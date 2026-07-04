import Testing
@testable import BreathEngine

struct SequencePlannerTests {
    private func pattern(in i: Double, out o: Double, holdIn: Double = 0, holdOut: Double = 0) -> BreathPattern {
        BreathPattern(inhaleSec: i, holdInSec: holdIn, exhaleSec: o, holdOutSec: holdOut)
    }

    // MARK: - Exact fit

    @Test func exactFitStrict() throws {
        let plan = try SequencePlanner.plan(total: 30, pattern: pattern(in: 5, out: 5), mode: .strict)
        #expect(plan.cycles == 3)
        #expect(abs(plan.actualTotalSec - 30) <= 1e-9)
        #expect(abs(plan.deltaSec - 0) <= 1e-9)
        #expect(plan.isExact)
    }

    @Test func exactFitClosestMatchesStrict() throws {
        let plan = try SequencePlanner.plan(total: 30, pattern: pattern(in: 5, out: 5), mode: .closest)
        #expect(plan.cycles == 3)
        #expect(plan.isExact)
        #expect(abs(plan.deltaSec - 0) <= 1e-9)
    }

    @Test func exactFitWithHolds() throws {
        // 4 in + 1 hold + 4 out + 1 hold = 10s cycle → 3 cycles fill 30s exactly.
        let plan = try SequencePlanner.plan(total: 30, pattern: pattern(in: 4, out: 4, holdIn: 1, holdOut: 1), mode: .strict)
        #expect(plan.cycles == 3)
        #expect(plan.isExact)
    }

    // MARK: - Non-tiling: strict fails with a proposal

    @Test func nonTilingStrictThrowsWithProposal() throws {
        let error = try #require(throws: SequencePlanError.self) {
            try SequencePlanner.plan(total: 30, pattern: pattern(in: 3, out: 6), mode: .strict)
        }
        guard case let .doesNotTile(requested, lower, upper, nearest) = error else {
            Issue.record("expected doesNotTile, got \(error)")
            return
        }
        #expect(abs(requested - 30) <= 1e-9)
        #expect(lower.cycles == 3)
        #expect(abs(lower.actualTotalSec - 27) <= 1e-9)
        #expect(upper.cycles == 4)
        #expect(abs(upper.actualTotalSec - 36) <= 1e-9)
        // 27 is 3s away, 36 is 6s away → 27 is nearest.
        #expect(nearest.cycles == 3)
        #expect(abs(nearest.actualTotalSec - 27) <= 1e-9)
    }

    // MARK: - Non-tiling: closest renders the nearest

    @Test func nonTilingClosestRendersNearest() throws {
        let plan = try SequencePlanner.plan(total: 30, pattern: pattern(in: 3, out: 6), mode: .closest)
        #expect(plan.cycles == 3)
        #expect(abs(plan.actualTotalSec - 27) <= 1e-9)
        #expect(abs(plan.deltaSec - (-3)) <= 1e-9)
        #expect(!(plan.isExact))
    }

    // MARK: - Total shorter than one cycle

    @Test func totalShorterThanOneCycleStrict() throws {
        let error = try #require(throws: SequencePlanError.self) {
            try SequencePlanner.plan(total: 5, pattern: pattern(in: 3, out: 6), mode: .strict)
        }
        guard case let .doesNotTile(_, lower, upper, _) = error else {
            Issue.record("expected doesNotTile, got \(error)")
            return
        }
        // Only one option: a single 9s cycle.
        #expect(lower.cycles == 1)
        #expect(upper.cycles == 1)
        #expect(abs(lower.actualTotalSec - 9) <= 1e-9)
    }

    @Test func totalShorterThanOneCycleClosest() throws {
        let plan = try SequencePlanner.plan(total: 5, pattern: pattern(in: 3, out: 6), mode: .closest)
        #expect(plan.cycles == 1)
        #expect(abs(plan.actualTotalSec - 9) <= 1e-9)
        #expect(!(plan.isExact))
    }

    // MARK: - Invalid patterns

    @Test func inhaleBelowMinimumThrowsInvalid() throws {
        let error = try #require(throws: SequencePlanError.self) {
            try SequencePlanner.plan(total: 30, pattern: pattern(in: 0.5, out: 6), mode: .closest)
        }
        guard case .invalidPattern = error else {
            Issue.record("expected invalidPattern, got \(error)")
            return
        }
    }

    @Test func exhaleAboveMaximumThrowsInvalid() throws {
        let error = try #require(throws: SequencePlanError.self) {
            try SequencePlanner.plan(total: 120, pattern: pattern(in: 4, out: 40), mode: .closest)
        }
        guard case .invalidPattern = error else {
            Issue.record("expected invalidPattern, got \(error)")
            return
        }
    }

    @Test func nonPositiveTotalThrowsInvalid() throws {
        let error = try #require(throws: SequencePlanError.self) {
            try SequencePlanner.plan(total: 0, pattern: pattern(in: 4, out: 6), mode: .closest)
        }
        guard case .invalidPattern = error else {
            Issue.record("expected invalidPattern, got \(error)")
            return
        }
    }

    @Test func negativeHoldThrowsInvalid() throws {
        let p = BreathPattern(inhaleSec: 4, holdInSec: -1, exhaleSec: 6)
        let error = try #require(throws: SequencePlanError.self) {
            try SequencePlanner.plan(total: 30, pattern: p, mode: .closest)
        }
        guard case .invalidPattern = error else {
            Issue.record("expected invalidPattern, got \(error)")
            return
        }
    }

    // MARK: - Tie-break

    @Test func tieBreakPrefersFewerCycles() throws {
        // 4s cycle into 10s → exactly 2.5 cycles. 2 cycles (8s) and 3 cycles (12s) are
        // both 2s away; the tie resolves toward fewer cycles (the shorter total).
        let plan = try SequencePlanner.plan(total: 10, pattern: pattern(in: 2, out: 2), mode: .closest)
        #expect(plan.cycles == 2)
        #expect(abs(plan.actualTotalSec - 8) <= 1e-9)
    }
}
