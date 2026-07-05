import BreathBank
import BreathEngineCore
import Foundation

/// Per-connection message handling for the live enrollment WebSocket — deliberately independent of
/// Vapor's `WebSocket` type and Fluent, so it's testable by feeding it text/binary frames directly and
/// inspecting what it would have sent, with no real socket or database involved (see
/// `EnrollmentSocketHandlerTests`). The Vapor route wiring (`routes.swift`) supplies `send` (writes to
/// the real socket) and `onSegment`/`onRoomTone` (persist DB rows) as closures.
actor EnrollmentSocketHandler {
    private let sessionID: UUID
    private let outputDir: URL
    private let assetsDir: URL
    private let registry: EnrollmentSessionRegistry?
    private let send: @Sendable (ServerMessage) async -> Void
    /// Fires once per written segment (takeIndex, laneSlug, filename) — the caller resolves the rest
    /// (style/type/role/reference) against its own copy of the step catalog and persists a `Take` row.
    private let onSegment: @Sendable (Int, String, String) async -> Void
    /// Fires once when room tone is written — filename only; the caller resolves/persists the object key.
    private let onRoomTone: @Sendable (String) async -> Void

    /// Not `private` — visible to `@testable import App` so tests can inspect session state directly
    /// (e.g. after a `resume`, that the same take index re-armed) without re-deriving it from sent
    /// messages alone.
    var engine: EnrollmentEngine?
    private var eventTask: Task<Void, Never>?
    private var lastDetectionSendAt = Date.distantPast
    private static let detectionThrottleSec: TimeInterval = 0.1
    /// Overridable only for tests — production always walks the real `EnrollmentScript.steps` catalog.
    private let steps: [EnrollmentStep]

    init(
        sessionID: UUID, outputDir: URL, assetsDir: URL, registry: EnrollmentSessionRegistry? = nil,
        steps: [EnrollmentStep] = EnrollmentScript.steps,
        send: @escaping @Sendable (ServerMessage) async -> Void,
        onSegment: @escaping @Sendable (Int, String, String) async -> Void = { _, _, _ in },
        onRoomTone: @escaping @Sendable (String) async -> Void = { _ in }
    ) {
        self.sessionID = sessionID
        self.outputDir = outputDir
        self.assetsDir = assetsDir
        self.registry = registry
        self.steps = steps
        self.send = send
        self.onSegment = onSegment
        self.onRoomTone = onRoomTone
    }

    // MARK: Inbound

    func handle(text: String) async {
        guard let data = text.data(using: .utf8) else { return }
        let message: ClientMessage
        do {
            message = try JSONDecoder().decode(ClientMessage.self, from: data)
        } catch {
            await send(.error(ErrorMessage(message: "unrecognized message")))
            return
        }
        await handle(message)
    }

    func handle(_ message: ClientMessage) async {
        switch message {
        case let .hello(sampleRate, _):
            await beginOrResumeSession(sampleRate: sampleRate)
        case let .startStep(stepIndex):
            guard let engine else { return }
            if await engine.currentStepIndex != stepIndex {
                await engine.jumpToStep(stepIndex)
            }
            await engine.startStepCapture()
        case .stopTake:
            await engine?.stopCurrentTake()
        case .redoTake, .resume:
            // Reconnect recovery is the same re-arm-and-redo path a manual redo takes — a dropped
            // in-progress take is simply lost and re-listened for at the same take index, exactly
            // BreathRecorder's own semantics (see ClientMessage.resume's doc).
            await engine?.redoCurrentTake()
        case .overrideAmbientGate:
            await engine?.recordAnywayDespiteNoise()
        case .skipStep:
            await engine?.skipCurrentStep()
        }
    }

    /// Raw Int16 LE mono PCM, sent only while a step is armed.
    func handle(binary bytes: [UInt8]) async {
        guard let engine else { return }
        await engine.engine.feed(Self.int16LEToFloat(bytes))
        await maybeSendDetectionState(engine.engine)
    }

    /// Socket dropped — release this handler's event subscription (a resumed session gets a fresh one
    /// via `makeEventStream()`'s "second call replaces the first" contract) without tearing down the
    /// engine itself, which the registry keeps alive for a `resume`.
    func handleDisconnect() async {
        eventTask?.cancel()
        if let registry { await registry.touch(sessionID) }
    }

    // MARK: Session lifecycle

    private func beginOrResumeSession(sampleRate: Double) async {
        let engine: EnrollmentEngine
        let wasExisting: Bool
        if let registry {
            let outputDir = self.outputDir
            let assetsDir = self.assetsDir
            let steps = self.steps
            (engine, wasExisting) = await registry.engine(for: sessionID) {
                EnrollmentEngine(outputDir: outputDir, assetsDir: assetsDir, sampleRate: sampleRate, steps: steps)
            }
        } else {
            engine = EnrollmentEngine(outputDir: outputDir, assetsDir: assetsDir, sampleRate: sampleRate, steps: steps)
            wasExisting = false
        }
        self.engine = engine

        eventTask?.cancel()
        let stream = await engine.makeEventStream()
        eventTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                await self.forward(event)
            }
        }

        if !wasExisting {
            await engine.start()
        }
        await sendSessionState(engine)
    }

    private func sendSessionState(_ engine: EnrollmentEngine) async {
        let steps = await engine.steps
        let stage = await engine.stage
        let currentIndex = await engine.currentStepIndex
        await send(.sessionState(SessionStateMessage(
            steps: steps.map(StepSnapshot.init), currentStepIndex: currentIndex, stage: Self.stageString(stage)
        )))
    }

    private func forward(_ event: EnrollmentEngine.Event) async {
        switch event {
        case let .roomToneReady(filename):
            await send(.roomToneReady(RoomToneReadyMessage()))
            await onRoomTone(filename)
        case let .segmentWritten(takeIndex, laneSlug, filename):
            await onSegment(takeIndex, laneSlug, filename)
        case let .takeVerdict(takeIndex, check):
            await send(.takeVerdict(TakeVerdictMessage(takeIndex: takeIndex, check: check)))
        case let .stepComplete(nextStepIndex, notice):
            await send(.stepComplete(StepCompleteMessage(nextStepIndex: nextStepIndex, insertedFallbackNotice: notice)))
        case .sessionFinished:
            await send(.sessionFinished(SessionFinishedMessage()))
            if let registry { await registry.remove(sessionID) }
        }
    }

    // MARK: Throttled detection polling

    private func maybeSendDetectionState(_ capture: TakeCaptureEngine) async {
        let now = Date()
        guard now.timeIntervalSince(lastDetectionSendAt) >= Self.detectionThrottleSec else { return }
        lastDetectionSendAt = now

        await send(.detectionState(DetectionStateMessage(
            phase: Self.phaseString(await capture.phase), livePhase: Self.livePhaseString(await capture.livePhase),
            blackoutRemaining: await capture.blackoutRemaining, level: await capture.level,
            activityThreshold: await capture.activityThreshold, eventCount: await capture.eventCount,
            takeIndex: await capture.takeIndex, gapTooClose: await capture.gapTooClose
        )))
        await send(.ambientHold(AmbientHoldMessage(active: await capture.ambientHold)))
    }

    // MARK: Wire format

    private static func stageString(_ stage: EnrollmentEngine.Stage) -> String {
        switch stage {
        case .idle: return "idle"
        case .technique: return "technique"
        case .finished: return "finished"
        }
    }

    private static func phaseString(_ phase: TakeCaptureEngine.Phase) -> String {
        switch phase {
        case .idle: return "idle"
        case .waitingForOnset: return "waitingForOnset"
        case .capturing: return "capturing"
        case .reviewing: return "reviewing"
        }
    }

    private static func livePhaseString(_ phase: CaptureAnalyzer.LivePhase) -> String {
        switch phase {
        case .waiting: return "waiting"
        case .capturing: return "capturing"
        case .inhale: return "inhale"
        case .midPause: return "midPause"
        case .exhale: return "exhale"
        }
    }

    private static let int16Scale: Float = 1.0 / 32768.0

    /// Int16 little-endian mono PCM → Float in [-1, 1], the exact normalization every native capture
    /// (and `LiveTakeGrader`'s decode path) assumes — raw PCM, deliberately, so no codec artifact feeds
    /// the calibrated detector.
    static func int16LEToFloat(_ bytes: [UInt8]) -> [Float] {
        let sampleCount = bytes.count / 2
        var out = [Float](repeating: 0, count: sampleCount)
        for i in 0..<sampleCount {
            let lo = UInt16(bytes[2 * i])
            let hi = UInt16(bytes[2 * i + 1])
            let raw = Int16(bitPattern: lo | (hi << 8))
            out[i] = Float(raw) * int16Scale
        }
        return out
    }
}
