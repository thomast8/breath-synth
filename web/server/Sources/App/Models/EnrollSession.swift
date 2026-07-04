import Fluent
import Vapor

public enum SessionStatus: String, Codable, CaseIterable, Sendable {
    case inProgress = "in_progress"
    case completed
    case abandoned
}

/// One enrollment session: a participant walking the six-step script once. Named `EnrollSession`
/// (not `Session`) to avoid colliding with Vapor's own `Session` type.
public final class EnrollSession: Model, Content, @unchecked Sendable {
    public static let schema = "sessions"

    @ID(key: .id)
    public var id: UUID?

    @Parent(key: "participant_id")
    public var participant: Participant

    @Enum(key: "status")
    public var status: SessionStatus

    @Field(key: "script_version")
    public var scriptVersion: String

    @Field(key: "sample_rate")
    public var sampleRate: Double

    @OptionalField(key: "user_agent")
    public var userAgent: String?

    /// What the browser's `MediaTrackSettings` actually reported (echoCancellation/noiseSuppression/
    /// autoGainControl/sampleRate/...) — some mobile browsers ignore the requested constraints, and
    /// this is exactly the provenance a future classifier wants per-take, tracked at the session level
    /// since it's fixed for the whole capture.
    @OptionalField(key: "mic_constraints_actual")
    public var micConstraintsActual: [String: String]?

    @OptionalField(key: "room_tone_object_key")
    public var roomToneObjectKey: String?

    @Timestamp(key: "started_at", on: .create)
    public var startedAt: Date?

    @OptionalField(key: "completed_at")
    public var completedAt: Date?

    public init() {}

    public init(
        id: UUID? = nil, participantID: Participant.IDValue, status: SessionStatus = .inProgress,
        scriptVersion: String, sampleRate: Double, userAgent: String?
    ) {
        self.id = id
        self.$participant.id = participantID
        self.status = status
        self.scriptVersion = scriptVersion
        self.sampleRate = sampleRate
        self.userAgent = userAgent
    }
}
