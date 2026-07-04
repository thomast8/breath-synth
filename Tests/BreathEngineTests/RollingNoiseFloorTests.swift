import XCTest

@testable import BreathEngine

final class RollingNoiseFloorTests: XCTestCase {
    func testNilSeedAdoptsFirstReading() {
        var floor = RollingNoiseFloor()
        XCTAssertNil(floor.value)
        floor.update(with: 0.01)
        XCTAssertEqual(floor.value, 0.01)
    }

    func testEMABlendsTowardReading() {
        var floor = RollingNoiseFloor(value: 0.01)
        floor.update(with: 0.012)  // 1.2x — under the 1.5x upward-step clamp, so this is pure EMA
        // alpha=0.35: 0.01 + (0.012 - 0.01) * 0.35 = 0.0107
        XCTAssertEqual(floor.value ?? 0, 0.0107, accuracy: 0.0001)
    }

    func testUpwardStepClampedBeforeBlending() {
        var floor = RollingNoiseFloor(value: 0.01)
        floor.update(with: 0.1)  // 10x reading
        // Clamped reading = min(0.1, 0.01 * 1.5) = 0.015; blended = 0.01 + (0.015 - 0.01) * 0.35 = 0.01175
        XCTAssertEqual(floor.value ?? 0, 0.01175, accuracy: 0.0001)
    }

    func testDownwardMoveIsUnclamped() {
        var floor = RollingNoiseFloor(value: 0.02)
        floor.update(with: 0.001)  // a big drop
        // No clamp on the way down: 0.02 + (0.001 - 0.02) * 0.35 = 0.02 - 0.00665 = 0.01335
        XCTAssertEqual(floor.value ?? 0, 0.01335, accuracy: 0.0001)
    }

    func testRepeatedHighReadingsConverge() {
        var floor = RollingNoiseFloor(value: 0.01)
        for _ in 0..<20 { floor.update(with: 0.05) }
        XCTAssertEqual(floor.value ?? 0, 0.05, accuracy: 0.002)
    }
}
