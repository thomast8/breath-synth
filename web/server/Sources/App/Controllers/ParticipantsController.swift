import Fluent
import Vapor

struct ParticipantsController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let participants = routes.grouped("api", "participants")
        participants.post(use: create)
        participants.delete(":participantID", use: delete)
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
            consentVersion: body.consentVersion,
            consentedAt: Date()
        )
        try await participant.save(on: req.db)
        return participant
    }

    /// Self-serve deletion: the participant's own ID (an unguessable UUID, shown only to them on
    /// the done screen) is the sole capability token — no other auth, by design. Cascades through
    /// every session's takes and stored audio before removing the sessions and the participant row
    /// itself, so nothing is left dangling in either Postgres or the storage root. A storage
    /// failure is logged but doesn't block the database rows from being removed — the DB rows are
    /// the primary guarantee "your data is gone from our records"; a stuck file needs the operator
    /// to notice and clean up separately, not a participant left un-deleted.
    @Sendable
    func delete(req: Request) async throws -> HTTPStatus {
        guard let participantID = req.parameters.get("participantID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid participant ID")
        }
        guard let participant = try await Participant.find(participantID, on: req.db) else {
            throw Abort(.notFound)
        }

        let sessions = try await EnrollSession.query(on: req.db)
            .filter(\.$participant.$id == participantID)
            .all()

        for session in sessions {
            guard let sessionID = session.id else { continue }
            try await Take.query(on: req.db).filter(\.$session.$id == sessionID).delete()
            do {
                try await req.application.storageDriver.delete(prefix: "sessions/\(sessionID)/")
            } catch {
                req.logger.error(
                    "participant \(participantID) deletion: failed to remove storage for session \(sessionID): \(error)"
                )
            }
            try await session.delete(on: req.db)
        }

        try await participant.delete(on: req.db)
        return .noContent
    }
}
