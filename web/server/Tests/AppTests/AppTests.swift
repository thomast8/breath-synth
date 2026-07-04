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

        let assetsDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // AppTests
            .deletingLastPathComponent() // Tests
            .appendingPathComponent("Resources/gold-refs", isDirectory: true)
        app.gradingSessions = GradingSessionStore(assetsDir: assetsDir)

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

    /// End-to-end plumbing check: participant → session → room tone → a take upload → verdict →
    /// complete → admin list/export. Not asserting the grader's *specific* accept/reject verdict on
    /// synthetic silence (that decision-level parity is Phase 4's job, against real recordings) —
    /// this proves the pipeline wires together and produces a coherent, exportable session.
    func testFullSessionFlowProducesExportableSession() async throws {
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

        let roomTone = synthesizeWAV(seconds: 2, amplitude: 0.002)
        try await app.test(
            .POST, "api/sessions/\(sessionID!)/room-tone",
            beforeRequest: { req async throws in
                try req.content.encode(RoomToneUploadRequest(sampleRate: 44_100, audio: roomTone))
            },
            afterResponse: { res async throws in
                XCTAssertEqual(res.status, .ok)
            })

        let take = synthesizeWAV(seconds: 8, amplitude: 0.15)
        var verdict: TakeVerdictResponse!
        try await app.test(
            .POST, "api/sessions/\(sessionID!)/takes",
            beforeRequest: { req async throws in
                try req.content.encode(TakeUploadRequest(
                    stepSlug: "calm", laneSlug: "calm_inhale", style: "calm", breathType: "inhale",
                    renderMode: "textured", role: "texture", takeIndex: 1, reference: nil,
                    minSeconds: 4, maxSeconds: 15, sampleRate: 44_100, clientMeta: nil, audio: take))
            },
            afterResponse: { res async throws in
                XCTAssertEqual(res.status, .ok)
                verdict = try res.content.decode(TakeVerdictResponse.self)
            })
        XCTAssertNotNil(verdict)

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

    /// A 2-second, 44.1kHz mono 16-bit PCM WAV of pseudo-random noise at `amplitude` — a stand-in
    /// for real breath audio, just enough to exercise decode → analyze → grade without needing a
    /// bundled fixture recording.
    private func synthesizeWAV(seconds: Double, amplitude: Double) -> Data {
        let sampleRate = 44_100
        let count = Int(seconds * Double(sampleRate))
        var samples = [Int16](repeating: 0, count: count)
        var seed: UInt64 = 12345
        for i in 0..<count {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1
            let unit = Double(seed >> 33) / Double(1 << 31) * 2 - 1
            samples[i] = Int16(max(-1, min(1, unit * amplitude)) * Double(Int16.max))
        }

        var data = Data()
        func appendASCII(_ s: String) { data.append(contentsOf: s.utf8) }
        func appendLE(_ v: UInt32) { var le = v.littleEndian; withUnsafeBytes(of: &le) { data.append(contentsOf: $0) } }
        func appendLE(_ v: UInt16) { var le = v.littleEndian; withUnsafeBytes(of: &le) { data.append(contentsOf: $0) } }
        func appendLE(_ v: Int16) { var le = v.littleEndian; withUnsafeBytes(of: &le) { data.append(contentsOf: $0) } }

        let dataSize = samples.count * 2
        appendASCII("RIFF"); appendLE(UInt32(36 + dataSize)); appendASCII("WAVE")
        appendASCII("fmt "); appendLE(UInt32(16))
        appendLE(UInt16(1)) // PCM
        appendLE(UInt16(1)) // mono
        appendLE(UInt32(sampleRate))
        appendLE(UInt32(sampleRate * 2))
        appendLE(UInt16(2)) // block align
        appendLE(UInt16(16)) // bits per sample
        appendASCII("data"); appendLE(UInt32(dataSize))
        for s in samples { appendLE(s) }
        return data
    }
}
