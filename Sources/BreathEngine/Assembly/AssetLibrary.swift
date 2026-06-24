import AVFoundation
import Foundation

/// Loads breath assets from disk, decoding/resampling each to mono Float at the
/// working sample rate, and caches the decoded samples. Isolated to the main actor
/// so it shares the engine's isolation domain.
@MainActor
public final class AssetLibrary {
    private let baseURL: URL
    private let manifest: BreathManifest
    private let sampleRate: Double
    private var cache: [String: [Float]] = [:]

    public init(baseURL: URL, manifest: BreathManifest, sampleRate: Double = AudioConstants.workingSampleRate) {
        self.baseURL = baseURL
        self.manifest = manifest
        self.sampleRate = sampleRate
    }

    /// Choose the one-shot variant (seeded) and load the clip for one breath render.
    public func sourceClips(
        style: BreathStyle,
        type: BreathType,
        rng: inout SeededRNG
    ) throws -> BreathSourceClips {
        guard let palette = manifest.palette(style: style, type: type) else {
            throw BreathError.missingStyle(style, type)
        }
        let oneShot = try loadOptional(palette.oneShot, style: style, type: type, role: .oneShot, rng: &rng)
        return BreathSourceClips(oneShot: oneShot)
    }

    private func loadOptional(
        _ assets: [BreathAsset],
        style: BreathStyle,
        type: BreathType,
        role: BreathRole,
        rng: inout SeededRNG
    ) throws -> [Float]? {
        guard !assets.isEmpty else { return nil }
        return try loadOne(assets, style: style, type: type, role: role, rng: &rng)
    }

    private func loadOne(
        _ assets: [BreathAsset],
        style: BreathStyle,
        type: BreathType,
        role: BreathRole,
        rng: inout SeededRNG
    ) throws -> [Float] {
        guard !assets.isEmpty else {
            throw BreathError.emptyRole(style, type, role)
        }
        let pick = assets.count == 1 ? assets[0] : assets[Int.random(in: 0..<assets.count, using: &rng)]
        return try samples(for: pick.file)
    }

    /// Decoded mono samples for a file (cached).
    public func samples(for file: String) throws -> [Float] {
        if let cached = cache[file] { return cached }
        // Asset filenames are flat; reject path separators / traversal so a crafted
        // manifest can't read files outside the assets directory.
        guard !file.isEmpty, !file.contains("/"), !file.contains("..") else {
            throw BreathError.assetNotFound(file)
        }
        let url = baseURL.appendingPathComponent(file)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw BreathError.assetNotFound(url.path)
        }
        let decoded = try Self.loadMonoSamples(url: url, targetRate: sampleRate)
        cache[file] = decoded
        return decoded
    }

    /// Decode a file to mono Float32 at `targetRate`, resampling/downmixing as needed.
    static func loadMonoSamples(url: URL, targetRate: Double) throws -> [Float] {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw BreathError.ioFailure("opening \(url.lastPathComponent): \(error.localizedDescription)")
        }
        let inFormat = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0,
              let inBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: frameCount) else {
            return []
        }
        do {
            try file.read(into: inBuffer)
        } catch {
            throw BreathError.ioFailure("reading \(url.lastPathComponent): \(error.localizedDescription)")
        }

        // `processingFormat` is always deinterleaved Float32, so floatChannelData is valid.
        let frames = Int(inBuffer.frameLength)
        guard frames > 0, let channelData = inBuffer.floatChannelData else { return [] }
        let channelCount = Int(inFormat.channelCount)

        // Downmix to mono.
        var mono = [Float](repeating: 0, count: frames)
        for c in 0..<channelCount {
            let ptr = channelData[c]
            for i in 0..<frames { mono[i] += ptr[i] }
        }
        if channelCount > 1 {
            let scale = 1 / Float(channelCount)
            for i in 0..<frames { mono[i] *= scale }
        }

        // Resample to the working rate if needed (linear interp, matching the rest of the engine).
        if inFormat.sampleRate != targetRate {
            let target = Int((Double(frames) * targetRate / inFormat.sampleRate).rounded())
            mono = Resample.toFrames(mono, target)
        }
        return mono
    }
}
