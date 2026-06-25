import Foundation

/// What kind of sub-take fragment a `Fragment` is. The render path differs per kind:
/// `grain` (a window of energy-flat sustain texture, pooled into a granular loop — calm/RV/FRC
/// timbre), `gulpCore` (a declicked packing event), `gap` (an inter-onset silence carried as a
/// frame count), `oneShotBody` (a whole graded one-shot maneuver — frc/rv).
public enum FragmentKind: String, Codable, Sendable, CaseIterable {
    case grain
    case gulpCore
    case gap
    case oneShotBody
}

/// One graded sub-take fragment: an offset range into a *prepared* take (the `prepareSource`
/// output), plus its grades. Rejected fragments are kept (`accept == false` + a `reason`) so a
/// take is never discarded for a few bad fragments and the bank stays auditable / re-gradable.
public struct Fragment: Codable, Sendable, Equatable {
    /// The source take's filename (provenance). The engine loads `<file>`'s prepared cache.
    public var file: String
    /// Inclusive start offset into the PREPARED source, at `FragmentBank.sampleRate`.
    public var startFrame: Int
    /// Exclusive end offset into the PREPARED source.
    public var endFrame: Int
    public var kind: FragmentKind
    public var accept: Bool
    /// Reject reason code when `accept == false` (audit trail).
    public var reason: String?
    // Persisted grader sub-scores — nil until graded.
    public var qaScore: Double?
    public var anomalyScore: Double?
    public var templateDistance: Double?
    /// gulpCore only: envelope peak height, used for selection/cadence.
    public var peakHeight: Float?
    /// gulpCore / gap: inter-onset samples to the next event.
    public var gapToNext: Int?

    public init(
        file: String,
        startFrame: Int,
        endFrame: Int,
        kind: FragmentKind,
        accept: Bool,
        reason: String? = nil,
        qaScore: Double? = nil,
        anomalyScore: Double? = nil,
        templateDistance: Double? = nil,
        peakHeight: Float? = nil,
        gapToNext: Int? = nil
    ) {
        self.file = file
        self.startFrame = startFrame
        self.endFrame = endFrame
        self.kind = kind
        self.accept = accept
        self.reason = reason
        self.qaScore = qaScore
        self.anomalyScore = anomalyScore
        self.templateDistance = templateDistance
        self.peakHeight = peakHeight
        self.gapToNext = gapToNext
    }

    /// Frames the fragment spans in the prepared source.
    public var frameCount: Int { max(0, endFrame - startFrame) }
}

/// A per-(style, type) bank of graded sub-take fragments, built offline by the app-layer
/// `breath-bank` tool and consumed read-only by the engine. A sidecar to the manifest, mirroring
/// the `noiseProfile` pattern: the manifest names the file, the engine loads it as data and applies
/// no grading policy of its own.
public struct FragmentBank: Codable, Sendable, Equatable {
    public var version: Int
    public var style: String
    public var type: BreathType
    /// The working sample rate the fragment offsets are expressed in.
    public var sampleRate: Double
    /// Hash of the `prepareSource` params the fragments were cut under. The engine refuses a bank
    /// whose `preparedSig` doesn't match its current prepare config rather than mis-slicing.
    public var preparedSig: String
    /// Gold reference take filename (the grading template); builder-only, never loaded by the engine.
    public var referenceTake: String?
    /// Session room-tone profile filename used for SNR grading.
    public var roomToneProfile: String?
    /// When the bank was built (ISO-8601); informational.
    public var builtAt: String
    public var fragments: [Fragment]

    public static let currentVersion = 1

    public init(
        version: Int = FragmentBank.currentVersion,
        style: String,
        type: BreathType,
        sampleRate: Double = AudioConstants.workingSampleRate,
        preparedSig: String,
        referenceTake: String? = nil,
        roomToneProfile: String? = nil,
        builtAt: String = "",
        fragments: [Fragment] = []
    ) {
        self.version = version
        self.style = style
        self.type = type
        self.sampleRate = sampleRate
        self.preparedSig = preparedSig
        self.referenceTake = referenceTake
        self.roomToneProfile = roomToneProfile
        self.builtAt = builtAt
        self.fragments = fragments
    }

    /// Accepted fragments of one kind, in stable `(file, startFrame)` order — the deterministic
    /// draw order the engine samples from, so a given seed always selects the same fragments and a
    /// regrade (flipping `accept`) changes the pool deterministically.
    public func acceptedFragments(kind: FragmentKind) -> [Fragment] {
        fragments
            .filter { $0.accept && $0.kind == kind }
            .sorted { ($0.file, $0.startFrame) < ($1.file, $1.startFrame) }
    }

    // MARK: - Disk I/O

    public static func load(from url: URL) throws -> FragmentBank {
        let data = try Data(contentsOf: url)
        let bank = try JSONDecoder().decode(FragmentBank.self, from: data)
        guard bank.version <= currentVersion else {
            throw BreathError.unsupportedBankVersion(found: bank.version, supported: currentVersion)
        }
        return bank
    }

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
