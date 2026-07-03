import BreathEngine
import Foundation

/// Session-scoped live per-take grading, the coarse content backstop above `CaptureAnalyzer`'s
/// per-event spectral gate: it catches whole-take problems per-event features can't (a clipped take, a
/// too-short/long take, a cough-contaminated or off-technique fragment) so the enrollment app can offer
/// an in-session redo. Runs off the main actor (an `actor`, so concurrent lane grading — e.g. calm's
/// inhale + exhale — serializes safely on its own cached state). Reuses `TakeGrading`'s per-fragment
/// derivation and `Grader`'s verdicts exactly as the offline `BankBuilder` does; **the offline build
/// stays authoritative** — this is guidance for the session, not a replacement for it.
public actor LiveTakeGrader {
    /// One take's live grade. `reason` is set only when `accept` is false (the worst-ranked failing
    /// gate, by `Grader`'s own check order — clipped/length first, person-dependent gates last).
    /// `advisory` carries findings from any fragment that failed a *person-dependent* gate
    /// (`off_technique`, `cadence_drift`, `outlier`) even on an otherwise-accepted take — the app's redo
    /// policy treats these as informational, not redo-worthy (auto-redoing against the bundled gold's
    /// spectrum/cadence would recreate the blind-retry loop this feature exists to avoid).
    public struct TakeVerdict: Sendable {
        public var accept: Bool
        public var reason: String?
        public var advisory: [String]
        public var fragmentsAccepted: Int
        public var fragmentsTotal: Int

        public init(accept: Bool, reason: String?, advisory: [String], fragmentsAccepted: Int, fragmentsTotal: Int) {
            self.accept = accept
            self.reason = reason
            self.advisory = advisory
            self.fragmentsAccepted = fragmentsAccepted
            self.fragmentsTotal = fragmentsTotal
        }
    }

    /// Reason strings in `Grader.grade`'s own check order — first-checked is treated as "worst" when a
    /// fully-rejected take's fragments failed for more than one reason.
    private static let reasonSeverityOrder = [
        "clipped", "length", "dropout", "low_snr", "merged_gulp", "off_technique", "cadence_drift", "outlier",
    ]

    private let assetsDir: URL
    private let settings: AssemblerSettings
    private let thresholds: Grader.Thresholds
    private let roomProfile: [Float]?
    private var goldProfiles: [String: [Float]?] = [:]
    private var goldCadences: [String: [Int]] = [:]
    /// Per-lane (role|type|reference) accumulated fragment features, for the anomaly gate's sibling
    /// comparison — grows as the session's takes are graded, exactly like the offline builder's
    /// cross-take/within-take sibling sets, just accumulated live instead of all at once.
    private var siblingsByLane: [String: [Grader.Features]] = [:]

    /// `roomToneURL` is the just-written room-tone capture (e.g. `capturesDir/room_tone.caf`) — decoded
    /// directly. Unlike `BankBuilder`, there's no write-then-redecode round trip here: that dance exists
    /// only to keep the *shipped bank's* `preparedSig` consistent across build/render/regenerate: the
    /// live grader ships nothing, so decoding the original capture directly is both correct and simpler.
    public init(
        roomToneURL: URL?, assetsDir: URL,
        settings: AssemblerSettings = AssemblerSettings(), thresholds: Grader.Thresholds = .default
    ) {
        self.assetsDir = assetsDir
        self.settings = settings
        self.thresholds = thresholds
        if let roomToneURL, let samples = try? AudioIO.decodeMono(url: roomToneURL, sampleRate: settings.sampleRate) {
            let profile = SpectralDenoise.magnitudeProfile(from: samples, sampleRate: settings.sampleRate)
            roomProfile = profile.isEmpty ? nil : profile
        } else {
            roomProfile = nil
        }
    }

    /// Grade one just-written take. `reference` is the gold asset filename (in `assetsDir`) for this
    /// lane's role/type, or `nil` when the style has none (e.g. recovery). Decodes `fileURL` the same
    /// way the offline builder decodes a take, so a verdict here and the eventual `breath-bank build`
    /// verdict are computed from identical per-fragment facts (sibling sets differ, by design).
    public func grade(
        fileURL: URL, role: String, type: BreathType, reference: String?,
        minSeconds: Double?, maxSeconds: Double?
    ) async -> TakeVerdict {
        guard let raw = try? AudioIO.decodeMono(url: fileURL, sampleRate: settings.sampleRate) else {
            return TakeVerdict(accept: false, reason: "unreadable", advisory: [], fragmentsAccepted: 0, fragmentsTotal: 0)
        }

        let goldProfile = goldProfile(forReference: reference, role: role, type: type)
        let goldCadence = goldCadence(forReference: reference, role: role, type: type)
        let result = TakeGrading.gradeTake(
            raw: raw, role: role, type: type, settings: settings, roomToneProfile: roomProfile,
            goldCadence: goldCadence, minSeconds: minSeconds, maxSeconds: maxSeconds, thresholds: thresholds
        )

        // Take-level facts reject regardless of any individual fragment's verdict.
        if result.clipped {
            return TakeVerdict(accept: false, reason: "clipped", advisory: [], fragmentsAccepted: 0, fragmentsTotal: result.records.count)
        }
        if !result.lengthOK {
            return TakeVerdict(accept: false, reason: "length", advisory: [], fragmentsAccepted: 0, fragmentsTotal: result.records.count)
        }

        let laneKey = Self.laneKey(role: role, type: type, reference: reference)
        let siblings = siblingsByLane[laneKey] ?? []
        var accepted = 0
        var failReasons: [String] = []
        var newFeatures: [Grader.Features] = []
        for record in result.records {
            if record.raw.kind == .gap {
                // Gap fragments carry no audio-based verdict here — Phase 5 grades cadence takes;
                // Phase 4's live backstop only covers audio-bearing fragments.
                accepted += 1
                continue
            }
            guard let features = record.features else { continue }
            let verdict = Grader.grade(
                features, siblings: siblings, gold: goldProfile, lengthOK: record.lengthOK,
                dropoutOK: record.dropoutOK, spacingOK: record.spacingOK, cadenceOK: record.cadenceOK,
                thresholds: thresholds
            )
            if verdict.accept {
                accepted += 1
            } else if let reason = verdict.reason {
                failReasons.append(reason)
            }
            newFeatures.append(features)
        }
        siblingsByLane[laneKey, default: []].append(contentsOf: newFeatures)

        let total = result.records.count
        if accepted == 0, !failReasons.isEmpty {
            return TakeVerdict(accept: false, reason: Self.worstReason(among: failReasons), advisory: [],
                               fragmentsAccepted: 0, fragmentsTotal: total)
        }
        let advisory = Array(Set(failReasons)).sorted()
        return TakeVerdict(accept: true, reason: nil, advisory: advisory, fragmentsAccepted: accepted, fragmentsTotal: total)
    }

    private static func worstReason(among reasons: [String]) -> String {
        reasons.min {
            (reasonSeverityOrder.firstIndex(of: $0) ?? .max) < (reasonSeverityOrder.firstIndex(of: $1) ?? .max)
        } ?? reasons[0]
    }

    private static func laneKey(role: String, type: BreathType, reference: String?) -> String {
        "\(role)|\(type.rawValue)|\(reference ?? "")"
    }

    private func goldProfile(forReference reference: String?, role: String, type: BreathType) -> [Float]? {
        guard let reference else { return nil }
        let key = Self.laneKey(role: role, type: type, reference: reference)
        if let cached = goldProfiles[key] { return cached }
        let profile = BankBuilder.referenceProfile(
            assetsDir.appendingPathComponent(reference), role: role, type: type,
            settings: settings, roomProfile: roomProfile
        )
        goldProfiles[key] = profile
        return profile
    }

    private func goldCadence(forReference reference: String?, role: String, type: BreathType) -> [Int] {
        guard role == "cores", let reference else { return [] }
        let key = Self.laneKey(role: role, type: type, reference: reference)
        if let cached = goldCadences[key] { return cached }
        let cadence = BankBuilder.referenceCadence(
            assetsDir.appendingPathComponent(reference), type: type, settings: settings, roomProfile: roomProfile
        ) ?? []
        goldCadences[key] = cadence
        return cadence
    }
}
