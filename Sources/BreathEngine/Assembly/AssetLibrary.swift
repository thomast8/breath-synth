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
    private var bankCache: [String: FragmentBank?] = [:]
    private var grainPoolCache: [String: [[Float]]] = [:]
    private var corePoolCache: [String: [[Float]]] = [:]
    private var gapPoolCache: [String: [Int]] = [:]
    private var fingerprintCache: [String: String] = [:]

    public init(baseURL: URL, manifest: BreathManifest, sampleRate: Double = AudioConstants.workingSampleRate) {
        self.baseURL = baseURL
        self.manifest = manifest
        self.sampleRate = sampleRate
    }

    /// Choose the one-shot variant (seeded) and load the clip for one breath render.
    public func sourceClips(
        style: BreathStyle,
        type: BreathType,
        rng: inout SeededRNG,
        acceptedOneShot: Set<String>? = nil
    ) throws -> BreathSourceClips {
        guard let palette = manifest.palette(style: style, type: type) else {
            throw BreathError.missingStyle(style, type)
        }
        let oneShot = try loadOptional(palette.oneShot, style: style, type: type, role: .oneShot,
                                       rng: &rng, acceptedOneShot: acceptedOneShot)
        return BreathSourceClips(oneShot: oneShot)
    }

    private func loadOptional(
        _ assets: [BreathAsset],
        style: BreathStyle,
        type: BreathType,
        role: BreathRole,
        rng: inout SeededRNG,
        acceptedOneShot: Set<String>?
    ) throws -> [Float]? {
        guard !assets.isEmpty else { return nil }
        return try loadOne(assets, style: style, type: type, role: role,
                           rng: &rng, acceptedOneShot: acceptedOneShot)
    }

    private func loadOne(
        _ assets: [BreathAsset],
        style: BreathStyle,
        type: BreathType,
        role: BreathRole,
        rng: inout SeededRNG,
        acceptedOneShot: Set<String>?
    ) throws -> [Float] {
        guard !assets.isEmpty else {
            throw BreathError.emptyRole(style, type, role)
        }
        // Restrict the one-shot pick to the bank's accepted takes (frc/rv partial-failure tolerance).
        // Same single seeded draw, just over the accepted subset; an empty filter (no bank, or none
        // accepted) leaves the full list, so the no-bank pick is byte-identical.
        var pool = assets
        if role == .oneShot, let acceptedOneShot, !acceptedOneShot.isEmpty {
            let filtered = assets.filter { acceptedOneShot.contains($0.file) }
            if !filtered.isEmpty { pool = filtered }
        }
        let pick = pool.count == 1 ? pool[0] : pool[Int.random(in: 0..<pool.count, using: &rng)]
        return try samples(for: pick.file)
    }

    /// The set of accepted one-shot-body take filenames in the bank for `(style, type)` — the takes
    /// the frc/rv pick is allowed to draw from. `nil` when there's no bank or no accepted body.
    public func oneShotBodyAcceptedFiles(style: BreathStyle, type: BreathType, expectedSig: String?) -> Set<String>? {
        guard let bank = fragmentBank(style: style, type: type, expectedSig: expectedSig) else { return nil }
        let files = Set(bank.acceptedFragments(kind: .oneShotBody).map(\.file))
        return files.isEmpty ? nil : files
    }

    /// A content fingerprint of the bank's accepted fragments for `(style, type)` — folded into the
    /// render cache key so a regrade (different accept set, or a rebuilt bank) invalidates stale
    /// buffers. `"0"` when there's no bank. Cached.
    public func bankFingerprint(style: BreathStyle, type: BreathType, expectedSig: String?) -> String {
        let key = "\(style)|\(type.rawValue)"
        if let cached = fingerprintCache[key] { return cached }
        let fingerprint: String
        if let bank = fragmentBank(style: style, type: type, expectedSig: expectedSig) {
            let accepted = bank.fragments
                .filter { $0.accept }
                .map { "\($0.file):\($0.startFrame):\($0.endFrame):\($0.kind.rawValue)" }
                .sorted()
                .joined(separator: ",")
            fingerprint = String(format: "%016llx", Variation.fnv1a(bank.preparedSig + "|" + accepted))
        } else {
            fingerprint = "0"
        }
        fingerprintCache[key] = fingerprint
        return fingerprint
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

    // MARK: - Fragment banks

    /// Load (and cache) the fragment-bank sidecar for `(style, type)`, or `nil` when the manifest
    /// names none, it can't be read, or its `preparedSig` doesn't match `expectedSig` — the engine
    /// refuses a bank cut under an incompatible prepare configuration rather than rendering from
    /// offsets that no longer line up with how it prepares sources.
    public func fragmentBank(style: BreathStyle, type: BreathType, expectedSig: String?) -> FragmentBank? {
        let key = "\(style)|\(type.rawValue)"
        if let cached = bankCache[key] { return cached }
        let bank = loadBank(style: style, type: type, expectedSig: expectedSig)
        bankCache[key] = bank
        return bank
    }

    private func loadBank(style: BreathStyle, type: BreathType, expectedSig: String?) -> FragmentBank? {
        // The sidecar lives at a manifest-relative path (e.g. "fragments/calm_inhale.frags.json");
        // reject traversal so a crafted manifest can't read outside the assets directory.
        guard let palette = manifest.palette(style: style, type: type),
              let name = palette.fragmentBank, !name.isEmpty, !name.contains("..") else { return nil }
        guard let bank = try? FragmentBank.load(from: baseURL.appendingPathComponent(name)) else { return nil }
        if let expectedSig, bank.preparedSig != expectedSig { return nil }
        return bank
    }

    /// The accepted grain pool for a textured `(style, type)`: each accepted `grain` fragment sliced
    /// from its take's prepared cache, in the bank's stable `(file, startFrame)` order. `nil` when
    /// there's no usable bank or no accepted grain. Cached — the pool is immutable for an engine.
    public func grainPool(style: BreathStyle, type: BreathType, expectedSig: String?) -> [[Float]]? {
        let key = "\(style)|\(type.rawValue)"
        if let cached = grainPoolCache[key] { return cached.isEmpty ? nil : cached }
        guard let bank = fragmentBank(style: style, type: type, expectedSig: expectedSig) else {
            grainPoolCache[key] = []
            return nil
        }
        var pool: [[Float]] = []
        for fragment in bank.acceptedFragments(kind: .grain) {
            guard let signal = try? samples(for: fragment.preparedCacheFile),
                  fragment.startFrame >= 0, fragment.startFrame < fragment.endFrame,
                  fragment.endFrame <= signal.count else { continue }
            pool.append(Array(signal[fragment.startFrame..<fragment.endFrame]))
        }
        grainPoolCache[key] = pool
        return pool.isEmpty ? nil : pool
    }

    /// The accepted gulp-core pool for a counted/hybrid `(style, type)`: each accepted `gulpCore`
    /// fragment re-cut and declicked from its take's prepared cache, exactly as the engine would
    /// render it. `nil` when there's no usable bank or no accepted core. Cached.
    public func gulpCorePool(style: BreathStyle, type: BreathType, expectedSig: String?) -> [[Float]]? {
        let key = "\(style)|\(type.rawValue)"
        if let cached = corePoolCache[key] { return cached.isEmpty ? nil : cached }
        guard let bank = fragmentBank(style: style, type: type, expectedSig: expectedSig) else {
            corePoolCache[key] = []
            return nil
        }
        var cores: [[Float]] = []
        for fragment in bank.acceptedFragments(kind: .gulpCore) {
            guard let signal = try? samples(for: fragment.preparedCacheFile),
                  fragment.startFrame >= 0, fragment.startFrame < fragment.endFrame,
                  fragment.endFrame <= signal.count else { continue }
            cores.append(UnitExtractor.declickedCore(Array(signal[fragment.startFrame..<fragment.endFrame]),
                                                     sampleRate: sampleRate))
        }
        corePoolCache[key] = cores
        return cores.isEmpty ? nil : cores
    }

    /// The accepted inter-onset rhythm-gap pool (sample counts) for a counted/hybrid `(style, type)`,
    /// in the bank's stable order — the cadence cores are laid out at. `nil` when there's no usable
    /// bank or no accepted gap. Cached.
    public func rhythmGapPool(style: BreathStyle, type: BreathType, expectedSig: String?) -> [Int]? {
        let key = "\(style)|\(type.rawValue)"
        if let cached = gapPoolCache[key] { return cached.isEmpty ? nil : cached }
        guard let bank = fragmentBank(style: style, type: type, expectedSig: expectedSig) else {
            gapPoolCache[key] = []
            return nil
        }
        let gaps = bank.acceptedFragments(kind: .gap).compactMap(\.gapToNext).filter { $0 > 0 }
        gapPoolCache[key] = gaps
        return gaps.isEmpty ? nil : gaps
    }

    /// Decode a file to mono Float32 at `targetRate`, resampling/downmixing as needed. `nonisolated`
    /// and `public` so the app-layer `breath-bank` builder decodes enrollment takes through the exact
    /// same path the engine uses for its assets (no decode drift between build and render).
    public nonisolated static func loadMonoSamples(url: URL, targetRate: Double) throws -> [Float] {
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
