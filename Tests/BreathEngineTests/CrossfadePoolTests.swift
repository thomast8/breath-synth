import XCTest
@testable import BreathEngine

final class CrossfadePoolTests: XCTestCase {
    private func constantGrain(_ value: Float, _ length: Int) -> [Float] {
        [Float](repeating: value, count: length)
    }

    func testExactLengthLongAndShort() {
        let pool = [constantGrain(0.3, 1_000), constantGrain(0.6, 1_000)]
        var rngLong = SeededRNG(seed: 5)
        let long = Crossfade.assembleTexturedFromPool(grains: pool, targetLen: 3_333, grainLen: 1_000, crossfadeLen: 200, rng: &rngLong)
        XCTAssertEqual(long.count, 3_333)
        // targetLen < grainLen still returns exactly targetLen (one random grain, trimmed).
        var rngShort = SeededRNG(seed: 5)
        let short = Crossfade.assembleTexturedFromPool(grains: pool, targetLen: 400, grainLen: 1_000, crossfadeLen: 200, rng: &rngShort)
        XCTAssertEqual(short.count, 400)
    }

    func testSeededReproducibleAndSeedSensitive() {
        let pool = [constantGrain(0.2, 800), constantGrain(0.5, 800), constantGrain(0.8, 800)]
        var a = SeededRNG(seed: 11)
        var b = SeededRNG(seed: 11)
        let r1 = Crossfade.assembleTexturedFromPool(grains: pool, targetLen: 6_000, grainLen: 800, crossfadeLen: 150, rng: &a)
        let r2 = Crossfade.assembleTexturedFromPool(grains: pool, targetLen: 6_000, grainLen: 800, crossfadeLen: 150, rng: &b)
        XCTAssertEqual(r1, r2, "same seed must reproduce the same output")
        // Different seed → a different grain succession. This is the per-cycle independence
        // primitive: re-seeding per cycle yields independent draws, reproducibly.
        var c = SeededRNG(seed: 12)
        let r3 = Crossfade.assembleTexturedFromPool(grains: pool, targetLen: 6_000, grainLen: 800, crossfadeLen: 150, rng: &c)
        XCTAssertNotEqual(r1, r3, "a different seed should draw a different grain sequence")
    }

    func testDrawsFromMultiplePoolGrains() {
        // Distinct constant grains; probing each placed grain's clean (post-crossfade) region
        // reveals which grain filled that slot. A working pool draw must source >1 distinct grain.
        let grain = 1_000, x = 200, stride = 800
        let pool = [constantGrain(0.2, grain), constantGrain(0.5, grain), constantGrain(0.8, grain)]
        var rng = SeededRNG(seed: 3)
        let body = Crossfade.assembleTexturedFromPool(grains: pool, targetLen: 8_000, grainLen: grain, crossfadeLen: x, rng: &rng)
        var seen = Set<Int>()
        for k in 0..<8 {
            let probe = k * stride + x + 50  // inside slot k's pure (non-overlap) region
            if probe < body.count { seen.insert(Int((body[probe] * 10).rounded())) }
        }
        XCTAssertGreaterThan(seen.count, 1, "pool draw should source grains from multiple pool entries")
    }

    func testEqualPowerSeamsNoLoudnessDip() {
        // All-DC-1 grains: every equal-power crossfade of correlated signals must stay ≥ 1, no dip.
        let pool = [constantGrain(1, 1_000), constantGrain(1, 1_000)]
        var rng = SeededRNG(seed: 9)
        let body = Crossfade.assembleTexturedFromPool(grains: pool, targetLen: 8_000, grainLen: 1_000, crossfadeLen: 200, rng: &rng)
        for value in body { XCTAssertGreaterThanOrEqual(value, 1 - 1e-4) }
    }

    func testEmptyPoolReturnsSilence() {
        var rng = SeededRNG(seed: 1)
        let body = Crossfade.assembleTexturedFromPool(grains: [], targetLen: 500, grainLen: 1_000, crossfadeLen: 200, rng: &rng)
        XCTAssertEqual(body.count, 500)
        XCTAssertTrue(body.allSatisfy { $0 == 0 })
    }
}
