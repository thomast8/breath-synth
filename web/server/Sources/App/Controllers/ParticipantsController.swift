import Fluent
import Vapor

struct ParticipantsController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let participants = routes.grouped("api", "participants")
        participants.post(use: create)
    }

    @Sendable
    func create(req: Request) async throws -> Participant {
        let body = try req.content.decode(ParticipantCreateRequest.self)

        if let required = req.application.inviteCode {
            guard let supplied = body.inviteCode, ConstantTimeCompare.equals(supplied, required) else {
                throw Abort(.unauthorized, reason: "Invalid or missing invite code")
            }
        }

        let participant = Participant(
            pseudonym: body.pseudonym,
            experienceLevel: body.experienceLevel,
            consentVersion: body.consentVersion,
            consentedAt: Date()
        )
        try await participant.save(on: req.db)
        return participant
    }
}
