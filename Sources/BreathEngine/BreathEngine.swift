import AVFoundation
import Foundation

/// Top-level engine: renders exact-duration asset-backed breaths and plays them
/// (single, cycle, or looping).
@MainActor
public final class BreathEngine {
    public struct Config: Sendable {
        /// Directory containing the breath assets referenced by `manifest`.
        public var assetsDirectory: URL
        /// The breath palette driving assembly.
        public var manifest: BreathManifest
        /// Assembler tunables, including the working sample rate, the single source
        /// of truth for the rate (both decode-resampling and assembly read it here).
        public var settings: AssemblerSettings
        /// Master gain applied after assembly.
        public var masterGain: Double
        /// Headroom (dB, negative) applied before the final clamp.
        public var headroomDb: Double
        /// Max number of rendered buffers to keep cached.
        public var cacheLimit: Int

        /// The working sample rate, derived from `settings`.
        public var sampleRate: Double { settings.sampleRate }

        public init(
            assetsDirectory: URL,
            manifest: BreathManifest,
            settings: AssemblerSettings = AssemblerSettings(),
            masterGain: Double = 1.0,
            headroomDb: Double = -1.0,
            cacheLimit: Int = 32
        ) {
            self.assetsDirectory = assetsDirectory
            self.manifest = manifest
            self.settings = settings
            self.masterGain = masterGain
            self.headroomDb = headroomDb
            self.cacheLimit = cacheLimit
        }
    }

    private let config: Config
    private let library: AssetLibrary
    private let format: AVAudioFormat
    /// Per-bin room-tone magnitude profile loaded from `manifest.noiseProfile`, passed
    /// to every render so the denoiser subtracts the measured floor instead of estimating
    /// one. `nil` when no profile is configured or it failed to load (denoiser falls back).
    private let noiseProfile: [Float]?
    /// The prepare-config signature the engine expects a fragment bank to carry; a bank whose
    /// `preparedSig` differs is ignored (the render falls back to the single-take path).
    private let bankSig: String
    private var player: BreathPlayer?
    private var cache: [String: AVAudioPCMBuffer] = [:]
    private var cacheOrder: [String] = []

    public init(config: Config) throws {
        self.config = config
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: config.sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw BreathError.audioFormatUnavailable
        }
        self.format = format
        self.library = AssetLibrary(
            baseURL: config.assetsDirectory,
            manifest: config.manifest,
            sampleRate: config.sampleRate
        )
        // Load the room-tone denoise profile once, if the manifest names one. A missing or
        // unreadable file leaves `noiseProfile` nil so the denoiser estimates its own floor.
        if let name = config.manifest.noiseProfile {
            if let s = try? library.samples(for: name) {
                noiseProfile = SpectralDenoise.magnitudeProfile(from: s, sampleRate: config.sampleRate)
            } else {
                noiseProfile = nil
            }
        } else {
            noiseProfile = nil
        }
        bankSig = FragmentBank.preparedSignature(settings: config.settings, roomToneProfile: noiseProfile)
    }

    /// Convenience: build an engine from a manifest.json file in `assetsDirectory`.
    /// Pass `settings` to tune assembly (sample rate, spectral denoise, etc.).
    public static func load(
        assetsDirectory: URL,
        settings: AssemblerSettings = AssemblerSettings()
    ) throws -> BreathEngine {
        let manifestURL = assetsDirectory.appendingPathComponent("manifest.json")
        let manifest = try BreathManifest.load(from: manifestURL)
        return try BreathEngine(config: Config(assetsDirectory: assetsDirectory, manifest: manifest, settings: settings))
    }

    // MARK: - Rendering

    /// Render the breath to mono samples (no caching).
    public func renderSamples(_ spec: BreathSpec) throws -> [Float] {
        RenderJob.run(try job(for: spec))
    }

    /// The same render, with the expensive half moved off this actor.
    ///
    /// `BreathEngine` is `@MainActor`, so every caller's render ran on the main thread and froze
    /// the app for as long as it took. That is about 0.9s for a five-minute sequence in a release
    /// build, and — because the DSP is `-Onone` there — roughly 75 SECONDS in a debug one, which
    /// reads as a hang rather than a hitch: no timer, no touches, no accessibility.
    ///
    /// Only the asset loading genuinely needs the actor, and it is cached and quick. Everything
    /// after it is arithmetic over `Sendable` values, so it is gathered into a ``RenderJob`` here
    /// and assembled somewhere else.
    public func renderSamplesOffActor(_ spec: BreathSpec) async throws -> [Float] {
        let job = try job(for: spec)
        return await Task.detached(priority: .userInitiated) { RenderJob.run(job) }.value
    }

    /// Gathers everything the assembler needs. This is the part that touches the library, and the
    /// only part that has to happen here.
    private func job(for spec: BreathSpec) throws -> RenderJob {
        let mode = config.manifest.styles[spec.style]?.effectiveRender ?? .textured
        // Counted styles have no duration; `BreathSpec` can't express a count, so fail loudly
        // rather than silently degrading to one one-shot copy (via render/cycle/sequence).
        guard mode != .counted else { throw BreathError.styleRequiresCount(spec.style) }
        let seed = spec.seed ?? Variation.stableSeed(for: spec)
        var rng = SeededRNG(seed: seed)
        let deltas = Variation.draw(spec.variation, rng: &rng)
        // frc/rv (oneShot) restrict the take pick to the bank's accepted takes; nil ⇒ no filter ⇒
        // byte-identical pick. The same single seeded draw is used, so the stream doesn't shift.
        let acceptedOneShot = library.oneShotBodyAcceptedFiles(style: spec.style, type: spec.type, expectedSig: bankSig)
        let clips = try library.sourceClips(style: spec.style, type: spec.type, rng: &rng,
                                            acceptedOneShot: acceptedOneShot)
        // Banked textured styles render from the cross-take accepted-grain pool. Loaded after the
        // take pick and drawing no RNG, so the seed stream — and thus the no-bank render — is
        // byte-identical whether or not a bank is present.
        let grainPool = mode == .textured
            ? library.grainPool(style: spec.style, type: spec.type, expectedSig: bankSig)
            : nil
        return RenderJob(
            type: spec.type,
            durationSec: spec.clampedDurationSec,
            clips: clips,
            settings: config.settings,
            deltas: deltas,
            seed: seed,
            mode: mode,
            style: spec.style,
            noiseProfile: noiseProfile,
            grainPool: grainPool,
            gain: config.masterGain * spec.gain * Variation.dbToGain(config.headroomDb)
        )
    }

    /// One render, reduced to values. Nothing here reaches back into the engine, the library or
    /// any actor, which is what lets it run off the main thread.
    struct RenderJob: Sendable {
        let type: BreathType
        let durationSec: Double
        let clips: BreathSourceClips
        let settings: AssemblerSettings
        let deltas: VariationDeltas
        let seed: UInt64
        let mode: RenderMode
        let style: BreathStyle
        let noiseProfile: [Float]?
        let grainPool: [[Float]]?
        /// Master gain, the caller's extra gain and the headroom, pre-multiplied — so the clamp
        /// can happen here rather than needing the engine's config afterwards.
        let gain: Double

        static func run(_ job: RenderJob) -> [Float] {
            var samples = BreathAssembler.assemble(
                type: job.type,
                durationSec: job.durationSec,
                clips: job.clips,
                settings: job.settings,
                deltas: job.deltas,
                seed: job.seed,
                mode: job.mode,
                style: job.style,
                noiseProfile: job.noiseProfile,
                grainPool: job.grainPool
            )
            let gain = Float(job.gain)
            for i in samples.indices {
                var v = samples[i] * gain
                if v > 1 { v = 1 } else if v < -1 { v = -1 }
                samples[i] = v
            }
            return samples
        }
    }

    /// Render the breath to a cached AVAudioPCMBuffer ready for playback.
    public func render(_ spec: BreathSpec) throws -> AVAudioPCMBuffer {
        let key = cacheKey(spec)
        if let cached = cache[key] {
            return cached
        }
        let buffer = try makeBuffer(renderSamples(spec))
        store(buffer, for: key)
        return buffer
    }

    /// Render `max(1, cycle.cycles)` inhale/hold/exhale/hold cycles into one buffer, each cycle
    /// re-seeded so consecutive cycles draw independent samples (no "ABC ABC ABC" repeat) while
    /// staying reproducible. Cycle 0 matches a single-cycle render of the spec.
    public func renderCycle(_ cycle: CycleSpec) throws -> AVAudioPCMBuffer {
        try makeBuffer(renderCyclesSamples(cycle, count: max(1, cycle.cycles)))
    }

    /// One cycle's samples, decorrelated by `cycleIndex` (golden-ratio seed stride, as sequences use).
    public func renderCycleSamples(_ cycle: CycleSpec, cycleIndex: Int = 0) throws -> [Float] {
        var samples = try renderSamples(decorrelated(cycle.inhale, cycleIndex: cycleIndex))
        samples += silence(seconds: cycle.holdAfterInhaleSec)
        samples += try renderSamples(decorrelated(cycle.exhale, cycleIndex: cycleIndex))
        samples += silence(seconds: cycle.holdAfterExhaleSec)
        return samples
    }

    private func renderCyclesSamples(_ cycle: CycleSpec, count: Int) throws -> [Float] {
        var samples: [Float] = []
        for index in 0..<max(1, count) { samples += try renderCycleSamples(cycle, cycleIndex: index) }
        return samples
    }

    /// Per-cycle decorrelated copy of a breath spec: stride the seed by `cycleIndex` with the golden
    /// ratio so consecutive cycles differ yet stay reproducible. Index 0 is the spec's own seed.
    private func decorrelated(_ base: BreathSpec, cycleIndex: Int) -> BreathSpec {
        var spec = base
        let baseSeed = base.seed ?? Variation.stableSeed(for: base)
        spec.seed = baseSeed &+ UInt64(cycleIndex) &* 0x9E37_79B9_7F4A_7C15
        return spec
    }

    /// Render a planned sequence (a whole number of pattern cycles) to mono samples.
    /// Each cycle is re-seeded so the run doesn't sound like one identical loop repeated,
    /// while staying fully reproducible (seed the pattern to pin the whole sequence).
    public func renderSequenceSamples(_ plan: SequencePlan) throws -> [Float] {
        Self.assemble(try sequenceJobs(plan))
    }

    /// The sequence render, off this actor — see ``renderSamplesOffActor(_:)``.
    ///
    /// This is the one that mattered: a breathe-up is a whole sequence, and it is rendered at the
    /// moment the step begins, which is the moment the diver is looking at the screen.
    public func renderSequenceSamplesOffActor(_ plan: SequencePlan) async throws -> [Float] {
        let jobs = try sequenceJobs(plan)
        return await Task.detached(priority: .userInitiated) { Self.assemble(jobs) }.value
    }

    /// A whole sequence reduced to values, gathered on this actor.
    private func sequenceJobs(_ plan: SequencePlan) throws -> [SequenceEntry] {
        let pattern = plan.pattern
        var entries: [SequenceEntry] = []
        for cycleIndex in 0..<plan.cycles {
            entries.append(.breath(try job(for: breathSpec(for: pattern, type: .inhale, cycleIndex: cycleIndex))))
            entries.append(.silence(frames(pattern.holdInSec)))
            entries.append(.breath(try job(for: breathSpec(for: pattern, type: .exhale, cycleIndex: cycleIndex))))
            entries.append(.silence(frames(pattern.holdOutSec)))
        }
        return entries
    }

    /// Exposed for the test that pins the assembly's independence from any actor.
    func sequenceJobsForTesting(_ plan: SequencePlan) throws -> [SequenceEntry] {
        try sequenceJobs(plan)
    }

    enum SequenceEntry: Sendable {
        case breath(RenderJob)
        case silence(Int)
    }

    /// Pure, so it can run wherever it is called from — including off the main actor, which is
    /// the whole point of the split.
    nonisolated static func assemble(_ entries: [SequenceEntry]) -> [Float] {
        var samples: [Float] = []
        for entry in entries {
            switch entry {
            case .breath(let job): samples += RenderJob.run(job)
            case .silence(let count): samples += [Float](repeating: 0, count: count)
            }
        }
        return samples
    }

    private func frames(_ seconds: Double) -> Int {
        Segments.frames(seconds: max(0, seconds), sampleRate: config.sampleRate)
    }

    /// Render a planned sequence into a single buffer.
    public func renderSequence(_ plan: SequencePlan) throws -> AVAudioPCMBuffer {
        try makeBuffer(renderSequenceSamples(plan))
    }

    // MARK: - Counted render

    /// Render `count` counted events (recovery breaths, packing gulps) to mono samples.
    ///
    /// With a single source take the recording is cleaned/denoised, split into its real events, and
    /// the first `count` are concatenated (cycling for higher counts) — a seamless slice of the real
    /// recording. With two source takes the render is HYBRID: clean event cores are sampled (seeded)
    /// from the first take and laid out at the second take's natural rhythm (used for packing —
    /// random single packs from the separated take, at the natural-rhythm take's cadence). When
    /// `count` is nil the detected event count is used.
    public func renderCountedSamples(
        style: BreathStyle,
        type: BreathType,
        count: Int?,
        seed: UInt64? = nil
    ) throws -> [Float] {
        CountedJob.run(try countedJob(style: style, type: type, count: count, seed: seed))
    }

    /// Gathers what a counted render needs. Only the library reads happen here; every branch
    /// hands the raw samples on and lets the DSP happen wherever the caller wants it.
    private func countedJob(
        style: BreathStyle,
        type: BreathType,
        count: Int?,
        seed: UInt64?
    ) throws -> CountedJob {
        let resolvedSeed = seed ?? countedStableSeed(style: style, type: type, count: count)
        guard let palette = config.manifest.palette(style: style, type: type), !palette.oneShot.isEmpty else {
            throw BreathError.emptyRole(style, type, .oneShot)
        }
        let gain = config.masterGain * Variation.dbToGain(config.headroomDb)

        if let cores = library.gulpCorePool(style: style, type: type, expectedSig: bankSig),
           let gaps = library.rhythmGapPool(style: style, type: type, expectedSig: bankSig) {
            // Banked hybrid: cross-take accepted gulp cores laid out at the pooled cadence. Seeded by
            // `resolvedSeed`, so identical to the single-take hybrid in shape but drawing from the full
            // graded pool. No bank ⇒ the pools are nil and we fall through to the take-based paths,
            // which stay byte-identical. A nil count defaults to ONE cadence take's worth of gulps, not
            // the pooled cross-take total (which would scale the breath with the number of takes).
            let n = count
                ?? library.defaultCountedEvents(style: style, type: type, expectedSig: bankSig)
                ?? (gaps.count + 1)
            return CountedJob(shape: .pooledHybrid(cores: cores, gaps: gaps, count: n),
                              settings: config.settings, noiseProfile: noiseProfile,
                              sampleRate: config.sampleRate, seed: resolvedSeed, gain: gain)
        } else if palette.oneShot.count >= 2 {
            // Hybrid: cores from take 0 (separated packs), rhythm from take 1 (natural cadence).
            return CountedJob(
                shape: .takeHybrid(coreRaw: try library.samples(for: palette.oneShot[0].file),
                                        rhythmRaw: try library.samples(for: palette.oneShot[1].file),
                                        count: count),
                settings: config.settings, noiseProfile: noiseProfile,
                sampleRate: config.sampleRate, seed: resolvedSeed, gain: gain)
        } else {
            return CountedJob(
                shape: .singleTake(raw: try library.samples(for: palette.oneShot[0].file), count: count),
                settings: config.settings, noiseProfile: noiseProfile,
                sampleRate: config.sampleRate, seed: resolvedSeed, gain: gain)
        }
    }

    /// One counted render, reduced to values — see ``RenderJob``.
    struct CountedJob: Sendable {
        enum Shape: Sendable {
            case pooledHybrid(cores: [[Float]], gaps: [Int], count: Int)
            case takeHybrid(coreRaw: [Float], rhythmRaw: [Float], count: Int?)
            case singleTake(raw: [Float], count: Int?)
        }

        let shape: Shape
        let settings: AssemblerSettings
        let noiseProfile: [Float]?
        let sampleRate: Double
        let seed: UInt64
        let gain: Double

        static func run(_ job: CountedJob) -> [Float] {
            var body: [Float]
            switch job.shape {
            case .pooledHybrid(let cores, let gaps, let count):
                body = BreathAssembler.assembleHybrid(
                    cores: cores, gaps: gaps, count: count, settings: job.settings, seed: job.seed)

            case .takeHybrid(let coreRaw, let rhythmRaw, let count):
                let coreSrc = BreathAssembler.prepareSource(
                    coreRaw, settings: job.settings, noiseProfile: job.noiseProfile)
                let rhythmSrc = BreathAssembler.prepareSource(
                    rhythmRaw, settings: job.settings, noiseProfile: job.noiseProfile)
                let cores = UnitExtractor.gulpCores(from: coreSrc, sampleRate: job.sampleRate)
                let gaps = UnitExtractor.rhythmGaps(from: rhythmSrc, sampleRate: job.sampleRate)
                body = BreathAssembler.assembleHybrid(
                    cores: cores, gaps: gaps, count: count ?? (gaps.count + 1),
                    settings: job.settings, seed: job.seed)

            case .singleTake(let raw, let count):
                let prepared = BreathAssembler.prepareSource(
                    raw, settings: job.settings, noiseProfile: job.noiseProfile)
                let (units, detected) = UnitExtractor.extract(from: prepared, sampleRate: job.sampleRate)
                body = BreathAssembler.assembleCounted(
                    units: units, count: count ?? detected, settings: job.settings)
            }

            let gain = Float(job.gain)
            for i in body.indices {
                var v = body[i] * gain
                if v > 1 { v = 1 } else if v < -1 { v = -1 }
                body[i] = v
            }
            return body
        }
    }

    /// Render a counted breath into a single buffer.
    public func renderCounted(
        style: BreathStyle,
        type: BreathType,
        count: Int?,
        seed: UInt64? = nil
    ) throws -> AVAudioPCMBuffer {
        try makeBuffer(renderCountedSamples(style: style, type: type, count: count, seed: seed))
    }

    /// Render a counted breath and write it to a 32-bit float WAV file.
    public func renderCountedToWAV(
        style: BreathStyle,
        type: BreathType,
        count: Int?,
        seed: UInt64? = nil,
        url: URL
    ) throws {
        try write(renderCounted(style: style, type: type, count: count, seed: seed), to: url)
    }

    /// Play a counted breath once and return when done.
    public func playCounted(
        style: BreathStyle,
        type: BreathType,
        count: Int?,
        seed: UInt64? = nil
    ) async throws {
        let samples = try await renderCountedSamplesOffActor(
            style: style, type: type, count: count, seed: seed
        )
        try await playerInstance().playOnce(makeBuffer(samples))
    }

    /// The counted render, off this actor — see ``renderSamplesOffActor(_:)``.
    ///
    /// The costly part here is `prepareSource`, which denoises a whole source take; it is the
    /// same spectral work that made the sequence render freeze the caller, on the same thread.
    public func renderCountedSamplesOffActor(
        style: BreathStyle,
        type: BreathType,
        count: Int?,
        seed: UInt64? = nil
    ) async throws -> [Float] {
        let job = try countedJob(style: style, type: type, count: count, seed: seed)
        return await Task.detached(priority: .userInitiated) { CountedJob.run(job) }.value
    }

    // MARK: - Manifest accessors

    /// Style names declared in the manifest, sorted for stable presentation.
    public func styleNames() -> [String] {
        config.manifest.styles.keys.sorted()
    }

    /// The render mode configured for `style`, defaulting to `.textured` when unset/unknown.
    public func renderMode(for style: BreathStyle) -> RenderMode {
        config.manifest.styles[style]?.effectiveRender ?? .textured
    }

    /// The breath directions `style` actually carries a non-empty `oneShot` clip for,
    /// ordered inhale then exhale. Used by the UI to gate the direction picker.
    public func supportedDirections(for style: BreathStyle) -> [BreathType] {
        [BreathType.inhale, .exhale].filter { type in
            !(config.manifest.palette(style: style, type: type)?.oneShot.isEmpty ?? true)
        }
    }

    // MARK: - Playback

    public func play(_ spec: BreathSpec) async throws {
        try await playerInstance().playOnce(try await renderOffActor(spec))
    }

    /// ``render(_:)`` with the assembly off this actor. The cache is still consulted and filled
    /// here, so a repeated cue costs nothing either way.
    public func renderOffActor(_ spec: BreathSpec) async throws -> AVAudioPCMBuffer {
        let key = cacheKey(spec)
        if let cached = cache[key] { return cached }
        let buffer = try makeBuffer(await renderSamplesOffActor(spec))
        store(buffer, for: key)
        return buffer
    }

    public func play(_ buffer: AVAudioPCMBuffer) async throws {
        try await playerInstance().playOnce(buffer)
    }

    /// Play a cycle. When `cycle.loop`, loops a BLOCK of distinct cycles forever (non-blocking) so the
    /// repeat period is many breaths, not one. Otherwise plays `cycle.cycles` distinct cycles once and
    /// returns when done. Either way no two consecutive breaths are the identical buffer replayed.
    public func playCycle(_ cycle: CycleSpec) async throws {
        if cycle.loop {
            let block = try makeBuffer(renderCyclesSamples(cycle, count: Self.loopBlockCycles))
            try playerInstance().loopForever(block)
        } else {
            try await playerInstance().playOnce(renderCycle(cycle))
        }
    }

    /// Distinct cycles rendered into a looped block so an infinite cycle doesn't audibly repeat a
    /// single breath. Eight breaths is well past the point the repeat is perceptible under holds.
    private static let loopBlockCycles = 8

    /// Play a planned sequence as one buffer. Loops the whole sequence forever
    /// (non-blocking) when `loop`, otherwise plays it once and returns when done.
    public func playSequence(_ plan: SequencePlan, loop: Bool = false) async throws {
        // Off-actor: rendering here is what froze callers for the length of the render.
        let buffer = try makeBuffer(await renderSequenceSamplesOffActor(plan))
        if loop {
            try playerInstance().loopForever(buffer)
        } else {
            try await playerInstance().playOnce(buffer)
        }
    }

    public func stop() {
        player?.stop()
    }

    /// Pause / resume the current playback (debug tooling). No-op when nothing is playing.
    public func pause() { player?.pause() }
    public func resume() { player?.resume() }

    /// Seek then continue playback from a frame offset. See `BreathPlayer.play(_:fromFrame:repeats:loop:)`.
    public func play(
        _ buffer: AVAudioPCMBuffer,
        fromFrame startFrame: AVAudioFramePosition,
        repeats: Int,
        loop: Bool
    ) async throws {
        try await playerInstance().play(buffer, fromFrame: startFrame, repeats: repeats, loop: loop)
    }

    /// Current playback position in frames since playback started, or nil when nothing is playing.
    /// Used by debug tooling to drive a playhead; see `BreathPlayer.currentSampleTime` for semantics
    /// (monotonic, does not wrap on loop — the caller modulos by the displayed buffer length).
    public var currentSampleTime: AVAudioFramePosition? {
        player?.currentSampleTime
    }

    // MARK: - File output

    /// Render a breath and write it to a 32-bit float WAV file.
    public func renderToWAV(_ spec: BreathSpec, url: URL) throws {
        let buffer = try render(spec)
        try write(buffer, to: url)
    }

    /// Render a cycle and write it to a 32-bit float WAV file.
    public func renderCycleToWAV(_ cycle: CycleSpec, url: URL) throws {
        let buffer = try renderCycle(cycle)
        try write(buffer, to: url)
    }

    /// Render a planned sequence and write it to a 32-bit float WAV file.
    public func renderSequenceToWAV(_ plan: SequencePlan, url: URL) throws {
        try write(renderSequence(plan), to: url)
    }

    private func write(_ buffer: AVAudioPCMBuffer, to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: config.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings)
            try file.write(from: buffer)
        } catch {
            throw BreathError.ioFailure("writing \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    // MARK: - Helpers

    private func silence(seconds: Double) -> [Float] {
        let frames = Segments.frames(seconds: max(0, seconds), sampleRate: config.sampleRate)
        return [Float](repeating: 0, count: frames)
    }

    /// Build the breath spec for one phase of one cycle in a sequence, deriving a
    /// per-cycle, per-phase seed so consecutive cycles differ yet stay reproducible.
    private func breathSpec(for pattern: BreathPattern, type: BreathType, cycleIndex: Int) -> BreathSpec {
        let durationSec = type == .inhale ? pattern.inhaleSec : pattern.exhaleSec
        var spec = BreathSpec(type: type, durationSec: durationSec, style: pattern.style)
        // Start from the per-spec stable seed (already distinct by type/duration/style),
        // offset by any caller seed so a `--seed` still varies inhale and exhale apart,
        // and stride by cycle with the golden-ratio constant so consecutive cycles decorrelate.
        let base = Variation.stableSeed(for: spec) &+ (pattern.seed ?? 0)
        spec.seed = base &+ UInt64(cycleIndex) &* 0x9E37_79B9_7F4A_7C15
        return spec
    }

    /// A stable seed for a counted render, so a given (style, type, count) always varies the
    /// same way when the caller doesn't pin a seed. Mirrors `Variation.stableSeed`'s FNV hash.
    private func countedStableSeed(style: BreathStyle, type: BreathType, count: Int?) -> UInt64 {
        let key = "counted|\(style)|\(type.rawValue)|\(count.map(String.init) ?? "auto")"
        return Variation.fnv1a(key)
    }

    private func applyMasterGainAndClamp(_ samples: inout [Float], extraGain: Double) {
        let gain = Float(config.masterGain * extraGain * Variation.dbToGain(config.headroomDb))
        for i in samples.indices {
            var v = samples[i] * gain
            if v > 1 { v = 1 } else if v < -1 { v = -1 }
            samples[i] = v
        }
    }

    private func makeBuffer(_ samples: [Float]) throws -> AVAudioPCMBuffer {
        let frameCount = AVAudioFrameCount(max(1, samples.count))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw BreathError.audioFormatUnavailable
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let channel = buffer.floatChannelData, !samples.isEmpty {
            samples.withUnsafeBufferPointer { src in
                channel[0].update(from: src.baseAddress!, count: samples.count)
            }
        }
        return buffer
    }

    private func playerInstance() throws -> BreathPlayer {
        if let player { return player }
        let created = try BreathPlayer(sampleRate: config.sampleRate)
        player = created
        return created
    }

    private func cacheKey(_ spec: BreathSpec) -> String {
        let seed = spec.seed ?? Variation.stableSeed(for: spec)
        // Fold in the bank fingerprint so a regrade (changed accept set / rebuilt bank) invalidates
        // any stale cached buffer for this (style, type) instead of replaying pre-regrade audio.
        let bank = library.bankFingerprint(style: spec.style, type: spec.type, expectedSig: bankSig)
        return sourceCachePrefix + "|" + Variation.canonicalString(spec) + "|seed:\(seed)|bank:\(bank)"
    }

    private var sourceCachePrefix: String { "assets" }

    private func store(_ buffer: AVAudioPCMBuffer, for key: String) {
        cache[key] = buffer
        cacheOrder.append(key)
        while cacheOrder.count > config.cacheLimit {
            let evicted = cacheOrder.removeFirst()
            cache.removeValue(forKey: evicted)
        }
    }
}
