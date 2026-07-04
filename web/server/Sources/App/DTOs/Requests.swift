import Vapor

struct ParticipantCreateRequest: Content {
    var inviteCode: String?
    var pseudonym: String?
    var experienceLevel: ExperienceLevel
    var consentVersion: String
}

struct SessionCreateRequest: Content {
    var participantID: UUID
    var scriptVersion: String
    var sampleRate: Double
    var userAgent: String?
    var micConstraintsActual: [String: String]?
}

/// Multipart upload: `audio` is the file part, everything else is a text field. Vapor's `Content`
/// decoder matches multipart part names to these properties by name.
struct RoomToneUploadRequest: Content {
    var sampleRate: Double
    var audio: Data
}

struct TakeUploadRequest: Content {
    var stepSlug: String
    var laneSlug: String
    var style: String
    var breathType: String
    var renderMode: String
    var role: String
    var takeIndex: Int
    var reference: String?
    var minSeconds: Double?
    var maxSeconds: Double?
    var sampleRate: Double
    var clientMeta: [String: String]?
    var audio: Data
}

struct SessionCompleteRequest: Content {
    var status: SessionStatus
}

struct TakeVerdictResponse: Content {
    var takeID: UUID
    var accept: Bool
    var reason: String?
    var advisory: [String]
    var fragmentsAccepted: Int
    var fragmentsTotal: Int
}
