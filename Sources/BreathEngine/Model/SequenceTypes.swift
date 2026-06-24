import Foundation

/// A repeating breath pattern: one inhale → hold → exhale → hold cycle, plus the
/// style to render it with. A *sequence* is a whole number of these cycles laid
/// end to end to fill a requested total duration (see `SequencePlanner`).
public struct BreathPattern: Sendable, Equatable {
    public var inhaleSec: Double
    public var holdInSec: Double
    public var exhaleSec: Double
    public var holdOutSec: Double
    public var style: BreathStyle
    /// Optional base seed for reproducible variation across the whole sequence.
    /// When nil, a stable seed is derived per breath so renders stay reproducible.
    public var seed: UInt64?

    public init(
        inhaleSec: Double,
        holdInSec: Double = 0,
        exhaleSec: Double,
        holdOutSec: Double = 0,
        style: BreathStyle = "calm",
        seed: UInt64? = nil
    ) {
        self.inhaleSec = inhaleSec
        self.holdInSec = holdInSec
        self.exhaleSec = exhaleSec
        self.holdOutSec = holdOutSec
        self.style = style
        self.seed = seed
    }

    /// Duration of one full cycle (inhale + holds + exhale).
    public var cycleSec: Double { inhaleSec + holdInSec + exhaleSec + holdOutSec }

    /// A short human description, e.g. "3s in / 6s out" or "4s in / 2s hold / 4s out".
    public var description: String {
        var parts = ["\(BreathFormat.sec(inhaleSec))s in"]
        if holdInSec > 0 { parts.append("\(BreathFormat.sec(holdInSec))s hold") }
        parts.append("\(BreathFormat.sec(exhaleSec))s out")
        if holdOutSec > 0 { parts.append("\(BreathFormat.sec(holdOutSec))s hold") }
        return parts.joined(separator: " / ")
    }
}

/// How to handle a total that the pattern does not tile evenly.
public enum FitMode: Sendable, Equatable {
    /// Fail unless the pattern tiles the total exactly; propose the nearest totals.
    case strict
    /// Render the nearest whole-cycle total instead of failing.
    case closest
}

/// The result of fitting a `BreathPattern` into a requested total: a whole number
/// of cycles, with the actual length that yields and how far it lands from the request.
public struct SequencePlan: Sendable, Equatable {
    public var pattern: BreathPattern
    public var cycles: Int
    public var requestedTotalSec: Double
    /// Nominal rendered length, `cycles * pattern.cycleSec`. The actual WAV can differ
    /// by a few samples once each segment is rounded to whole frames at render time.
    public var actualTotalSec: Double
    /// `actualTotalSec - requestedTotalSec` (negative = shorter than requested).
    public var deltaSec: Double
    /// Whether `actualTotalSec` matches the request within tolerance.
    public var isExact: Bool

    init(pattern: BreathPattern, cycles: Int, requestedTotalSec: Double, tolerance: Double) {
        let actual = Double(cycles) * pattern.cycleSec
        self.pattern = pattern
        self.cycles = cycles
        self.requestedTotalSec = requestedTotalSec
        self.actualTotalSec = actual
        self.deltaSec = actual - requestedTotalSec
        self.isExact = abs(actual - requestedTotalSec) <= tolerance
    }
}

/// Errors from planning a sequence. `description` is the user-facing message the
/// CLI prints verbatim (it already contains the proposed alternatives).
public enum SequencePlanError: Error, CustomStringConvertible, Equatable {
    /// The pattern itself is unusable (zero-length cycle, breath out of [1, 30]s, etc.).
    case invalidPattern(reason: String)
    /// Strict mode: the pattern does not tile the requested total evenly. Carries the
    /// nearest whole-cycle plans below/above the request and the closer of the two.
    case doesNotTile(requested: Double, lower: SequencePlan, upper: SequencePlan, nearest: SequencePlan)

    public var description: String {
        switch self {
        case let .invalidPattern(reason):
            return "invalid pattern: \(reason)"
        case let .doesNotTile(requested, lower, upper, nearest):
            let cycle = nearest.pattern.cycleSec
            let pat = nearest.pattern.description
            // Total shorter than a single cycle: only one option exists.
            if lower.cycles == upper.cycles {
                return "\(pat) (\(BreathFormat.sec(cycle))s cycle) can't fill "
                    + "\(BreathFormat.sec(requested))s — the minimum is one cycle "
                    + "(\(BreathFormat.sec(lower.actualTotalSec))s). Pass --closest to render it."
            }
            let frac = String(format: "%.2f", requested / cycle)
            return "\(pat) (\(BreathFormat.sec(cycle))s cycle) doesn't tile "
                + "\(BreathFormat.sec(requested))s evenly — that's \(frac) cycles.\n"
                + "  nearest: \(BreathFormat.sec(lower.actualTotalSec))s "
                + "(\(lower.cycles) cycles, \(BreathFormat.signedSec(lower.deltaSec))s) or "
                + "\(BreathFormat.sec(upper.actualTotalSec))s "
                + "(\(upper.cycles) cycles, \(BreathFormat.signedSec(upper.deltaSec))s)\n"
                + "  pass --closest to render the nearest (\(BreathFormat.sec(nearest.actualTotalSec))s)."
        }
    }
}

/// Compact second formatting shared by the planner error text and the CLI summary.
public enum BreathFormat {
    /// Whole numbers without decimals, otherwise up to 2 trimmed decimals. ("27", "27.5", "3.33")
    public static func sec(_ x: Double) -> String {
        let rounded = (x * 100).rounded() / 100
        if abs(rounded - rounded.rounded()) < 1e-9 {
            return String(Int(rounded.rounded()))
        }
        var s = String(format: "%.2f", rounded)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    /// Like `sec`, but always carries an explicit sign. ("+6", "-3")
    public static func signedSec(_ x: Double) -> String {
        (x < 0 ? "-" : "+") + sec(abs(x))
    }
}
