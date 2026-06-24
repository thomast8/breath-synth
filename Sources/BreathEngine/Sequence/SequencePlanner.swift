import Foundation

/// Fits a `BreathPattern` into a requested total by choosing a whole number of cycles.
///
/// Breath durations are always honoured exactly; the *total* flexes to the nearest
/// whole-cycle length. In `.strict` mode a request that doesn't tile evenly fails and
/// proposes the bracketing totals; in `.closest` mode it renders the nearest one.
public enum SequencePlanner {
    /// "Tiles exactly" tolerance, in seconds. Loose enough to absorb human-entered and
    /// floating-point values, tight enough to reject a genuine mismatch (e.g. 3s left over).
    public static let toleranceSec: Double = 0.005

    public static func plan(total: Double, pattern: BreathPattern, mode: FitMode) throws -> SequencePlan {
        try validate(total: total, pattern: pattern)

        let cycle = pattern.cycleSec
        let exact = total / cycle

        // Whole-cycle counts bracketing the request (floor can be 0 when total < one cycle).
        let lowN = max(1, Int(exact.rounded(.down)))
        let highN = max(lowN, Int(exact.rounded(.up)))

        let lower = SequencePlan(pattern: pattern, cycles: lowN, requestedTotalSec: total, tolerance: toleranceSec)
        let upper = SequencePlan(pattern: pattern, cycles: highN, requestedTotalSec: total, tolerance: toleranceSec)

        // Nearest by absolute delta; ties resolve toward the shorter total (fewer cycles).
        let nearest = abs(lower.deltaSec) <= abs(upper.deltaSec) ? lower : upper

        switch mode {
        case .closest:
            return nearest
        case .strict:
            if nearest.isExact { return nearest }
            throw SequencePlanError.doesNotTile(requested: total, lower: lower, upper: upper, nearest: nearest)
        }
    }

    private static func validate(total: Double, pattern: BreathPattern) throws {
        guard total > 0 else {
            throw SequencePlanError.invalidPattern(reason: "total must be greater than 0 (got \(BreathFormat.sec(total))s)")
        }
        guard pattern.cycleSec > 0 else {
            throw SequencePlanError.invalidPattern(reason: "cycle length must be greater than 0")
        }
        guard pattern.holdInSec >= 0, pattern.holdOutSec >= 0 else {
            throw SequencePlanError.invalidPattern(reason: "holds must be 0 or greater")
        }
        let lo = BreathSpec.minDurationSec
        let hi = BreathSpec.maxDurationSec
        // The assembler clamps breath duration to [lo, hi]; a silently-clamped breath
        // would break the tiling math, so reject out-of-range breaths up front.
        for (label, value) in [("inhale", pattern.inhaleSec), ("exhale", pattern.exhaleSec)] {
            guard value >= lo - 1e-9, value <= hi + 1e-9 else {
                throw SequencePlanError.invalidPattern(
                    reason: "\(label) must be between \(BreathFormat.sec(lo))s and \(BreathFormat.sec(hi))s "
                        + "(got \(BreathFormat.sec(value))s)"
                )
            }
        }
    }
}
