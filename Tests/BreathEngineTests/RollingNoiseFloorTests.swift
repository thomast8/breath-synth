import Testing

@testable import BreathEngine

struct RollingNoiseFloorTests {
    @Test func nilSeedAdoptsFirstReading() {
        var floor = RollingNoiseFloor()
        #expect(floor.value == nil)
        floor.update(with: 0.01)
        #expect(floor.value == 0.01)
    }

    @Test func emaBlendsTowardReading() {
        var floor = RollingNoiseFloor(value: 0.01)
        floor.update(with: 0.012)  // 1.2x — under the 1.5x upward-step clamp, so this is pure EMA
        // alpha=0.35: 0.01 + (0.012 - 0.01) * 0.35 = 0.0107
        #expect(abs((floor.value ?? 0) - 0.0107) <= 0.0001)
    }

    @Test func upwardStepClampedBeforeBlending() {
        var floor = RollingNoiseFloor(value: 0.01)
        floor.update(with: 0.1)  // 10x reading
        // Clamped reading = min(0.1, 0.01 * 1.5) = 0.015; blended = 0.01 + (0.015 - 0.01) * 0.35 = 0.01175
        #expect(abs((floor.value ?? 0) - 0.01175) <= 0.0001)
    }

    @Test func downwardMoveIsUnclamped() {
        var floor = RollingNoiseFloor(value: 0.02)
        floor.update(with: 0.001)  // a big drop
        // No clamp on the way down: 0.02 + (0.001 - 0.02) * 0.35 = 0.02 - 0.00665 = 0.01335
        #expect(abs((floor.value ?? 0) - 0.01335) <= 0.0001)
    }

    @Test func repeatedHighReadingsConverge() {
        var floor = RollingNoiseFloor(value: 0.01)
        for _ in 0..<20 { floor.update(with: 0.05) }
        #expect(abs((floor.value ?? 0) - 0.05) <= 0.002)
    }
}
