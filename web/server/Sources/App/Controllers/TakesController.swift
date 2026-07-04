import BreathBank
import BreathEngineCore
import Fluent
import Vapor

struct TakesController: RouteCollection {
    /// Defensive caps against a public link filling storage with junk — not a product decision
    /// about legitimate session size (25 s takes across ~20 lanes is nowhere near either limit).
    static let maxTakeBytes = 10_000_000
    static let maxTakesPerSession = 500

    func boot(routes: any RoutesBuilder) throws {
        routes.grouped("api", "sessions", ":sessionID", "takes").post(use: create)
    }

    @Sendable
    func create(req: Request) async throws -> TakeVerdictResponse {
        let sessionID = try req.parameters.require("sessionID", as: UUID.self)
        guard try await EnrollSession.find(sessionID, on: req.db) != nil else {
            throw Abort(.notFound, reason: "Unknown session")
        }
        let body = try req.content.decode(TakeUploadRequest.self)

        // Every one of these ends up as a path component (object storage key, and — for
        // `reference` — an argument to LiveTakeGrader's own unvalidated
        // `assetsDir.appendingPathComponent(reference)`), so a crafted client payload containing
        // ".." or "/" must be rejected before it ever reaches a file-system call.
        for candidate in [body.stepSlug, body.laneSlug] {
            guard SlugValidation.isSafe(candidate) else {
                throw Abort(.badRequest, reason: "Invalid slug")
            }
        }
        if let reference = body.reference {
            guard SlugValidation.isSafe(reference) else {
                throw Abort(.badRequest, reason: "Invalid reference")
            }
        }

        guard body.audio.count <= Self.maxTakeBytes else {
            throw Abort(.payloadTooLarge, reason: "Take exceeds \(Self.maxTakeBytes) bytes")
        }
        let existingCount = try await Take.query(on: req.db)
            .filter(\.$session.$id == sessionID)
            .count()
        guard existingCount < Self.maxTakesPerSession else {
            throw Abort(.conflict, reason: "Session has reached its take limit")
        }

        guard let grader = await req.application.gradingSessions.grader(for: sessionID) else {
            throw Abort(.conflict, reason: "Room tone must be uploaded before takes")
        }

        let objectKey = "sessions/\(sessionID)/raw/\(body.laneSlug)_take\(body.takeIndex).wav"
        try await req.application.storageDriver.put(body.audio, key: objectKey)
        let localURL = try await req.application.storageDriver.localURL(forKey: objectKey)

        let breathType: BreathType = body.breathType == "exhale" ? .exhale : .inhale
        let verdict = await grader.grade(
            fileURL: localURL, style: body.style, role: body.role, type: breathType,
            reference: body.reference, minSeconds: body.minSeconds, maxSeconds: body.maxSeconds
        )

        // Supersede any prior "kept" row at this exact (lane, take index) slot — never delete, just
        // flip its status, so a redo history stays fully auditable (mirrors the native Fragment's
        // keep-with-reason philosophy).
        if let previous = try await Take.query(on: req.db)
            .filter(\.$session.$id == sessionID)
            .filter(\.$laneSlug == body.laneSlug)
            .filter(\.$takeIndex == body.takeIndex)
            .filter(\.$status == .kept)
            .first()
        {
            previous.status = .redone
            try await previous.save(on: req.db)
        }

        let probed = try? AudioIO.probe(url: localURL)
        let take = Take(
            sessionID: sessionID, stepSlug: body.stepSlug, laneSlug: body.laneSlug, style: body.style,
            breathType: breathType.rawValue, renderMode: body.renderMode, role: body.role,
            takeIndex: body.takeIndex, reference: body.reference, objectKey: objectKey,
            durationSec: probed?.durationSec ?? 0, sampleRate: probed?.sampleRate ?? body.sampleRate,
            peak: nil, rms: nil, verdictAccept: verdict.accept, verdictReason: verdict.reason,
            verdictAdvisory: verdict.advisory, fragmentsAccepted: verdict.fragmentsAccepted,
            fragmentsTotal: verdict.fragmentsTotal, status: .kept, clientMeta: body.clientMeta
        )
        try await take.save(on: req.db)

        return TakeVerdictResponse(
            takeID: try take.requireID(), accept: verdict.accept, reason: verdict.reason,
            advisory: verdict.advisory, fragmentsAccepted: verdict.fragmentsAccepted,
            fragmentsTotal: verdict.fragmentsTotal
        )
    }
}
