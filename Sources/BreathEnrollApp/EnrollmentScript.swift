import BreathEngine
import Foundation

/// How a step is captured live — maps to a `CaptureDetection` in `EnrollModel`.
enum DetectionKind: Sendable {
    /// Inhale → pause → exhale; two labelled segments. Calm.
    case cycle
    /// One continuous breath/exhale. FRC/RV.
    case single
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
    /// How many takes to gather (a deeper pool → better perceptual randomness + failure tolerance).
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
    /// Mandatory session prelude: room tone for this session's SNR baseline (never the bundled one).
    static let roomToneSeconds = 5.0

    /// Uniform capabilities across techniques: calm captures a full inhale→pause→exhale cycle (both
    /// phases from one take); packing and recovery each get clean (cores) and natural-rhythm (gaps)
    /// passes; FRC/RV are single terminal exhales. References point at the bundled palette.
    static let steps: [EnrollmentStep] = [
        EnrollmentStep(
            title: "Calm breathing",
            prompt: "Breathe slow and relaxed: a smooth inhale, pause a beat, then a smooth exhale. "
                + "Repeat naturally — each phase about 8–12 s. The app splits inhale from exhale at the pause.",
            demoReference: "calm_inhale.aifc", takes: 4, renderMode: .textured, detection: .cycle,
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
            prompt: "Passive exhale to a relaxed (FRC) volume — let the air fall out, ~3.5–4.5 s. "
                + "Breathe normally between takes; each exhale is captured on its own.",
            demoReference: "frc_1.aifc", takes: 8, renderMode: .oneShot, detection: .single,
            minSeconds: 3, maxSeconds: 6, targetEvents: nil,
            lanes: [CaptureLane(label: .whole, slug: "frc_exhale", style: "frc", type: .exhale,
                                role: "oneShotBody", reference: "frc_1.aifc")]
        ),
        EnrollmentStep(
            title: "RV exhale",
            prompt: "Full forced exhale all the way to residual volume — push it right out, ~8–9 s. "
                + "Recover normally between takes.",
            demoReference: "rv.aifc", takes: 8, renderMode: .oneShot, detection: .single,
            minSeconds: 6, maxSeconds: 11, targetEvents: nil,
            lanes: [CaptureLane(label: .whole, slug: "rv_exhale", style: "rv", type: .exhale,
                                role: "oneShotBody", reference: "rv.aifc")]
        ),
        EnrollmentStep(
            title: "Packing — separated",
            prompt: "On full lungs, pack 12–15 deliberate, well-SEPARATED gulps — a clear gap between each. "
                + "Exhale and re-inhale to full between takes.",
            demoReference: "packing_1.aifc", takes: 4, renderMode: .counted, detection: .cleanEvents,
            minSeconds: 8, maxSeconds: 25, targetEvents: 13,
            lanes: [CaptureLane(label: .whole, slug: "packing_separated", style: "packing", type: .inhale,
                                role: "cores", reference: "packing_1.aifc")]
        ),
        EnrollmentStep(
            title: "Packing — natural rhythm",
            prompt: "Now pack at your NATURAL rhythm — continuous, real-cadence packing. Reset between takes.",
            demoReference: "packing_2.aifc", takes: 3, renderMode: .counted, detection: .naturalRhythm,
            minSeconds: 8, maxSeconds: 25, targetEvents: nil,
            lanes: [CaptureLane(label: .whole, slug: "packing_cadence", style: "packing", type: .inhale,
                                role: "gaps", reference: "packing_2.aifc")]
        ),
        EnrollmentStep(
            title: "Recovery — separated",
            prompt: "Post-hold recovery hook breaths: sharp, well-SEPARATED double-sips — a clear gap between each. "
                + "Breathe out between takes.",
            demoReference: nil, takes: 4, renderMode: .counted, detection: .cleanEvents,
            minSeconds: 3, maxSeconds: 15, targetEvents: 6,
            lanes: [CaptureLane(label: .whole, slug: "recovery_separated", style: "recovery", type: .inhale,
                                role: "cores", reference: nil)]
        ),
        EnrollmentStep(
            title: "Recovery — natural rhythm",
            prompt: "Now recovery-breathe at your NATURAL post-hold rhythm — continuous hook breaths.",
            demoReference: nil, takes: 3, renderMode: .counted, detection: .naturalRhythm,
            minSeconds: 3, maxSeconds: 20, targetEvents: nil,
            lanes: [CaptureLane(label: .whole, slug: "recovery_cadence", style: "recovery", type: .inhale,
                                role: "gaps", reference: nil)]
        ),
    ]
}
