import BreathBank
import BreathEngineCore
import Foundation

/// Messages the browser sends over the live-capture WebSocket. Binary frames (raw Int16 LE mono PCM,
/// sent only while a step is armed) are handled separately — this covers the JSON control channel only.
enum ClientMessage: Decodable {
    case hello(sampleRate: Double, micSettings: [String: String]?)
    case startStep(stepIndex: Int)
    /// Manual escape hatch: finalize the in-progress take now with whatever's been captured so far.
    case stopTake
    /// Manual escape hatch: discard the in-progress take and re-listen for the same take index.
    case redoTake
    /// A genuinely loud room must never trap the session behind the ambient gate.
    case overrideAmbientGate
    /// The participant doesn't know this technique — abandon the current step with zero takes and
    /// advance, recording the step as deliberately skipped rather than failed.
    case skipStep
    /// Reconnecting after a dropped socket. `lastAckedTake` is currently informational only — recovery
    /// is the same re-arm-and-redo path `redoTake` already takes (see the plan's risk notes: a WS drop
    /// mid-take loses that take, and the server re-arms the same take index, exactly the native redo
    /// semantics — no new recovery logic needed).
    case resume(lastAckedTake: Int)

    private enum CodingKeys: String, CodingKey {
        case type, sampleRate, micSettings, stepIndex, lastAckedTake
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "hello":
            self = .hello(
                sampleRate: try container.decode(Double.self, forKey: .sampleRate),
                micSettings: try container.decodeIfPresent([String: String].self, forKey: .micSettings)
            )
        case "startStep":
            self = .startStep(stepIndex: try container.decode(Int.self, forKey: .stepIndex))
        case "stopTake":
            self = .stopTake
        case "redoTake":
            self = .redoTake
        case "overrideAmbientGate":
            self = .overrideAmbientGate
        case "skipStep":
            self = .skipStep
        case "resume":
            self = .resume(lastAckedTake: try container.decode(Int.self, forKey: .lastAckedTake))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container, debugDescription: "Unknown client message type: \(type)")
        }
    }
}

/// Messages the server sends over the live-capture WebSocket, as flat tagged JSON objects
/// (`{"type": "...", ...}`) — each case just delegates encoding to its own payload struct, which
/// carries its own literal `type` field, so there is no separate wrapper/discriminator to keep in sync.
enum ServerMessage: Encodable {
    case sessionState(SessionStateMessage)
    case detectionState(DetectionStateMessage)
    case ambientHold(AmbientHoldMessage)
    case takeRetake(TakeRetakeMessage)
    case takeVerdict(TakeVerdictMessage)
    case stepComplete(StepCompleteMessage)
    case roomToneReady(RoomToneReadyMessage)
    case sessionFinished(SessionFinishedMessage)
    case error(ErrorMessage)

    func encode(to encoder: Encoder) throws {
        switch self {
        case let .sessionState(payload): try payload.encode(to: encoder)
        case let .detectionState(payload): try payload.encode(to: encoder)
        case let .ambientHold(payload): try payload.encode(to: encoder)
        case let .takeRetake(payload): try payload.encode(to: encoder)
        case let .takeVerdict(payload): try payload.encode(to: encoder)
        case let .stepComplete(payload): try payload.encode(to: encoder)
        case let .roomToneReady(payload): try payload.encode(to: encoder)
        case let .sessionFinished(payload): try payload.encode(to: encoder)
        case let .error(payload): try payload.encode(to: encoder)
        }
    }
}

/// Catalog snapshot — doubles as the reconnect/resume payload (the client re-derives its whole step
/// list + current position from this rather than trusting anything it cached from before the drop).
struct SessionStateMessage: Encodable {
    let type = "sessionState"
    let steps: [StepSnapshot]
    let currentStepIndex: Int
    let stage: String
}

struct StepSnapshot: Encodable {
    let title: String
    let prompt: String
    let demoReference: String?
    let takes: Int
    let minSeconds: Double
    let maxSeconds: Double
    let targetEvents: Int?
    /// One of `"cycle"`, `"single"`, `"finalPhase"`, `"cleanEvents"`, `"naturalRhythm"` — the client needs
    /// this (and `isPairedRecovery` below) to reproduce native `BreathEnrollApp`'s per-kind phase-label
    /// wording (e.g. bare "Inhale…" for event-counted kinds vs. "Inhaling… Xs" for `cycle`).
    let detection: String
    /// Recovery's hook-breath lanes render like `cycle`'s "Ready — inhale when you are" even though
    /// their own `detection` kind is `cleanEvents`/`naturalRhythm` — mirrors native `phaseLabel(_:)`'s
    /// `isPairedRecovery` branch.
    let isPairedRecovery: Bool

    init(_ step: EnrollmentStep) {
        title = step.title
        prompt = step.prompt
        demoReference = step.demoReference
        takes = step.takes
        minSeconds = step.minSeconds
        maxSeconds = step.maxSeconds
        targetEvents = step.targetEvents
        switch step.detection {
        case .cycle: detection = "cycle"
        case .single: detection = "single"
        case .finalPhase: detection = "finalPhase"
        case .cleanEvents: detection = "cleanEvents"
        case .naturalRhythm: detection = "naturalRhythm"
        }
        isPairedRecovery = step.lanes.first?.style == "recovery"
    }
}

/// Throttled to ~10Hz by the handler — `TakeCaptureEngine`'s state refreshes on every `feed()` call,
/// far more often than a UI needs to redraw.
struct DetectionStateMessage: Encodable {
    let type = "detectionState"
    let phase: String
    let livePhase: String
    let phaseElapsed: Double
    let blackoutRemaining: Double
    let level: Float
    let activityThreshold: Float
    let eventCount: Int
    let takeIndex: Int
    let gapTooClose: Bool
    /// Mirrors native `EnrollModel.roomTooNoisy` — a non-blocking "this room reads loud" caption,
    /// distinct from `ambientHold` (which actually blocks onset detection until overridden).
    let roomTooNoisy: Bool
}

struct AmbientHoldMessage: Encodable {
    let type = "ambientHold"
    let active: Bool
}

/// A silent structural redo (bad cycle balance, missing pause, too-short phase, etc) — distinct from
/// `TakeVerdictMessage`, which only ever reports the async grader's ruling on a take that got written.
/// Mirrors native `retakeReason(_:)` (`EnrollContentView.swift`), driven by `CaptureAnalyzer.TakeIssue`.
struct TakeRetakeMessage: Encodable {
    let type = "takeRetake"
    let takeIndex: Int
    /// One of `"no_pause"`, `"inhale_too_short"`, `"exhale_too_short"`, `"phases_imbalanced"`,
    /// `"no_segment"`, `"no_pause_before_release"`.
    let issue: String
    /// Only set for `"phases_imbalanced"` — the inhale:exhale duration ratio that tripped the guard.
    let ratio: Double?
    let retries: Int

    init(takeIndex: Int, issue: CaptureAnalyzer.TakeIssue, retries: Int) {
        self.takeIndex = takeIndex
        self.retries = retries
        switch issue {
        case .noPauseDetected:
            self.issue = "no_pause"
            ratio = nil
        case .inhaleTooShort:
            self.issue = "inhale_too_short"
            ratio = nil
        case .exhaleTooShort:
            self.issue = "exhale_too_short"
            ratio = nil
        case let .phasesImbalanced(r):
            self.issue = "phases_imbalanced"
            ratio = r
        case .noSegment:
            self.issue = "no_segment"
            ratio = nil
        case .noPauseBeforeRelease:
            self.issue = "no_pause_before_release"
            ratio = nil
        }
    }
}

struct TakeVerdictMessage: Encodable {
    let type = "takeVerdict"
    /// One of `"accepted"`, `"redo"`, `"keptUnchecked"` — a flattened `EnrollmentEngine.LiveCheck`
    /// (its `.checking`/`.idle` cases never reach the wire; they're not verdicts).
    let outcome: String
    let takeIndex: Int
    let reason: String?

    init(takeIndex: Int, check: EnrollmentEngine.LiveCheck) {
        self.takeIndex = takeIndex
        switch check {
        case .passed:
            outcome = "accepted"
            reason = nil
        case let .redoing(_, why):
            outcome = "redo"
            reason = why
        case .keptUnchecked:
            outcome = "keptUnchecked"
            reason = nil
        case .idle, .checking:
            outcome = "checking"
            reason = nil
        }
    }
}

struct StepCompleteMessage: Encodable {
    let type = "stepComplete"
    let nextStepIndex: Int
    let insertedFallbackNotice: String?
}

struct RoomToneReadyMessage: Encodable {
    let type = "roomToneReady"
}

struct SessionFinishedMessage: Encodable {
    let type = "sessionFinished"
}

struct ErrorMessage: Encodable {
    let type = "error"
    let message: String
}
