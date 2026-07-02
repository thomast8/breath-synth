import BreathEngine
import Foundation

/// Offline bank builder: turns an enrollment folder (`captures.json` + recorded takes + room tone)
/// into a self-contained, renderable bundle — a v2 manifest, per-(style, type) fragment-bank
/// sidecars, the prepared-signal caches the engine slices fragments from, the takes re-encoded to
/// 44.1 kHz mono WAV, and the session room tone. Every quality decision is the non-deep `Grader`'s;
/// the builder only segments, orchestrates grading, and lays down files. Pure and synchronous.
public enum BankBuilder {
    // MARK: - Public result

    public struct BankSummary: Sendable {
        public var style: String
        public var type: BreathType
        public var kindCounts: [String: (accepted: Int, total: Int)]
        public var rejectReasons: [String: Int]
    }

    public struct BuildSummary: Sendable, CustomStringConvertible {
        public var outDir: String
        public var roomTone: String?
        public var preparedSig: String
        public var banks: [BankSummary]
        /// Non-fatal build warnings (e.g. a counted style missing its cores or gaps takes).
        public var warnings: [String]

        public var description: String {
            var lines = ["Built \(banks.count) fragment bank(s) → \(outDir)"]
            lines.append("  room tone: \(roomTone ?? "none")   preparedSig: \(preparedSig)")
            for bank in banks.sorted(by: { ($0.style, $0.type.rawValue) < ($1.style, $1.type.rawValue) }) {
                let kinds = bank.kindCounts
                    .sorted { $0.key < $1.key }
                    .map { "\($0.key) \($0.value.accepted)/\($0.value.total)" }
                    .joined(separator: ", ")
                var line = "  \(bank.style) \(bank.type.rawValue): \(kinds)"
                if !bank.rejectReasons.isEmpty {
                    let reasons = bank.rejectReasons.sorted { $0.key < $1.key }
                        .map { "\($0.key)×\($0.value)" }.joined(separator: ", ")
                    line += "   rejected: \(reasons)"
                }
                lines.append(line)
            }
            for warning in warnings { lines.append("  ⚠︎ \(warning)") }
            return lines.joined(separator: "\n")
        }
    }

    // MARK: - Build

    public static func build(
        capturesDir: URL,
        assetsDir: URL,
        outDir: URL,
        settings: AssemblerSettings = AssemblerSettings(),
        thresholds: Grader.Thresholds = .default,
        builtAt: String = ISO8601DateFormatter().string(from: Date())
    ) throws -> BuildSummary {
        let fm = FileManager.default
        let session = try CaptureSession.load(from: capturesDir.appendingPathComponent("captures.json"))
        let sr = settings.sampleRate

        // Stage the whole bundle in a temp dir and promote it into `outDir` only once every write has
        // succeeded, so a mid-build fault never leaves a half-written or mixed-generation bundle.
        let staging = fm.temporaryDirectory.appendingPathComponent("breath-bank-\(UUID().uuidString)")
        let fragmentsDir = staging.appendingPathComponent("fragments")
        try fm.createDirectory(at: fragmentsDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        // Session room tone → the one profile that both steers the denoiser (so the prepared signal
        // matches what the engine renders) and provides the SNR floor for grading.
        var roomProfile: [Float]?
        var roomToneOut: String?
        if let rt = session.roomTone {
            let samples = try AudioIO.decodeMono(url: capturesDir.appendingPathComponent(rt), sampleRate: sr)
            roomToneOut = "room_tone.wav"
            let roomToneURL = staging.appendingPathComponent(roomToneOut!)
            try AudioIO.writeMonoWAV(samples, sampleRate: sr, to: roomToneURL)
            // Derive the room profile from the *written* room_tone.wav (what the engine and
            // prepare-caches read), NOT the capture-dir room tone — a re-encode/resample shifts a quiet
            // profile enough to flip the signature, so deriving it from the committed file keeps
            // build == render == regenerate consistent.
            let committed = try AudioIO.decodeMono(url: roomToneURL, sampleRate: sr)
            let profile = SpectralDenoise.magnitudeProfile(from: committed, sampleRate: sr)
            if !profile.isEmpty { roomProfile = profile }
        }
        let preparedSig = FragmentBank.preparedSignature(settings: settings, roomToneProfile: roomProfile)

        var groups: [GroupKey: Group] = [:]
        var orderedKeys: [GroupKey] = []
        var takesToWrite: [String: [Float]] = [:]   // out take filename → re-encoded samples
        var cachesToWrite: [String: [Float]] = [:]   // prepared-cache filename → signal

        for step in session.steps {
            let key = GroupKey(style: step.style, type: step.type)
            let group: Group
            if let existing = groups[key] {
                group = existing
            } else {
                group = Group(renderMode: step.renderMode, reference: step.reference)
                groups[key] = group
                orderedKeys.append(key)
            }

            let refProfile = step.reference.flatMap { ref in
                referenceProfile(
                    assetsDir.appendingPathComponent(ref),
                    role: step.role, type: step.type, settings: settings, roomProfile: roomProfile
                )
            }
            // Gold cadence (gulp-core spacing) for the packing cadence gate — cores steps only.
            let refCadence: [Int] = step.role == "cores"
                ? (step.reference.flatMap {
                    referenceCadence(assetsDir.appendingPathComponent($0), type: step.type,
                                     settings: settings, roomProfile: roomProfile)
                  } ?? [])
                : []
            let minCoreSpacing = Int(thresholds.minCoreSpacingSec * sr)

            // Pass 1: segment every take, stage its files, compute per-fragment features.
            var records: [Record] = []
            for file in step.files {
                let outName = outTakeName(forCaptureFile: file)
                let raw: [Float]
                do {
                    raw = try AudioIO.decodeMono(url: capturesDir.appendingPathComponent(file), sampleRate: sr)
                } catch {
                    continue   // a missing/corrupt take drops out; its siblings still build
                }
                takesToWrite[outName] = raw
                group.record(takeName: outName, role: step.role)

                let clipped = Grader.clippingRun(raw, peak: thresholds.clipPeak, minRun: thresholds.clipRunSamples)
                let durationSec = Double(raw.count) / sr
                let lengthOK = lengthWithinBounds(durationSec, min: step.minSeconds, max: step.maxSeconds)

                let out = Segmenter.segment(
                    rawTake: raw, role: step.role, type: step.type,
                    settings: settings, roomToneProfile: roomProfile
                )
                if let cache = out.cacheSignal {
                    cachesToWrite[FragmentBank.preparedCacheName(forTake: outName)] = cache
                }
                // Take-level packing cadence vs the gold reference (applies to all this take's cores).
                let takeCoreGaps = out.fragments.filter { $0.kind == .gulpCore }.compactMap(\.gapToNext)
                let cadenceOK = refCadence.isEmpty || takeCoreGaps.isEmpty
                    ? true
                    : Grader.rhythmDistance(takeCoreGaps, refCadence) <= thresholds.maxRhythmDistance
                for fragment in out.fragments {
                    let features: Grader.Features?
                    if fragment.kind == .gap {
                        features = nil
                    } else {
                        var f = Grader.features(raw: fragment.audio, sampleRate: sr,
                                                roomToneProfile: roomProfile, thresholds: thresholds)
                        f.clipped = clipped   // clipping is a take-level verdict, not a fragment one
                        features = f
                    }
                    // Per-kind quality gates the Grader can't see from features alone.
                    let dropoutOK = fragment.kind != .oneShotBody
                        || !Grader.dropoutRun(BreathAssembler.rmsEnvelope(fragment.audio, sampleRate: sr),
                                              sampleRate: sr, minGapSec: thresholds.dropoutMinGapSec)
                    let spacingOK = fragment.kind != .gulpCore
                        || (fragment.gapToNext.map { $0 >= minCoreSpacing } ?? true)
                    records.append(Record(
                        outName: outName, raw: fragment, features: features, lengthOK: lengthOK,
                        dropoutOK: dropoutOK, spacingOK: spacingOK,
                        cadenceOK: fragment.kind == .gulpCore ? cadenceOK : true
                    ))
                }
            }

            // Pass 2: grade each fragment against its siblings and append to the group's bank.
            for rec in records {
                if rec.raw.kind == .gap {
                    // Keep the segmenter's monotonic onset offsets so the bank's stable
                    // `(file, startFrame)` order replays the recorded cadence sequence.
                    group.fragments.append(Fragment(
                        file: rec.outName, startFrame: rec.raw.startFrame, endFrame: rec.raw.endFrame, kind: .gap,
                        accept: true, gapToNext: rec.raw.gapToNext
                    ))
                    continue
                }
                guard let features = rec.features else { continue }
                let verdict = Grader.grade(
                    features, siblings: siblings(for: rec, in: records),
                    gold: refProfile, lengthOK: rec.lengthOK,
                    dropoutOK: rec.dropoutOK, spacingOK: rec.spacingOK, cadenceOK: rec.cadenceOK,
                    thresholds: thresholds
                )
                group.fragments.append(Fragment(
                    file: rec.outName, startFrame: rec.raw.startFrame, endFrame: rec.raw.endFrame,
                    kind: rec.raw.kind, accept: verdict.accept, reason: verdict.reason,
                    qaScore: verdict.qaScore, anomalyScore: verdict.anomalyScore,
                    templateDistance: verdict.templateDistance,
                    peakHeight: rec.raw.peakHeight, gapToNext: rec.raw.gapToNext
                ))
            }
        }

        // Only takes that contribute at least one accepted, cache-backed fragment (grain / gulpCore)
        // need their prepared cache shipped — a fully-rejected take's cache would never be sliced.
        var neededCaches = Set<String>()
        for group in groups.values {
            for fragment in group.fragments where fragment.accept && (fragment.kind == .grain || fragment.kind == .gulpCore) {
                neededCaches.insert(FragmentBank.preparedCacheName(forTake: fragment.file))
            }
        }

        // Lay down audio into staging: re-encoded takes, the needed prepared caches, then sidecars + manifest.
        for (name, samples) in takesToWrite {
            try AudioIO.writeMonoWAV(samples, sampleRate: sr, to: staging.appendingPathComponent(name))
        }
        for (name, samples) in cachesToWrite where neededCaches.contains(name) {
            try AudioIO.writeMonoWAV(samples, sampleRate: sr, to: staging.appendingPathComponent(name))
        }

        var summaries: [BankSummary] = []
        var warnings: [String] = []
        for key in orderedKeys {
            let group = groups[key]!
            let bank = FragmentBank(
                style: key.style, type: key.type, sampleRate: sr, preparedSig: preparedSig,
                referenceTake: group.reference, roomToneProfile: roomToneOut, builtAt: builtAt,
                fragments: group.fragments
            )
            try bank.write(to: fragmentsDir.appendingPathComponent(bankFileName(key)))
            summaries.append(summary(for: key, group: group))
            if let warning = countedTakeWarning(key: key, group: group) { warnings.append(warning) }
        }

        let manifest = assembleManifest(
            orderedKeys: orderedKeys, groups: groups, takesToWrite: takesToWrite,
            sampleRate: sr, roomTone: roomToneOut
        )
        try manifest.write(to: staging.appendingPathComponent("manifest.json"))

        try promote(staging: staging, to: outDir)

        return BuildSummary(
            outDir: outDir.path, roomTone: roomToneOut, preparedSig: preparedSig,
            banks: summaries, warnings: warnings
        )
    }

    /// Regenerate the gitignored `*.prepared.wav` caches in a committed assets bundle from its committed
    /// takes + banks (the offsets the engine slices are stored in the banks; only the cache *audio* is
    /// derived and not committed). For each `(style, type)` with a `fragmentBank`, each take referenced
    /// by an accepted grain/gulpCore fragment is re-segmented and its `cacheSignal` written. Refuses a
    /// bank whose `preparedSig` doesn't match this config (a stale cache would mis-slice). Returns the
    /// cache filenames written. A bundle with no `fragmentBank` is a no-op.
    @discardableResult
    public static func regenerateCaches(
        assetsDir: URL, settings: AssemblerSettings = AssemblerSettings()
    ) throws -> [String] {
        let sr = settings.sampleRate
        let manifest = try BreathManifest.load(from: assetsDir.appendingPathComponent("manifest.json"))
        var roomProfile: [Float]?
        if let rt = manifest.noiseProfile,
           let samples = try? AudioIO.decodeMono(url: assetsDir.appendingPathComponent(rt), sampleRate: sr) {
            let profile = SpectralDenoise.magnitudeProfile(from: samples, sampleRate: sr)
            if !profile.isEmpty { roomProfile = profile }
        }
        let expectedSig = FragmentBank.preparedSignature(settings: settings, roomToneProfile: roomProfile)

        var written: [String] = []
        var done = Set<String>()
        for style in manifest.styles.keys.sorted() {
            for type in [BreathType.inhale, .exhale] {
                guard let name = manifest.palette(style: style, type: type)?.fragmentBank else { continue }
                let bank = try FragmentBank.load(from: assetsDir.appendingPathComponent(name))
                guard bank.preparedSig == expectedSig else {
                    throw BreathError.ioFailure(
                        "\(name): preparedSig \(bank.preparedSig) ≠ current config \(expectedSig) — rebuild the bank")
                }
                for fragment in bank.fragments where fragment.accept && (fragment.kind == .grain || fragment.kind == .gulpCore) {
                    let cacheName = FragmentBank.preparedCacheName(forTake: fragment.file)
                    guard done.insert(cacheName).inserted else { continue }
                    let raw = try AudioIO.decodeMono(url: assetsDir.appendingPathComponent(fragment.file), sampleRate: sr)
                    let out = Segmenter.segment(
                        rawTake: raw, role: fragment.kind == .grain ? "texture" : "cores",
                        type: bank.type, settings: settings, roomToneProfile: roomProfile
                    )
                    guard let cache = out.cacheSignal else { continue }
                    try AudioIO.writeMonoWAV(cache, sampleRate: sr, to: assetsDir.appendingPathComponent(cacheName))
                    written.append(cacheName)
                }
            }
        }
        return written.sorted()
    }

    /// Promote a fully-staged bundle into `outDir`: replace the tool-owned `fragments/` directory
    /// wholesale and overwrite any same-named top-level artifact, leaving unrelated files in `outDir`
    /// untouched. `outDir` is only written here — after all grading and staging succeeded — so a fault
    /// earlier in the build can never leave a partial bundle.
    private static func promote(staging: URL, to outDir: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: outDir, withIntermediateDirectories: true)
        let outFragments = outDir.appendingPathComponent("fragments")
        if fm.fileExists(atPath: outFragments.path) { try fm.removeItem(at: outFragments) }
        for item in try fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil) {
            let dest = outDir.appendingPathComponent(item.lastPathComponent)
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.moveItem(at: item, to: dest)
        }
    }

    /// A counted style renders by laying cores at a gaps take's cadence; warn (don't fail — a partial
    /// enrollment is still worth banking) when one side is missing, since the render needs both.
    private static func countedTakeWarning(key: GroupKey, group: Group) -> String? {
        guard group.renderMode == .counted else { return nil }
        let hasCores = group.fragments.contains { $0.kind == .gulpCore && $0.accept }
        let hasGaps = group.fragments.contains { $0.kind == .gap && $0.accept }
        guard !hasCores || !hasGaps else { return nil }
        let missing = [hasCores ? nil : "cores", hasGaps ? nil : "gap cadence"].compactMap { $0 }.joined(separator: " and ")
        return "\(key.style) \(key.type.rawValue): counted style has no accepted \(missing) — its render needs both."
    }

    // MARK: - Grading helpers

    /// Anomaly siblings: one-shot bodies compare across the step's takes (so a freak take is the
    /// outlier); grains and cores compare within their own take (a glitch mid-take is the outlier).
    /// The cross-take baseline excludes takes that already failed a signal/length check, so a clipped
    /// or wrong-length take can't skew the median/MAD a good take is graded against. (Within-take
    /// siblings share the take's verdict, so no such filtering is needed there.)
    private static func siblings(for rec: Record, in records: [Record]) -> [Grader.Features] {
        if rec.raw.kind == .oneShotBody {
            return records
                .filter { $0.raw.kind == .oneShotBody && $0.lengthOK && !($0.features?.clipped ?? false) }
                .compactMap(\.features)
        }
        return records
            .filter { $0.outName == rec.outName && $0.raw.kind == rec.raw.kind }
            .compactMap(\.features)
    }

    private static func lengthWithinBounds(_ seconds: Double, min: Double?, max: Double?) -> Bool {
        if let min, seconds < min { return false }
        if let max, seconds > max { return false }
        return true
    }

    /// The grading template for one step's role: segment the gold reference the same way and average
    /// its fragment spectra into one 513-bin profile. `nil` when there's no reference (→ no template
    /// rejection) or it yields no usable fragment.
    private static func referenceProfile(
        _ url: URL, role: String, type: BreathType,
        settings: AssemblerSettings, roomProfile: [Float]?
    ) -> [Float]? {
        guard FileManager.default.fileExists(atPath: url.path),
              let raw = try? AudioIO.decodeMono(url: url, sampleRate: settings.sampleRate) else { return nil }
        let out = Segmenter.segment(
            rawTake: raw, role: role, type: type, settings: settings, roomToneProfile: roomProfile
        )
        let profiles = out.fragments
            .filter { $0.kind != .gap }
            .map { SpectralDenoise.magnitudeProfile(from: $0.audio, sampleRate: settings.sampleRate) }
            .filter { !$0.isEmpty }
        return averageProfiles(profiles)
    }

    /// The gold reference's packing cadence — its gulp-core inter-onset gaps — for the cadence gate.
    private static func referenceCadence(
        _ url: URL, type: BreathType, settings: AssemblerSettings, roomProfile: [Float]?
    ) -> [Int]? {
        guard FileManager.default.fileExists(atPath: url.path),
              let raw = try? AudioIO.decodeMono(url: url, sampleRate: settings.sampleRate) else { return nil }
        let out = Segmenter.segment(
            rawTake: raw, role: "cores", type: type, settings: settings, roomToneProfile: roomProfile
        )
        let gaps = out.fragments.filter { $0.kind == .gulpCore }.compactMap(\.gapToNext)
        return gaps.isEmpty ? nil : gaps
    }

    private static func averageProfiles(_ profiles: [[Float]]) -> [Float]? {
        guard let n = profiles.first?.count, n > 0 else { return nil }
        var acc = [Float](repeating: 0, count: n)
        var used = 0
        for p in profiles where p.count == n {
            for i in 0..<n { acc[i] += p[i] }
            used += 1
        }
        guard used > 0 else { return nil }
        let inv = 1 / Float(used)
        for i in 0..<n { acc[i] *= inv }
        return acc
    }

    // MARK: - Manifest assembly

    private static func assembleManifest(
        orderedKeys: [GroupKey], groups: [GroupKey: Group],
        takesToWrite: [String: [Float]], sampleRate sr: Double, roomTone: String?
    ) -> BreathManifest {
        var styleManifests: [String: StyleManifest] = [:]
        for style in orderedSet(orderedKeys.map(\.style)) {
            var inhale = RolePalette()
            var exhale = RolePalette()
            var render: RenderMode?
            for key in orderedKeys where key.style == style {
                let group = groups[key]!
                let palette = makePalette(key: key, group: group, takesToWrite: takesToWrite, sampleRate: sr)
                if key.type == .inhale { inhale = palette } else { exhale = palette }
                // A style's two directions share one render mode in our catalog; carry the non-default.
                if group.renderMode != .textured { render = group.renderMode }
            }
            styleManifests[style] = StyleManifest(inhale: inhale, exhale: exhale, render: render)
        }
        return BreathManifest(version: BreathManifest.currentVersion, styles: styleManifests, noiseProfile: roomTone)
    }

    private static func makePalette(
        key: GroupKey, group: Group, takesToWrite: [String: [Float]], sampleRate sr: Double
    ) -> RolePalette {
        let oneShot = group.orderedTakeNames().compactMap { name -> BreathAsset? in
            guard let samples = takesToWrite[name] else { return nil }
            return BreathAsset(file: name, durationSec: Double(samples.count) / sr, sampleRate: sr, channels: 1)
        }
        return RolePalette(oneShot: oneShot, fragmentBank: "fragments/\(bankFileName(key))")
    }

    // MARK: - Summary

    private static func summary(for key: GroupKey, group: Group) -> BankSummary {
        var kindCounts: [String: (accepted: Int, total: Int)] = [:]
        var rejectReasons: [String: Int] = [:]
        for fragment in group.fragments {
            let k = fragment.kind.rawValue
            var entry = kindCounts[k] ?? (0, 0)
            entry.total += 1
            if fragment.accept { entry.accepted += 1 } else if let reason = fragment.reason {
                rejectReasons[reason, default: 0] += 1
            }
            kindCounts[k] = entry
        }
        return BankSummary(style: key.style, type: key.type, kindCounts: kindCounts, rejectReasons: rejectReasons)
    }

    // MARK: - Naming

    private static func outTakeName(forCaptureFile file: String) -> String {
        (file as NSString).deletingPathExtension + ".wav"
    }

    private static func bankFileName(_ key: GroupKey) -> String {
        "\(key.style)_\(key.type.rawValue).frags.json"
    }

    private static func orderedSet(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}

// MARK: - Builder-private accumulators

private struct GroupKey: Hashable {
    var style: String
    var type: BreathType
}

private struct Record {
    var outName: String
    var raw: Segmenter.Raw
    var features: Grader.Features?
    var lengthOK: Bool
    var dropoutOK: Bool = true
    var spacingOK: Bool = true
    var cadenceOK: Bool = true
}

/// Per-(style, type) accumulator: the bank's fragments plus the take ordering for the manifest's
/// `oneShot` list. Packing needs a `cores` take at index 0 and a `gaps` take at index 1 (the engine's
/// pre-pool counted path reads exactly those two); other styles list their takes in encounter order.
private final class Group {
    let renderMode: RenderMode
    let reference: String?
    var fragments: [Fragment] = []
    private var coresNames: [String] = []
    private var gapsNames: [String] = []
    private var plainNames: [String] = []

    init(renderMode: RenderMode, reference: String?) {
        self.renderMode = renderMode
        self.reference = reference
    }

    func record(takeName: String, role: String) {
        switch role {
        case "cores": if !coresNames.contains(takeName) { coresNames.append(takeName) }
        case "gaps": if !gapsNames.contains(takeName) { gapsNames.append(takeName) }
        default: if !plainNames.contains(takeName) { plainNames.append(takeName) }
        }
    }

    func orderedTakeNames() -> [String] {
        guard !coresNames.isEmpty || !gapsNames.isEmpty else { return plainNames }
        var names: [String] = []
        if let first = coresNames.first { names.append(first) }
        if let first = gapsNames.first { names.append(first) }
        names.append(contentsOf: coresNames.dropFirst())
        names.append(contentsOf: gapsNames.dropFirst())
        return names
    }
}
