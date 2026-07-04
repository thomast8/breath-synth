import Fluent
import Vapor

struct SessionsController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let sessions = routes.grouped("api", "sessions")
        sessions.post(use: create)
        sessions.group(":sessionID") { session in
            session.post("complete", use: complete)
        }
    }

    @Sendable
    func create(req: Request) async throws -> EnrollSession {
        let body = try req.content.decode(SessionCreateRequest.self)
        guard try await Participant.find(body.participantID, on: req.db) != nil else {
            throw Abort(.notFound, reason: "Unknown participant")
        }
        let session = EnrollSession(
            participantID: body.participantID,
            scriptVersion: body.scriptVersion,
            sampleRate: body.sampleRate,
            userAgent: body.userAgent
        )
        session.micConstraintsActual = body.micConstraintsActual
        try await session.save(on: req.db)
        return session
    }

    /// Called by the client once it's done with the live-capture WebSocket (either the session ran to
    /// completion, or the participant bailed early) — room tone and take capture themselves are entirely
    /// the WS flow's job now (`EnrollmentSocketController`); this just records the session's final status.
    @Sendable
    func complete(req: Request) async throws -> EnrollSession {
        let sessionID = try req.parameters.require("sessionID", as: UUID.self)
        guard let session = try await EnrollSession.find(sessionID, on: req.db) else {
            throw Abort(.notFound)
        }
        let body = try req.content.decode(SessionCompleteRequest.self)
        session.status = body.status
        session.completedAt = Date()
        try await session.save(on: req.db)
        return session
    }
}
