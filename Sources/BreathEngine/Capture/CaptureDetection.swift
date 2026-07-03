import Foundation

/// Where a captured segment belongs. A `cycle` take yields `.inhale` then `.exhale`; every other
/// detection yields a single `.whole`.
public enum SegmentLabel: String, Sendable, Equatable {
    case whole
    case inhale
    case exhale
}

/// Style-specific spectral-shape acceptance rule for a width-confirmed counted-event candidate (see
/// `CaptureAnalyzer.isCandidateBreathShaped`). Each stored threshold is independently optional; a
/// candidate is accepted when it clears every threshold that's present (`nil` thresholds don't
/// constrain). No single rule works across styles — packing gulps and recovery hooks are spectrally
/// near-opposite (see the `.gulp`/`.hook` doc comments) — so this replaces an earlier flat/bandRatio
/// combined rule that measured no separation between real packing gulps and non-breath contamination.
public struct SpectralGateProfile: Sendable, Equatable {
    public var minCentroidHz: Double?
    public var minBandRatio: Double?
    public var minFlatness: Double?

    public init(minCentroidHz: Double? = nil, minBandRatio: Double? = nil, minFlatness: Double? = nil) {
        self.minCentroidHz = minCentroidHz
        self.minBandRatio = minBandRatio
        self.minFlatness = minFlatness
    }

    public func accepts(flatness: Double, bandRatio: Double, centroidHz: Double) -> Bool {
        if let min = minCentroidHz, centroidHz < min { return false }
        if let min = minBandRatio, bandRatio < min { return false }
        if let min = minFlatness, flatness < min { return false }
        return true
    }

    /// Packing gulps: sharp glottal-closure clicks, broadband with energy skewed above 3 kHz. Measured
    /// (this session, real fixture + gold `packing_1.aifc`/`packing_2.aifc`, two mics): real gulps
    /// 6,370–9,672 Hz centroid; a fixture's suspected keyboard contamination cluster 1,480–3,413 Hz.
    /// 4,500 Hz sits 1,870 Hz below the real minimum, 1,087 Hz above the worst contaminant — closer to
    /// the contaminant side deliberately, since a passed contaminant costs one bounded miscount while a
    /// rejected real gulp violates the zero-true-event-loss gate. bandRatio/flatness are not used here:
    /// bandRatio is physically meaningless as a floor for gulps (real range 0.030–0.163, energy sits
    /// mostly above the 300–3000 Hz breath band), and flatness showed only a razor-thin, unreliable gap.
    public static let gulp = SpectralGateProfile(minCentroidHz: 4500)

    /// Recovery hooks: turbulent airflow genuinely concentrated in the 300–3000 Hz band. Measured (gold
    /// `recovery.aifc`, one clip/user): bandRatio 0.75–0.95. 0.45 sits 0.30 below that observed minimum
    /// (40% relative margin); the packing fixture's contamination cluster (0.03–0.27) is used as a
    /// proxy negative — typing's acoustic signature isn't style-dependent — since no in-style recovery
    /// contamination sample exists yet. Provisional: single-clip, single-user positive evidence only.
    public static let hook = SpectralGateProfile(minBandRatio: 0.45)
}

/// Per-take detection contract for ``CaptureAnalyzer`` / ``BreathRecorder`` — *what* the live capture
/// is listening for and *when* the take ends. Pure data chosen by the app-layer catalog from a step's
/// role; the engine stays a primitive.
///
/// All non-`fixedDuration` cases end a take on **trailing silence** (or the `maxSec` cap) — a take is
/// never hard-cut mid-event (which would truncate a final event's decay tail). Reaching `targetEvents`
/// (where present) shortens the *required* trailing-silence window rather than cutting immediately, so
/// the guarantee holds even once the target is reached. Durations are seconds; the analyzer converts to
/// frames at the capture rate.
public enum CaptureDetection: Sendable, Equatable {
    /// Capture exactly `seconds` from the first sample, with no onset wait. Room tone.
    case fixedDuration(seconds: Double)
    /// Inhale → mid-pause → exhale: split into two labelled segments at the pause, labelled by order.
    /// Calm. The mid-pause (short silence) ends the inhale; trailing silence (long) ends the take.
    case cycle(minPhaseSec: Double, midPauseSec: Double, maxCycleSec: Double, trailingSilenceSec: Double)
    /// One continuous breath/exhale → a single `.whole` segment ending on trailing silence. Onset jumps
    /// straight to capturing, so a natural pre-exhale inhale is captured as part of the same segment —
    /// only correct for a genuine onset-to-silence consumer with no separable lead phase.
    case single(minActiveSec: Double, maxTakeSec: Double, trailingSilenceSec: Double)
    /// Deliberate-pause phase split, keeping only the final phase: reuses `cycle`'s
    /// inhale → mid-pause → exhale state machine internally, but the lead phase's segment is **never
    /// emitted** — only the final phase, as `label: .whole` (so a single-lane consumer's routing is
    /// unaffected). FRC/RV: an inhale inevitably precedes the exhale being captured (you must inhale
    /// before you can let it out or force it out); `single` bakes that inhale into the segment
    /// (`frc_exhale_*` takes ranged 4.56–8.1s against a 3–6s band on the same technique). A brief
    /// deliberate hold before releasing gives the analyzer a real pause to split on, same as `cycle`.
    /// No pause detected by `maxTakeSec` ends the take `.incomplete` — the recorder auto-redoes it, same
    /// as `cycle`'s missing-exhale case.
    /// - `minLeadSec`: minimum lead-phase (inhale) duration before a silence can be treated as the
    ///   mid-pause, not a natural intra-breath dip — small, since the lead phase is discarded regardless.
    /// - `minPhaseSec`: minimum duration of the kept final phase — a structural post-hoc check (see
    ///   `CaptureAnalyzer.TakeIssue`), not enforced inside the state machine itself.
    case finalPhase(minLeadSec: Double, midPauseSec: Double, minPhaseSec: Double, maxTakeSec: Double, trailingSilenceSec: Double)
    /// Well-separated events (cores): count them and flag onsets closer than `minGapSec`
    /// (separation feedback); one `.whole` segment. Packing/recovery separated.
    /// - `eventMinDistSec`: refractory spacing between counted events — the minimum real gap between
    ///   two distinct events of this style, so an event's own attack/decay (or a merged double-sip)
    ///   isn't double-counted.
    /// - `targetEvents`: once reached, the take ends on a much shorter trailing-silence window (still
    ///   silence-gated, never a hard cut) instead of running to the full done-pause or `maxTakeSec`.
    /// - `spectralGate`: reject width-confirmed candidates whose spectral shape doesn't match this
    ///   style's `SpectralGateProfile`; `nil` (the default) means the gate is off — there is no
    ///   style-agnostic default, so callers pick `.gulp`/`.hook`/a custom profile explicitly.
    case cleanEvents(
        minGapSec: Double, maxTakeSec: Double, trailingSilenceSec: Double,
        eventMinDistSec: Double = UnitExtractor.gulpMinDistSec, targetEvents: Int? = nil,
        spectralGate: SpectralGateProfile? = nil
    )
    /// Continuous events at natural cadence (gaps): count + measure inter-onset timing; one `.whole`
    /// segment. Packing/recovery cadence. `eventMinDistSec`/`spectralGate`: see `cleanEvents`.
    case naturalRhythm(
        minActiveSec: Double, maxTakeSec: Double, trailingSilenceSec: Double,
        eventMinDistSec: Double = UnitExtractor.gulpMinDistSec, spectralGate: SpectralGateProfile? = nil
    )
}
