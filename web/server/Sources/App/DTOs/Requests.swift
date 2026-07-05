import Vapor

struct ParticipantCreateRequest: Content {
    var inviteCode: String?
    var pseudonym: String?
    var consentVersion: String
}

struct SessionCreateRequest: Content {
    var participantID: UUID
    var scriptVersion: String
    var sampleRate: Double
    var userAgent: String?
    var micConstraintsActual: [String: String]?
}

struct SessionCompleteRequest: Content {
    var status: SessionStatus
}
