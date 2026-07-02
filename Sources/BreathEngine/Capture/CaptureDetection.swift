import Foundation

/// Where a captured segment belongs. A `cycle` take yields `.inhale` then `.exhale`; every other
/// detection yields a single `.whole`.
public enum SegmentLabel: String, Sendable, Equatable {
    case whole
    case inhale
    case exhale
}

/// Per-take detection contract for ``CaptureAnalyzer`` / ``BreathRecorder`` — *what* the live capture
/// is listening for and *when* the take ends. Pure data chosen by the app-layer catalog from a step's
/// role; the engine stays a primitive.
///
/// All non-`fixedDuration` cases end a take on **trailing silence** (or the `maxSec` cap). Any event
/// count shown in the UI is guidance only — it never hard-cuts a take (which would truncate a final
/// event's decay tail). Durations are seconds; the analyzer converts to frames at the capture rate.
public enum CaptureDetection: Sendable, Equatable {
    /// Capture exactly `seconds` from the first sample, with no onset wait. Room tone.
    case fixedDuration(seconds: Double)
    /// Inhale → mid-pause → exhale: split into two labelled segments at the pause, labelled by order.
    /// Calm. The mid-pause (short silence) ends the inhale; trailing silence (long) ends the take.
    case cycle(minPhaseSec: Double, midPauseSec: Double, maxCycleSec: Double, trailingSilenceSec: Double)
    /// One continuous breath/exhale → a single `.whole` segment ending on trailing silence. FRC/RV.
    case single(minActiveSec: Double, maxTakeSec: Double, trailingSilenceSec: Double)
    /// Well-separated events (cores): count them and flag onsets closer than `minGapSec`
    /// (separation feedback); one `.whole` segment. Packing/recovery separated.
    case cleanEvents(minGapSec: Double, maxTakeSec: Double, trailingSilenceSec: Double)
    /// Continuous events at natural cadence (gaps): count + measure inter-onset timing; one `.whole`
    /// segment. Packing/recovery cadence.
    case naturalRhythm(minActiveSec: Double, maxTakeSec: Double, trailingSilenceSec: Double)
}
