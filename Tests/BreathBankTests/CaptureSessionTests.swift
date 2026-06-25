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
}
