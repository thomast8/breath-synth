import XCTest
@testable import BreathEngine

final class SequencePlannerTests: XCTestCase {
    private func pattern(in i: Double, out o: Double, holdIn: Double = 0, holdOut: Double = 0) -> BreathPattern {
        BreathPattern(inhaleSec: i, holdInSec: holdIn, exhaleSec: o, holdOutSec: holdOut)
    }

    // MARK: - Exact fit

    func testExactFitStrict() throws {
        let plan = try SequencePlanner.plan(total: 30, pattern: pattern(in: 5, out: 5), mode: .strict)
        XCTAssertEqual(plan.cycles, 3)
        XCTAssertEqual(plan.actualTotalSec, 30, accuracy: 1e-9)
        XCTAssertEqual(plan.deltaSec, 0, accuracy: 1e-9)
        XCTAssertTrue(plan.isExact)
    }

    func testExactFitClosestMatchesStrict() throws {
        let plan = try SequencePlanner.plan(total: 30, pattern: pattern(in: 5, out: 5), mode: .closest)
        XCTAssertEqual(plan.cycles, 3)
        XCTAssertTrue(plan.isExact)
        XCTAssertEqual(plan.deltaSec, 0, accuracy: 1e-9)
    }

    func testExactFitWithHolds() throws {
        // 4 in + 1 hold + 4 out + 1 hold = 10s cycle → 3 cycles fill 30s exactly.
        let plan = try SequencePlanner.plan(total: 30, pattern: pattern(in: 4, out: 4, holdIn: 1, holdOut: 1), mode: .strict)
        XCTAssertEqual(plan.cycles, 3)
        XCTAssertTrue(plan.isExact)
    }

    // MARK: - Non-tiling: strict fails with a proposal

    func testNonTilingStrictThrowsWithProposal() {
        XCTAssertThrowsError(try SequencePlanner.plan(total: 30, pattern: pattern(in: 3, out: 6), mode: .strict)) { error in
            guard case let .doesNotTile(requested, lower, upper, nearest) = error as? SequencePlanError else {
                return XCTFail("expected doesNotTile, got \(error)")
            }
            XCTAssertEqual(requested, 30, accuracy: 1e-9)
            XCTAssertEqual(lower.cycles, 3)
            XCTAssertEqual(lower.actualTotalSec, 27, accuracy: 1e-9)
            XCTAssertEqual(upper.cycles, 4)
            XCTAssertEqual(upper.actualTotalSec, 36, accuracy: 1e-9)
            // 27 is 3s away, 36 is 6s away → 27 is nearest.
            XCTAssertEqual(nearest.cycles, 3)
            XCTAssertEqual(nearest.actualTotalSec, 27, accuracy: 1e-9)
        }
    }

    // MARK: - Non-tiling: closest renders the nearest

    func testNonTilingClosestRendersNearest() throws {
        let plan = try SequencePlanner.plan(total: 30, pattern: pattern(in: 3, out: 6), mode: .closest)
        XCTAssertEqual(plan.cycles, 3)
        XCTAssertEqual(plan.actualTotalSec, 27, accuracy: 1e-9)
        XCTAssertEqual(plan.deltaSec, -3, accuracy: 1e-9)
        XCTAssertFalse(plan.isExact)
    }

    // MARK: - Total shorter than one cycle

    func testTotalShorterThanOneCycleStrict() {
        XCTAssertThrowsError(try SequencePlanner.plan(total: 5, pattern: pattern(in: 3, out: 6), mode: .strict)) { error in
            guard case let .doesNotTile(_, lower, upper, _) = error as? SequencePlanError else {
                return XCTFail("expected doesNotTile, got \(error)")
            }
            // Only one option: a single 9s cycle.
            XCTAssertEqual(lower.cycles, 1)
            XCTAssertEqual(upper.cycles, 1)
            XCTAssertEqual(lower.actualTotalSec, 9, accuracy: 1e-9)
        }
    }

    func testTotalShorterThanOneCycleClosest() throws {
        let plan = try SequencePlanner.plan(total: 5, pattern: pattern(in: 3, out: 6), mode: .closest)
        XCTAssertEqual(plan.cycles, 1)
        XCTAssertEqual(plan.actualTotalSec, 9, accuracy: 1e-9)
        XCTAssertFalse(plan.isExact)
    }

    // MARK: - Invalid patterns

    func testInhaleBelowMinimumThrowsInvalid() {
        XCTAssertThrowsError(try SequencePlanner.plan(total: 30, pattern: pattern(in: 0.5, out: 6), mode: .closest)) { error in
            guard case .invalidPattern = error as? SequencePlanError else {
                return XCTFail("expected invalidPattern, got \(error)")
            }
        }
    }

    func testExhaleAboveMaximumThrowsInvalid() {
        XCTAssertThrowsError(try SequencePlanner.plan(total: 120, pattern: pattern(in: 4, out: 40), mode: .closest)) { error in
            guard case .invalidPattern = error as? SequencePlanError else {
                return XCTFail("expected invalidPattern, got \(error)")
            }
        }
    }

    func testNonPositiveTotalThrowsInvalid() {
        XCTAssertThrowsError(try SequencePlanner.plan(total: 0, pattern: pattern(in: 4, out: 6), mode: .closest)) { error in
            guard case .invalidPattern = error as? SequencePlanError else {
                return XCTFail("expected invalidPattern, got \(error)")
            }
        }
    }

    func testNegativeHoldThrowsInvalid() {
        let p = BreathPattern(inhaleSec: 4, holdInSec: -1, exhaleSec: 6)
        XCTAssertThrowsError(try SequencePlanner.plan(total: 30, pattern: p, mode: .closest)) { error in
            guard case .invalidPattern = error as? SequencePlanError else {
                return XCTFail("expected invalidPattern, got \(error)")
            }
        }
    }

    // MARK: - Tie-break

    func testTieBreakPrefersFewerCycles() throws {
        // 4s cycle into 10s → exactly 2.5 cycles. 2 cycles (8s) and 3 cycles (12s) are
        // both 2s away; the tie resolves toward fewer cycles (the shorter total).
        let plan = try SequencePlanner.plan(total: 10, pattern: pattern(in: 2, out: 2), mode: .closest)
        XCTAssertEqual(plan.cycles, 2)
        XCTAssertEqual(plan.actualTotalSec, 8, accuracy: 1e-9)
    }
}
