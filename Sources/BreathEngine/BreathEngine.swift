import AVFoundation
import Foundation

/// Top-level engine: renders exact-duration breaths from an asset palette and plays
/// them (single, cycle, or looping). Asset-driven only — if a requested style/role
/// is missing it throws rather than producing silence.
@MainActor
public final class BreathEngine {
    public struct Config: Sendable {
        public var assetsDirectory: URL
        public var manifest: BreathManifest
        /// Assembler tunables, including the working sample rate — the single source
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
            sampleRate: Double = AudioConstants.workingSampleRate,
            masterGain: Double = 1.0,
            headroomDb: Double = -1.0,
            cacheLimit: Int = 32
        ) {
            self.assetsDirectory = assetsDirectory
            self.manifest = manifest
            self.settings = AssemblerSettings(sampleRate: sampleRate)
            self.masterGain = masterGain
            self.headroomDb = headroomDb
            self.cacheLimit = cacheLimit
        }
    }

    private let config: Config
    private let library: AssetLibrary
    private let player: BreathPlayer
    private var cache: [String: AVAudioPCMBuffer] = [:]
    private var cacheOrder: [String] = []

    public init(config: Config) throws {
        self.config = config
        self.library = AssetLibrary(
            baseURL: config.assetsDirectory,
            manifest: config.manifest,
            sampleRate: config.sampleRate
        )
        self.player = try BreathPlayer(sampleRate: config.sampleRate)
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
        let clips = try library.sourceClips(style: spec.style, type: spec.type, rng: &rng)
        let deltas = Variation.draw(spec.variation, rng: &rng)
        var samples = BreathAssembler.assemble(
            type: spec.type,
            durationSec: spec.clampedDurationSec,
            clips: clips,
            settings: config.settings,
            deltas: deltas
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

    // MARK: - Playback

    public func play(_ spec: BreathSpec) async throws {
        try await player.playOnce(render(spec))
    }

    public func play(_ buffer: AVAudioPCMBuffer) async throws {
        try await player.playOnce(buffer)
    }

    /// Play a cycle. Loops forever (non-blocking) when `cycle.loop`, otherwise plays
    /// `cycle.cycles` times and returns when done.
    public func playCycle(_ cycle: CycleSpec) async throws {
        let buffer = try renderCycle(cycle)
        if cycle.loop {
            try player.loopForever(buffer)
        } else {
            try await player.play(buffer, times: max(1, cycle.cycles))
        }
    }

    public func stop() {
        player.stop()
    }

    // MARK: - File output

    /// Render a breath and write it to a 32-bit float WAV file.
    public func renderToWAV(_ spec: BreathSpec, url: URL) throws {
        let buffer = try render(spec)
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
        guard let buffer = AVAudioPCMBuffer(pcmFormat: player.format, frameCapacity: frameCount) else {
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

    private func cacheKey(_ spec: BreathSpec) -> String {
        let seed = spec.seed ?? Variation.stableSeed(for: spec)
        return Variation.canonicalString(spec) + "|seed:\(seed)"
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
