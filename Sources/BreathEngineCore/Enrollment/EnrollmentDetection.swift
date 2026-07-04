import Foundation

/// Maps `EnrollmentStep`'s catalog intent to the engine's `CaptureDetection` contract — moved out of
/// the native `BreathEnrollApp`'s `EnrollModel` alongside `EnrollmentScript` so the calibrated
/// constants below have exactly one home, shared by the native app and the web enrollment server.
public enum EnrollmentDetection {
    /// Tuning lives here, app-side (the engine stays a primitive with no catalog of its own).
    public static func detection(for step: EnrollmentStep) -> CaptureDetection {
        switch step.detection {
        case .cycle:
            // postArmBlackoutSec: a real between-takes settle pause — calm is gentle, so a short one —
            // that also (Phase 2b) gives the harvest/rolling-floor calibration a guaranteed window;
            // without it a self-paced take could onset almost immediately, leaving nothing to sample.
            return .cycle(minPhaseSec: step.minSeconds, midPauseSec: 0.45,
                          maxCycleSec: step.maxSeconds * 2 + 6, trailingSilenceSec: 1.0,
                          postArmBlackoutSec: 1.5)
        case .single:
            return .single(minActiveSec: max(0.3, step.minSeconds * 0.5),
                           maxTakeSec: step.maxSeconds + 3, trailingSilenceSec: 0.8,
                           postArmBlackoutSec: 1.5)
        case .finalPhase:
            // minLeadSec small — the lead phase (a real inhale before the hold) is discarded regardless
            // of how long it runs; midPauseSec matches calm's deliberate-pause split; maxTakeSec has
            // margin for the lead + pause overhead on top of the final phase's own bound.
            // postArmBlackoutSec: FRC/RV are exertive (RV especially — a forced exhale to residual
            // volume) — a real recovery pause matters on its own, on top of the settle/harvest purpose.
            return .finalPhase(minLeadSec: 0.5, midPauseSec: 0.4,
                               minPhaseSec: step.minSeconds, maxTakeSec: step.maxSeconds + 6,
                               trailingSilenceSec: 0.8, postArmBlackoutSec: 2.0)
        case .cleanEvents:
            // Trailing silence must exceed the deliberate inter-event gap (events are well-separated),
            // so a slow gap doesn't end the take after the first event — only the real done-pause does.
            // postArmBlackoutSec: gives the between-takes exhale/re-inhale (packing/recovery have no
            // discarded-lead-phase structure like cycle/finalPhase) a window to happen without bleeding
            // into the next take as onset noise. pairedEvents: recovery's hook breath is a strict
            // inhale-sip/exhale-sip alternation (see `CaptureDetection.cleanEvents`'s doc); packing's
            // single-click gulp has no such structure.
            return .cleanEvents(minGapSec: 0.35, maxTakeSec: step.maxSeconds + 8, trailingSilenceSec: 3.0,
                                eventMinDistSec: eventMinDistSec(for: step), targetEvents: step.targetEvents,
                                spectralGate: spectralGateProfile(for: step), postArmBlackoutSec: 5.0,
                                pairedEvents: step.lanes.first?.style == "recovery")
        case .naturalRhythm:
            return .naturalRhythm(minActiveSec: 1.0, maxTakeSec: step.maxSeconds + 5, trailingSilenceSec: 1.0,
                                  eventMinDistSec: eventMinDistSec(for: step),
                                  spectralGate: spectralGateProfile(for: step), postArmBlackoutSec: 5.0,
                                  pairedEvents: step.lanes.first?.style == "recovery")
        }
    }

    /// Refractory spacing between counted events, by style: recovery's hook breaths need the wider
    /// offline `hookMinDistSec` floor (matches `UnitExtractor.extract`'s double-sip merge) so an
    /// in/out pair isn't split into two events; every other counted style uses the tighter gulp floor.
    private static func eventMinDistSec(for step: EnrollmentStep) -> Double {
        step.lanes.first?.style == "recovery" ? UnitExtractor.hookMinDistSec : UnitExtractor.gulpMinDistSec
    }

    /// Spectral event-shape profile, by style: packing's sharp glottal gulps and recovery's turbulent
    /// hook breaths are spectrally near-opposite (see `SpectralGateProfile`'s doc comments for the
    /// measured cluster evidence behind `.gulp`/`.hook`), so there is no shared default — every counted
    /// style picks explicitly.
    private static func spectralGateProfile(for step: EnrollmentStep) -> SpectralGateProfile {
        step.lanes.first?.style == "recovery" ? .hook : .gulp
    }

    /// Gulps closer together than this can't isolate cleanly (`UnitExtractor.coreRanges`'s fixed
    /// `[-0.08s, +0.35s]` window around each event bleeds into a neighbor closer than 0.43s); a small
    /// margin above that keeps this a "clearly fine" bar rather than a razor's-edge one.
    public static let packingCoreIsolationSec = 0.45

    /// Once the ambient-harvest pool reaches this much audio, `room_tone` is written once and never
    /// refreshed — a refreshing profile would churn `LiveTakeGrader`'s cached denoise profile for no
    /// measured benefit.
    public static let ambientPoolTargetSec = 4.0

    /// Grading a packing `cores` take costs ~7-11s live (denoise STFT dominates, not fixed overhead —
    /// a short frc/rv `oneShotBody` take grades in ~1.5-3s, measured on real fixtures). 15s clears the
    /// worst observed case with real margin; a timeout still falls back to accept, so a slow grade
    /// never blocks the session, only skips that take's live check.
    public static let liveGradeDeadlineSec = 15.0

    /// Redo policy is app-catalog data, not engine or grader logic: only signal-defect gates trigger an
    /// auto-redo. Person-dependent gates (off_technique/cadence_drift/outlier) are advisory-only —
    /// auto-redoing a person against the bundled gold's spectrum/cadence would recreate the blind
    /// retry loop that motivated this whole feature.
    public static let redoReasons: Set<String> = ["clipped", "length", "dropout", "low_snr", "merged_gulp"]

    /// Consecutive auto-rejected takes (any structurally-invalid cause, or a live-grade `.redo`) after
    /// which the next take is force-accepted, so a user who can't produce a valid take is never
    /// trapped in an infinite redo loop.
    public static let maxTakeRetries = 3
}
