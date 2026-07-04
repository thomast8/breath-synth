import BreathEngine
import Foundation

/// How a step is captured live — maps to a `CaptureDetection` in `EnrollModel`.
enum DetectionKind: Sendable {
    /// Inhale → pause → exhale; two labelled segments. Calm.
    case cycle
    /// One continuous breath/exhale, no separable lead phase.
    case single
    /// Deliberate-pause phase split, keeping only the final phase. FRC/RV: an inhale must precede the
    /// exhale being captured, so a brief hold-then-release gives the analyzer a real pause to split on
    /// (see `CaptureDetection.finalPhase`).
    case finalPhase
    /// Well-separated, counted events (cores). Packing/recovery separated.
    case cleanEvents
    /// Continuous events at natural cadence (gaps). Packing/recovery cadence.
    case naturalRhythm
}

/// Where one captured segment is filed: which `SegmentLabel` routes to which bank. A `cycle` step has
/// two lanes (inhale, exhale); every other step has one (`.whole`). Each lane becomes one
/// `captures.json` step for the bank builder.
struct CaptureLane: Sendable {
    let label: SegmentLabel
    /// Filename base + `captures.json` slug, e.g. "calm_inhale", "packing_separated".
    let slug: String
    let style: String
    let type: BreathType
    /// Builder role: "texture" (grains), "oneShotBody" (frc/rv), "cores" / "gaps" (counted).
    let role: String
    /// Gold grading template for this lane (in the assets dir); may differ from the step's demo.
    let reference: String?
}

/// One step of the guided enrollment: what to perform, how it's detected, and where its segments are
/// filed. Pure data — the app-layer catalog; the engine stays a primitive.
struct EnrollmentStep: Identifiable, Sendable {
    let id = UUID()
    /// UI title, e.g. "Calm breathing".
    let title: String
    /// The instruction shown to the person.
    let prompt: String
    /// Filename in the assets dir played once as a demo before recording; nil if none.
    let demoReference: String?
    /// How many takes to gather. Sized to the grading gates' statistical floor plus one take of
    /// wholesale-loss tolerance — not blanket redundancy: live grading (Phase 4) already auto-redoes
    /// any structurally or signal-defective take at capture time, so the offline build only has
    /// person-dependent advisory gates left to reject wholesale, and only two of those have a hard
    /// floor below which they silently go inert: `Grader.anomalyScore`'s **cross-take** comparison for
    /// `oneShotBody` (frc/rv) needs **≥3 accepted takes** to exist at all, and its **within-take**
    /// comparison for `cleanEvents`' cores (recovery-separated) needs **≥3 cores in one take**, i.e.
    /// `targetEvents: 3`. Don't trim either below that floor without knowing the anomaly gate silently
    /// stops rejecting. Everything else (calm's texture grains, packing's dual-lane cores/gaps, natural
    /// cadence) is graded within a single take or pooled across takes with no such floor, so those steps
    /// only need one take beyond the functional minimum for loss tolerance — see PR #11's fable-planner
    /// take-count calibration for the full per-role evidence.
    let takes: Int
    let renderMode: RenderMode
    let detection: DetectionKind
    /// Per-segment length bounds (seconds) for the builder's length gate; for `cycle` these bound each phase.
    let minSeconds: Double
    let maxSeconds: Double
    /// Expected event count shown as on-screen guidance for `cleanEvents`/`naturalRhythm` (never a hard stop).
    let targetEvents: Int?
    let lanes: [CaptureLane]
}

enum EnrollmentScript {
    /// Uniform capabilities across techniques: calm captures a full inhale→pause→exhale cycle (both
    /// phases from one take); FRC/RV are single terminal exhales; recovery gets separate clean (cores)
    /// and natural-rhythm (gaps) passes (its hook breaths are reliably too close together for one
    /// natural-rhythm take to double as both); packing captures natural rhythm only by default, adding
    /// a separated pass only if that turns out too tight (`packingSeparatedFallback`). References point
    /// at the bundled palette.
    static let steps: [EnrollmentStep] = [
        EnrollmentStep(
            title: "Calm breathing",
            prompt: "Breathe slow and relaxed: a smooth inhale, pause a beat, then a smooth exhale. "
                + "Repeat naturally — each phase about 8–12 s. The app splits inhale from exhale at the pause.",
            // 3: any one take already meets the within-take grain-anomaly floor; the 3rd is one-take
            // wholesale-loss tolerance on top of that (calm is the most-rendered style).
            demoReference: "calm_inhale.aifc", takes: 3, renderMode: .textured, detection: .cycle,
            minSeconds: 4, maxSeconds: 15, targetEvents: nil,
            lanes: [
                CaptureLane(label: .inhale, slug: "calm_inhale", style: "calm", type: .inhale, role: "texture",
                            reference: "calm_inhale.aifc"),
                CaptureLane(label: .exhale, slug: "calm_exhale", style: "calm", type: .exhale, role: "texture",
                            reference: "calm_exhale.aifc"),
            ]
        ),
        EnrollmentStep(
            title: "FRC exhale",
            prompt: "Inhale, hold a beat, then let it fall out passively to a relaxed (FRC) volume — "
                + "don't hold it out longer than feels natural. The pause tells the app where the exhale "
                + "starts — breathe normally between takes.",
            // 4: 3 is the hard floor for `Grader.anomalyScore`'s cross-take oneShot comparison to exist
            // at all; the 4th keeps that gate alive even after a one-take wholesale loss.
            demoReference: "frc_1.aifc", takes: 4, renderMode: .oneShot, detection: .finalPhase,
            // minSeconds was 1.5 (calibrated against the bundled frc_1.aifc reference, itself a
            // different developer's much longer/held release, ~3.4s) — real hardware showed this
            // user's genuine passive FRC release (per this step's own "don't hold it out longer than
            // feels natural" prompt) consistently lands 0.9-1.3s across 5 takes, so 1.5s rejected every
            // real attempt. 0.7 gives comparable margin below the observed low end to RV's calibration
            // (3.0 floor vs. 3.66-4.08 real takes).
            minSeconds: 0.7, maxSeconds: 6, targetEvents: nil,
            lanes: [CaptureLane(label: .whole, slug: "frc_exhale", style: "frc", type: .exhale,
                                role: "oneShotBody", reference: "frc_1.aifc")]
        ),
        EnrollmentStep(
            title: "RV exhale",
            prompt: "Inhale, hold a beat, then force it all the way out to residual volume — as much as "
                + "you can manage, not a specific count. The pause tells the app where the exhale starts "
                + "— recover normally between takes.",
            // 3: exactly the cross-take oneShot anomaly-gate floor (see FRC's note above) — this is
            // the most physically taxing step (repeated forced exhales to RV), so no tolerance take
            // beyond the floor; a wholesale loss degrades variety but never breaks the gate or render.
            demoReference: "rv.aifc", takes: 3, renderMode: .oneShot, detection: .finalPhase,
            minSeconds: 3, maxSeconds: 11, targetEvents: nil,
            lanes: [CaptureLane(label: .whole, slug: "rv_exhale", style: "rv", type: .exhale,
                                role: "oneShotBody", reference: "rv.aifc")]
        ),
        EnrollmentStep(
            title: "Packing",
            prompt: "Pack at your NATURAL rhythm — continuous, real-cadence packing. Whatever lung fill is "
                + "comfortable is fine, it doesn't need to be full. Reset between takes.",
            // 2: one natural take already yields ~10-30 gulps — a deep core pool and a full gap
            // sequence simultaneously (both projections of the same peak pass) — satisfying every gate
            // on its own; the 2nd is one-take wholesale-loss tolerance.
            demoReference: "packing_2.aifc", takes: 2, renderMode: .counted, detection: .naturalRhythm,
            minSeconds: 8, maxSeconds: 25, targetEvents: nil,
            lanes: [
                CaptureLane(label: .whole, slug: "packing_cadence", style: "packing", type: .inhale,
                            role: "gaps", reference: "packing_2.aifc"),
                // Same recordings double as the "cores" role — cores/gaps are two projections of the
                // same peak-detection pass over a take (see EnrollModel.checkPackingCoreIsolation);
                // whether they're actually clean enough is checked after this step, not assumed.
                CaptureLane(label: .whole, slug: "packing_cadence", style: "packing", type: .inhale,
                            role: "cores", reference: "packing_2.aifc"),
            ]
        ),
        EnrollmentStep(
            title: "Recovery — separated",
            prompt: "Recovery hook breaths: each one is a quick inhale then exhale — like calm breathing "
                + "sped way up. Breathe IN, breathe OUT, that's one hook. Do 3 hooks with a clearly "
                + "deliberate pause between each — even if your real post-hold pace has less gap than "
                + "that — so the app gets clean isolated examples. Breathe out between takes.",
            // takes: 2 — a 6-core pool (2 takes x targetEvents 3) already exceeds render needs
            // (3-4 events/render), and a one-take wholesale loss still leaves a working 3-core pool.
            // targetEvents: 3 is a hard floor, not tunable down — it's what `Grader.anomalyScore`'s
            // within-take core comparison needs to exist at all; below 3 the gate silently goes inert.
            demoReference: nil, takes: 2, renderMode: .counted, detection: .cleanEvents,
            minSeconds: 3, maxSeconds: 15, targetEvents: 3,
            lanes: [CaptureLane(label: .whole, slug: "recovery_separated", style: "recovery", type: .inhale,
                                role: "cores", reference: nil)]
        ),
        EnrollmentStep(
            title: "Recovery — natural rhythm",
            prompt: "Now do the same hook breaths, but at whatever pace is actually natural for you post-hold — "
                + "tight back-to-back or more spaced out, whichever you'd really do. This step wants your "
                + "real rhythm, not the deliberate pause from the last step.",
            // 2: one accepted cadence take is the functional floor (graded wholesale per take); the
            // 2nd adds loss tolerance and gap variety. This is the tightest-paced hook breathing —
            // most dizzying step alongside RV — so kept minimal.
            demoReference: nil, takes: 2, renderMode: .counted, detection: .naturalRhythm,
            minSeconds: 3, maxSeconds: 20, targetEvents: nil,
            lanes: [CaptureLane(label: .whole, slug: "recovery_cadence", style: "recovery", type: .inhale,
                                role: "gaps", reference: nil)]
        ),
    ]

    /// Conditional fallback, inserted by `EnrollModel` only if the natural-rhythm "Packing" step's own
    /// gulps turn out too close together for a clean isolated core (see
    /// `EnrollModel.checkPackingCoreIsolation`) — unlike recovery's double-sip hooks, packing's natural
    /// cadence is usually wide enough to double as cores (see PR #11), so this isn't needed by default.
    static let packingSeparatedFallback = EnrollmentStep(
        title: "Packing — separated",
        prompt: "Your natural rhythm was a bit tight for clean isolated samples. Pack 6 deliberate, "
            + "well-SEPARATED gulps this time — a clear gap between each.",
        // takes: 2, targetEvents: 6 — 6 cores/take is comfortably above the within-take anomaly-gate
        // floor (3, see `takes`' doc comment), and a 12-core pool covers packing's high default render
        // counts (10-30 events, cores may repeat — they're near-identical clicks, same as gold assets).
        demoReference: "packing_1.aifc", takes: 2, renderMode: .counted, detection: .cleanEvents,
        minSeconds: 5, maxSeconds: 20, targetEvents: 6,
        lanes: [CaptureLane(label: .whole, slug: "packing_separated", style: "packing", type: .inhale,
                            role: "cores", reference: "packing_1.aifc")]
    )
}
