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
        var samples = BreathAssembler.assemble(
            type: spec.type,
            durationSec: spec.clampedDurationSec,
            clips: clips,
            settings: config.settings,
            deltas: deltas,
            seed: seed,
            mode: mode,
            style: spec.style,
            noiseProfile: noiseProfile,
            grainPool: grainPool
        )
        applyMasterGainAndClamp(&samples, extraGain: spec.gain)
        return samples
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

    /// Render a full inhale/hold/exhale/hold cycle into a single buffer.
    public func renderCycle(_ cycle: CycleSpec) throws -> AVAudioPCMBuffer {
        var samples = try renderSamples(cycle.inhale)
        samples += silence(seconds: cycle.holdAfterInhaleSec)
        samples += try renderSamples(cycle.exhale)
        samples += silence(seconds: cycle.holdAfterExhaleSec)
        return try makeBuffer(samples)
    }

    /// Render a planned sequence (a whole number of pattern cycles) to mono samples.
    /// Each cycle is re-seeded so the run doesn't sound like one identical loop repeated,
    /// while staying fully reproducible (seed the pattern to pin the whole sequence).
    public func renderSequenceSamples(_ plan: SequencePlan) throws -> [Float] {
        let pattern = plan.pattern
        var samples: [Float] = []
        for cycleIndex in 0..<plan.cycles {
            samples += try renderSamples(breathSpec(for: pattern, type: .inhale, cycleIndex: cycleIndex))
            samples += silence(seconds: pattern.holdInSec)
            samples += try renderSamples(breathSpec(for: pattern, type: .exhale, cycleIndex: cycleIndex))
            samples += silence(seconds: pattern.holdOutSec)
        }
        return samples
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
        let resolvedSeed = seed ?? countedStableSeed(style: style, type: type, count: count)
        guard let palette = config.manifest.palette(style: style, type: type), !palette.oneShot.isEmpty else {
            throw BreathError.emptyRole(style, type, .oneShot)
        }
        let sr = config.sampleRate
        var body: [Float]

        if let cores = library.gulpCorePool(style: style, type: type, expectedSig: bankSig),
           let gaps = library.rhythmGapPool(style: style, type: type, expectedSig: bankSig) {
            // Banked hybrid: cross-take accepted gulp cores laid out at the pooled cadence. Seeded by
            // `resolvedSeed`, so identical to the single-take hybrid in shape but drawing from the full
            // graded pool. No bank ⇒ the pools are nil and we fall through to the take-based paths,
            // which stay byte-identical.
            let n = count ?? (gaps.count + 1)
            body = BreathAssembler.assembleHybrid(cores: cores, gaps: gaps, count: n, settings: config.settings, seed: resolvedSeed)
        } else if palette.oneShot.count >= 2 {
            // Hybrid: cores from take 0 (separated packs), rhythm from take 1 (natural cadence).
            let coreSrc = BreathAssembler.prepareSource(
                try library.samples(for: palette.oneShot[0].file), settings: config.settings, noiseProfile: noiseProfile)
            let rhythmSrc = BreathAssembler.prepareSource(
                try library.samples(for: palette.oneShot[1].file), settings: config.settings, noiseProfile: noiseProfile)
            let cores = UnitExtractor.gulpCores(from: coreSrc, sampleRate: sr)
            let gaps = UnitExtractor.rhythmGaps(from: rhythmSrc, sampleRate: sr)
            let n = count ?? (gaps.count + 1)
            body = BreathAssembler.assembleHybrid(cores: cores, gaps: gaps, count: n, settings: config.settings, seed: resolvedSeed)
        } else {
            let prepared = BreathAssembler.prepareSource(
                try library.samples(for: palette.oneShot[0].file), settings: config.settings, noiseProfile: noiseProfile)
            let (units, detected) = UnitExtractor.extract(from: prepared, sampleRate: sr)
            body = BreathAssembler.assembleCounted(units: units, count: count ?? detected, settings: config.settings)
        }
        applyMasterGainAndClamp(&body, extraGain: 1.0)
        return body
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
        try await playerInstance().playOnce(renderCounted(style: style, type: type, count: count, seed: seed))
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
        try await playerInstance().playOnce(render(spec))
    }

    public func play(_ buffer: AVAudioPCMBuffer) async throws {
        try await playerInstance().playOnce(buffer)
    }

    /// Play a cycle. Loops forever (non-blocking) when `cycle.loop`, otherwise plays
    /// `cycle.cycles` times and returns when done.
    public func playCycle(_ cycle: CycleSpec) async throws {
        let buffer = try renderCycle(cycle)
        if cycle.loop {
            try playerInstance().loopForever(buffer)
        } else {
            try await playerInstance().play(buffer, times: max(1, cycle.cycles))
        }
    }

    /// Play a planned sequence as one buffer. Loops the whole sequence forever
    /// (non-blocking) when `loop`, otherwise plays it once and returns when done.
    public func playSequence(_ plan: SequencePlan, loop: Bool = false) async throws {
        let buffer = try renderSequence(plan)
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
