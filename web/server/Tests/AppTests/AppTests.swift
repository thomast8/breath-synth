import Fluent
import FluentSQLiteDriver
import XCTVapor

@testable import App

final class AppTests: XCTestCase {
    private func makeTestApp() async throws -> Application {
        let app = try await Application.make(.testing)
        app.databases.use(.sqlite(.memory), as: .sqlite)
        app.migrations.add(CreateParticipant())
        app.migrations.add(CreateEnrollSession())
        app.migrations.add(CreateTake())
        try await app.autoMigrate()

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("breath-enroll-tests-\(UUID().uuidString)", isDirectory: true)
        app.storageDriver = LocalDiskStorage(root: tempDir)

        app.enrollmentSessions = EnrollmentSessionRegistry()

        app.inviteCode = "letmein"
        app.adminToken = "admin-secret"

        try routes(app)
        return app
    }

    private func shutdown(_ app: Application) async throws {
        try await app.autoRevert()
        try await app.asyncShutdown()
    }

    func testHealthz() async throws {
        let app = try await makeTestApp()
        try await app.test(.GET, "healthz") { res async throws in
            XCTAssertEqual(res.status, .ok)
            XCTAssertEqual(res.body.string, "ok")
        }
        try await shutdown(app)
    }

    func testParticipantRejectsMissingInviteCode() async throws {
        let app = try await makeTestApp()
        let body = ParticipantCreateRequest(
            inviteCode: nil, pseudonym: "diver1", experienceLevel: .intermediate,
            consentVersion: "v1")
        try await app.test(.POST, "api/participants", beforeRequest: { req async throws in
            try req.content.encode(body)
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .unauthorized)
        })
        try await shutdown(app)
    }

    func testParticipantAcceptsValidInviteCode() async throws {
        let app = try await makeTestApp()
        let body = ParticipantCreateRequest(
            inviteCode: "letmein", pseudonym: "diver1", experienceLevel: .intermediate,
            consentVersion: "v1")
        try await app.test(.POST, "api/participants", beforeRequest: { req async throws in
            try req.content.encode(body)
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
            let participant = try res.content.decode(Participant.self)
            XCTAssertEqual(participant.pseudonym, "diver1")
        })
        try await shutdown(app)
    }

    /// Plumbing check for the REST-only lifecycle around the live-capture WebSocket (participant →
    /// session → complete → admin list/export). Capture itself — the WebSocket flow that writes takes
    /// and grades them live — is `EnrollmentSocketHandlerTests`' job; this just proves the surrounding
    /// REST endpoints and the admin export still produce a coherent (if take-less) session.
    func testSessionLifecycleReachesAdminExport() async throws {
        let app = try await makeTestApp()

        var participantID: UUID!
        try await app.test(.POST, "api/participants", beforeRequest: { req async throws in
            try req.content.encode(ParticipantCreateRequest(
                inviteCode: "letmein", pseudonym: nil, experienceLevel: .novice, consentVersion: "v1"))
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
            participantID = try res.content.decode(Participant.self).id
        })

        var sessionID: UUID!
        try await app.test(.POST, "api/sessions", beforeRequest: { req async throws in
            try req.content.encode(SessionCreateRequest(
                participantID: participantID, scriptVersion: "v1", sampleRate: 44_100,
                userAgent: "XCTest", micConstraintsActual: ["echoCancellation": "false"]))
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
            sessionID = try res.content.decode(EnrollSession.self).id
        })

        try await app.test(
            .POST, "api/sessions/\(sessionID!)/complete",
            beforeRequest: { req async throws in
                try req.content.encode(SessionCompleteRequest(status: .completed))
            },
            afterResponse: { res async throws in
                XCTAssertEqual(res.status, .ok)
            })

        try await app.test(.GET, "api/admin/sessions", beforeRequest: { req async throws in
            req.headers.bearerAuthorization = .init(token: "admin-secret")
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok)
            let sessions = try res.content.decode([EnrollSession].self)
            XCTAssertTrue(sessions.contains { $0.id == sessionID })
        })

        try await app.test(
            .GET, "api/admin/sessions/\(sessionID!)/export",
            beforeRequest: { req async throws in
                req.headers.bearerAuthorization = .init(token: "admin-secret")
            },
            afterResponse: { res async throws in
                XCTAssertEqual(res.status, .ok)
                let zipBytes = Data(buffer: res.body)
                XCTAssertGreaterThan(zipBytes.count, 0)
                // A valid ZIP ends with the end-of-central-directory signature.
                let eocdSignature: [UInt8] = [0x50, 0x4b, 0x05, 0x06]
                let tail = zipBytes.suffix(64)
                XCTAssertTrue(
                    tail.starts(with: []) || tail.range(of: Data(eocdSignature)) != nil,
                    "exported archive should contain a ZIP end-of-central-directory record")
            })

        try await shutdown(app)
    }

    func testAdminRoutesRejectWrongToken() async throws {
        let app = try await makeTestApp()
        try await app.test(.GET, "api/admin/sessions", beforeRequest: { req async throws in
            req.headers.bearerAuthorization = .init(token: "wrong-token")
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .unauthorized)
        })
        try await shutdown(app)
    }

    func testSlugValidationRejectsTraversalAndSeparators() {
        XCTAssertTrue(SlugValidation.isSafe("calm_inhale"))
        XCTAssertTrue(SlugValidation.isSafe("frc_exhale-1"))
        XCTAssertFalse(SlugValidation.isSafe(""))
        XCTAssertFalse(SlugValidation.isSafe("../etc/passwd"))
        XCTAssertFalse(SlugValidation.isSafe("a/b"))
        XCTAssertFalse(SlugValidation.isSafe("a\\b"))
        XCTAssertFalse(SlugValidation.isSafe(String(repeating: "a", count: 129)))
    }

    func testConstantTimeCompareMatchesRegularEquality() {
        XCTAssertTrue(ConstantTimeCompare.equals("letmein", "letmein"))
        XCTAssertFalse(ConstantTimeCompare.equals("letmein", "letmeIn"))
        XCTAssertFalse(ConstantTimeCompare.equals("short", "muchlonger"))
        XCTAssertFalse(ConstantTimeCompare.equals("", "a"))
        XCTAssertTrue(ConstantTimeCompare.equals("", ""))
    }
}
