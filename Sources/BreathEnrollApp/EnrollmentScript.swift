import BreathEngine
import Foundation

/// One step of the guided enrollment: what to record, how the reference guides it, and how many
/// takes to gather. Pure data — the app-layer enrollment catalog (the engine stays a primitive).
struct EnrollmentStep: Identifiable, Sendable {
    let id = UUID()
    /// Filename base for this step's takes, e.g. "calm_inhale", "packing_separated".
    let slug: String
    let style: String
    let type: BreathType
    let renderMode: RenderMode
    /// Builder role for the takes: "texture" (grains), "oneShotBody" (frc/rv), "cores" / "gaps" (packing).
    let role: String
    /// The instruction shown to the person.
    let prompt: String
    /// How many takes to gather (a deeper pool → better perceptual randomness + failure tolerance).
    let takes: Int
    /// Gold reference take filename, played first to guide imitation; nil if none recorded yet.
    let reference: String?
    let minSeconds: Double
    let maxSeconds: Double
}

enum EnrollmentScript {
    /// Mandatory session prelude: room tone for this session's SNR baseline (never the bundled one).
    static let roomToneSeconds = 5.0

    /// High-value, sonically-distinct techniques (calm, FRC, RV, packing). Hyperventilation == fast
    /// calm; full-lung dropped. Reference filenames point at the bundled palette for guidance.
    static let steps: [EnrollmentStep] = [
        EnrollmentStep(
            slug: "calm_inhale", style: "calm", type: .inhale, renderMode: .textured, role: "texture",
            prompt: "Slow, relaxed inhale — smooth and steady airflow, about 8–12 seconds.",
            takes: 4, reference: "calm_inhale.aifc", minSeconds: 8, maxSeconds: 12
        ),
        EnrollmentStep(
            slug: "calm_exhale", style: "calm", type: .exhale, renderMode: .textured, role: "texture",
            prompt: "Slow, relaxed exhale — smooth and steady, about 8–12 seconds.",
            takes: 4, reference: "calm_exhale.aifc", minSeconds: 8, maxSeconds: 12
        ),
        EnrollmentStep(
            slug: "frc_exhale", style: "frc", type: .exhale, renderMode: .oneShot, role: "oneShotBody",
            prompt: "Passive exhale to a relaxed (FRC) volume — let the air fall out, ~3.5–4.5 s. Hold mic gain steady.",
            takes: 8, reference: "frc_1.aifc", minSeconds: 3.5, maxSeconds: 4.5
        ),
        EnrollmentStep(
            slug: "rv_exhale", style: "rv", type: .exhale, renderMode: .oneShot, role: "oneShotBody",
            prompt: "Full forced exhale all the way to residual volume — push it right out, ~8–9 s.",
            takes: 8, reference: "rv.aifc", minSeconds: 8, maxSeconds: 9
        ),
        EnrollmentStep(
            slug: "packing_separated", style: "packing", type: .inhale, renderMode: .counted, role: "cores",
            prompt: "On full lungs, pack 12–15 deliberate, well-SEPARATED gulps — clear gaps between each.",
            takes: 4, reference: "packing_1.aifc", minSeconds: 15, maxSeconds: 20
        ),
        EnrollmentStep(
            slug: "packing_cadence", style: "packing", type: .inhale, renderMode: .counted, role: "gaps",
            prompt: "Now pack at your NATURAL rhythm — continuous, real-cadence packing.",
            takes: 3, reference: "packing_2.aifc", minSeconds: 15, maxSeconds: 20
        ),
    ]
}

/// What an enrollment session captured, written as `captures.json` in the output folder for the
/// `breath-bank` builder to consume. (Re-homed into the builder library in PR4.)
struct CaptureSession: Codable, Sendable {
    struct Step: Codable, Sendable {
        var slug: String
        var style: String
        var type: BreathType
        var renderMode: RenderMode
        var role: String
        var reference: String?
        var files: [String]
    }

    var roomTone: String?
    var steps: [Step]

    func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
