import XCTest
@testable import BreathBank
import BreathEngine

final class CaptureSessionTests: XCTestCase {
    func testRoundTrip() throws {
        let session = CaptureSession(roomTone: "room_tone.caf", steps: [
            .init(slug: "calm_inhale", style: "calm", type: .inhale, renderMode: .textured,
                  role: "texture", reference: "calm_inhale.aifc",
                  files: ["calm_inhale_1.caf", "calm_inhale_2.caf"]),
            .init(slug: "packing_separated", style: "packing", type: .inhale, renderMode: .counted,
                  role: "cores", reference: nil, files: []),
        ])

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("captures.json")

        try session.write(to: url)
        let loaded = try CaptureSession.load(from: url)
        XCTAssertEqual(loaded.roomTone, "room_tone.caf")
        XCTAssertEqual(loaded.steps.count, 2)
        XCTAssertEqual(loaded.steps.first?.files, ["calm_inhale_1.caf", "calm_inhale_2.caf"])
        XCTAssertEqual(loaded.steps.first?.type, .inhale)
        XCTAssertEqual(loaded.steps.last?.renderMode, .counted)
        XCTAssertNil(loaded.steps.last?.reference)
    }

    /// Incremental save writes captures.json mid-session, so a partial run (fewer takes than planned,
    /// later steps not reached) must round-trip cleanly — the builder simply grades what's there.
    func testPartialSessionRoundTrips() throws {
        let session = CaptureSession(roomTone: "room_tone.caf", steps: [
            // 2 of a planned 4 takes captured before the user hit "Finish & save now".
            .init(slug: "calm_inhale", style: "calm", type: .inhale, renderMode: .textured,
                  role: "texture", reference: "calm_inhale.aifc",
                  files: ["calm_inhale_1.caf", "calm_inhale_2.caf"], minSeconds: 8, maxSeconds: 12),
            // A later step never reached → no files.
            .init(slug: "frc_exhale", style: "frc", type: .exhale, renderMode: .oneShot,
                  role: "oneShotBody", reference: "frc_1.aifc", files: [], minSeconds: 3.5, maxSeconds: 4.5),
        ])

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("captures.json")

        try session.write(to: url)
        let loaded = try CaptureSession.load(from: url)
        XCTAssertEqual(loaded.steps.first?.files.count, 2, "partial take count preserved")
        XCTAssertEqual(loaded.steps.last?.files, [], "unreached step has no takes")
        XCTAssertEqual(loaded.steps.first?.minSeconds, 8)
    }
}
