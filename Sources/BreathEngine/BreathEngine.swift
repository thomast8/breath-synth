import AVFoundation
import Foundation

/// Top-level engine: renders exact-duration procedural or asset-backed breaths and
/// plays them (single, cycle, or looping).
@MainActor
public final class BreathEngine {
    public struct Config: Sendable {
        public var source: BreathSource
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
            source: BreathSource = .procedural(),
            sampleRate: Double = AudioConstants.workingSampleRate,
            masterGain: Double = 1.0,
            headroomDb: Double = -1.0,
            cacheLimit: Int = 32
        ) {
            self.source = source
            self.settings = AssemblerSettings(sampleRate: sampleRate)
            self.masterGain = masterGain
            self.headroomDb = headroomDb
            self.cacheLimit = cacheLimit
        }

        public init(
            assetsDirectory: URL,
            manifest: BreathManifest,
            sampleRate: Double = AudioConstants.workingSampleRate,
            masterGain: Double = 1.0,
            headroomDb: Double = -1.0,
            cacheLimit: Int = 32
        ) {
            self.init(
                source: .assets(directory: assetsDirectory, manifest: manifest),
                sampleRate: sampleRate,
                masterGain: masterGain,
                headroomDb: headroomDb,
                cacheLimit: cacheLimit
            )
        }
    }

    private let config: Config
    private let library: AssetLibrary?
    private let format: AVAudioFormat
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
        switch config.source {
        case .procedural:
            self.library = nil
        case let .assets(directory, manifest):
            self.library = AssetLibrary(
                baseURL: directory,
                manifest: manifest,
                sampleRate: config.sampleRate
            )
        }
    }

    /// Convenience: build an engine from a manifest.json file in `assetsDirectory`.
    public static func load(assetsDirectory: URL) throws -> BreathEngine {
        let manifestURL = assetsDirectory.appendingPathComponent("manifest.json")
        let manifest = try BreathManifest.load(from: manifestURL)
        return try BreathEngine(config: Config(assetsDirectory: assetsDirectory, manifest: manifest))
    }

    // MARK: - Rendering

    /// Render the breath to mono samples (no caching).
    public func renderSamples(_ spec: BreathSpec) throws -> [Float] {
        let seed = spec.seed ?? Variation.stableSeed(for: spec)
        var rng = SeededRNG(seed: seed)
        let deltas = Variation.draw(spec.variation, rng: &rng)
        var samples: [Float]
        switch config.source {
        case let .procedural(proceduralConfig):
            let resolvedSpec = BreathSpec(
                type: spec.type,
                durationSec: spec.durationSec,
                style: spec.style,
                seed: seed,
                variation: spec.variation,
                gain: spec.gain
            )
            samples = try ProceduralBreathSynth.render(
                spec: resolvedSpec,
                sampleRate: config.sampleRate,
                config: proceduralConfig,
                deltas: deltas
            )
        case .assets:
            guard let library else {
                throw BreathError.ioFailure("asset source is missing its library")
            }
            let clips = try library.sourceClips(style: spec.style, type: spec.type, rng: &rng)
            samples = BreathAssembler.assemble(
                type: spec.type,
                durationSec: spec.clampedDurationSec,
                clips: clips,
                settings: config.settings,
                deltas: deltas
            )
        }
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

    public func stop() {
        player?.stop()
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
        return sourceCachePrefix + "|" + Variation.canonicalString(spec) + "|seed:\(seed)"
    }

    private var sourceCachePrefix: String {
        switch config.source {
        case .procedural:
            return "procedural"
        case .assets:
            return "assets"
        }
    }

    private func store(_ buffer: AVAudioPCMBuffer, for key: String) {
        cache[key] = buffer
        cacheOrder.append(key)
        while cacheOrder.count > config.cacheLimit {
            let evicted = cacheOrder.removeFirst()
            cache.removeValue(forKey: evicted)
        }
    }
}
