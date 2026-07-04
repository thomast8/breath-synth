import Fluent
import Vapor

public enum TakeStatus: String, Codable, CaseIterable, Sendable {
    case kept
    case redone
}

/// One recorded segment of the enrollment script — a lane's take (`captures.json`'s per-lane
/// `files` entries once exported). Redone takes keep their row and blob (`status` flips to
/// `.redone`, never deleted) — mirrors the native `Fragment`'s keep-with-reason audit-trail
/// philosophy, and means an abandoned session still contributes usable takes.
public final class Take: Model, Content, @unchecked Sendable {
    public static let schema = "takes"

    @ID(key: .id)
    public var id: UUID?

    @Parent(key: "session_id")
    public var session: EnrollSession

    @Field(key: "step_slug")
    public var stepSlug: String

    @Field(key: "lane_slug")
    public var laneSlug: String

    @Field(key: "style")
    public var style: String

    /// Raw string, not `BreathType`/`RenderMode` directly — Fluent's `@Enum` needs its own migration
    /// case list, and pinning these to the engine's exact Codable raw values (`"inhale"`/`"exhale"`,
    /// `"textured"`/`"oneShot"`/`"counted"`) as plain strings is what keeps the exporter's
    /// `CaptureSession` JSON byte-identical to what `BreathType`/`RenderMode` would encode, without a
    /// second enum definition to keep in sync.
    @Field(key: "breath_type")
    public var breathType: String

    @Field(key: "render_mode")
    public var renderMode: String

    @Field(key: "role")
    public var role: String

    @Field(key: "take_index")
    public var takeIndex: Int

    @OptionalField(key: "reference")
    public var reference: String?

    @Field(key: "object_key")
    public var objectKey: String

    @Field(key: "duration_sec")
    public var durationSec: Double

    @Field(key: "sample_rate")
    public var sampleRate: Double

    @OptionalField(key: "peak")
    public var peak: Double?

    @OptionalField(key: "rms")
    public var rms: Double?

    @Field(key: "verdict_accept")
    public var verdictAccept: Bool

    @OptionalField(key: "verdict_reason")
    public var verdictReason: String?

    @Field(key: "verdict_advisory")
    public var verdictAdvisory: [String]

    @OptionalField(key: "fragments_accepted")
    public var fragmentsAccepted: Int?

    @OptionalField(key: "fragments_total")
    public var fragmentsTotal: Int?

    @Enum(key: "status")
    public var status: TakeStatus

    /// Free-form per-take diagnostics (client-reported level/clip stats, server verdict detail) —
    /// the web analogue of the native app's `spectral_diagnostics.json` sidecar: field data for a
    /// future classifier, not read by any current pipeline.
    @OptionalField(key: "client_meta")
    public var clientMeta: [String: String]?

    @Timestamp(key: "created_at", on: .create)
    public var createdAt: Date?

    public init() {}

    public init(
        id: UUID? = nil, sessionID: EnrollSession.IDValue, stepSlug: String, laneSlug: String,
        style: String, breathType: String, renderMode: String, role: String, takeIndex: Int,
        reference: String?, objectKey: String, durationSec: Double, sampleRate: Double,
        peak: Double?, rms: Double?, verdictAccept: Bool, verdictReason: String?,
        verdictAdvisory: [String], fragmentsAccepted: Int?, fragmentsTotal: Int?,
        status: TakeStatus, clientMeta: [String: String]?
    ) {
        self.id = id
        self.$session.id = sessionID
        self.stepSlug = stepSlug
        self.laneSlug = laneSlug
        self.style = style
        self.breathType = breathType
        self.renderMode = renderMode
        self.role = role
        self.takeIndex = takeIndex
        self.reference = reference
        self.objectKey = objectKey
        self.durationSec = durationSec
        self.sampleRate = sampleRate
        self.peak = peak
        self.rms = rms
        self.verdictAccept = verdictAccept
        self.verdictReason = verdictReason
        self.verdictAdvisory = verdictAdvisory
        self.fragmentsAccepted = fragmentsAccepted
        self.fragmentsTotal = fragmentsTotal
        self.status = status
        self.clientMeta = clientMeta
    }
}
