import Fluent
import Vapor

struct SessionsController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let sessions = routes.grouped("api", "sessions")
        sessions.post(use: create)
        sessions.group(":sessionID") { session in
            session.post("room-tone", use: uploadRoomTone)
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

    /// Stores the room-tone recording and spins up this session's `LiveTakeGrader` — every
    /// subsequent `POST /api/takes` for this session grades against it, exactly as the native app's
    /// `EnrollModel` creates `liveGrader` once room tone is written.
    @Sendable
    func uploadRoomTone(req: Request) async throws -> EnrollSession {
        let sessionID = try req.parameters.require("sessionID", as: UUID.self)
        guard let session = try await EnrollSession.find(sessionID, on: req.db) else {
            throw Abort(.notFound)
        }
        let body = try req.content.decode(RoomToneUploadRequest.self)

        let objectKey = "sessions/\(sessionID)/room_tone.wav"
        try await req.application.storageDriver.put(body.audio, key: objectKey)
        session.roomToneObjectKey = objectKey
        try await session.save(on: req.db)

        let localURL = try await req.application.storageDriver.localURL(forKey: objectKey)
        await req.application.gradingSessions.makeGrader(sessionID: sessionID, roomToneURL: localURL)

        return session
    }

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
        await req.application.gradingSessions.removeGrader(sessionID: sessionID)
        return session
    }
}
