import BreathEngineCore
import Foundation
import XCTVapor

@testable import App

/// Tests for the WebSocket transport seam per se — Int16→Float PCM conversion, JSON message framing,
/// the detection-state throttle, and `resume`'s redo semantics. `EnrollmentSocketHandler` wraps a real
/// `EnrollmentEngine`, so capture *policy* (structural redo, force-accept, room-tone pooling, ...) is
/// already covered by `BreathBankTests`' `TakeCaptureEngineTests`/`EnrollmentEngineTests` — these tests
/// exist to prove the transport layer around it, not to re-litigate that policy.
final class EnrollmentSocketHandlerTests: XCTestCase {
    private let sr = 44_100.0

    // MARK: Signal builders (Int16 LE bytes, mirroring BreathBankTests' Float builders)

    private func silenceBytes(_ sec: Double) -> [UInt8] {
        [UInt8](repeating: 0, count: Int(sec * sr) * 2)
    }

    private func toneBytes(_ sec: Double, amp: Float = 0.2) -> [UInt8] {
        let sample = Int16(amp * Float(Int16.max))
        var bytes: [UInt8] = []
        bytes.reserveCapacity(Int(sec * sr) * 2)
        for _ in 0..<Int(sec * sr) {
            bytes.append(UInt8(truncatingIfNeeded: sample))
            bytes.append(UInt8(truncatingIfNeeded: sample >> 8))
        }
        return bytes
    }

    /// A minimal `.single` step: short blackout, no spectral gate, no counted events.
    private func singleStep(slug: String) -> EnrollmentStep {
        EnrollmentStep(
            title: "Test step", prompt: "", demoReference: nil, takes: 1, renderMode: .textured,
            detection: .single, minSeconds: 0.3, maxSeconds: 10, targetEvents: nil,
            lanes: [CaptureLane(label: .whole, slug: slug, style: "calm", type: .inhale, role: "texture", reference: nil)]
        )
    }

    private func makeOutputDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private actor MessageRecorder {
        private(set) var messages: [ServerMessage] = []
        private(set) var segments: [(takeIndex: Int, laneSlug: String, filename: String)] = []
        func record(_ message: ServerMessage) { messages.append(message) }
        func recordSegment(_ takeIndex: Int, _ laneSlug: String, _ filename: String) {
            segments.append((takeIndex, laneSlug, filename))
        }
    }

    // MARK: Int16 <-> Float conversion

    func testInt16ToFloatConversion() {
        // -32768 -> -1.0, 32767 -> just under 1.0, 0 -> 0.0 — the exact normalization LiveTakeGrader's
        // own decode path assumes.
        let bytes: [UInt8] = [
            0x00, 0x80, // -32768 LE
            0xFF, 0x7F, // 32767 LE
            0x00, 0x00, // 0
        ]
        let floats = EnrollmentSocketHandler.int16LEToFloat(bytes)
        XCTAssertEqual(floats.count, 3)
        XCTAssertEqual(floats[0], -1.0, accuracy: 0.0001)
        XCTAssertEqual(floats[1], 32767.0 / 32768.0, accuracy: 0.0001)
        XCTAssertEqual(floats[2], 0.0, accuracy: 0.0001)
    }

    // MARK: hello -> sessionState

    func testHelloSendsSessionStateSnapshot() async throws {
        let dir = try makeOutputDir()
        let recorder = MessageRecorder()
        let steps = [singleStep(slug: "a"), singleStep(slug: "b")]
        let handler = EnrollmentSocketHandler(
            sessionID: UUID(), outputDir: dir, assetsDir: dir, steps: steps,
            send: { message in await recorder.record(message) }
        )

        await handler.handle(.hello(sampleRate: sr, micSettings: nil))

        let messages = await recorder.messages
        guard case let .sessionState(payload)? = messages.first else {
            return XCTFail("expected sessionState as the first message, got \(messages)")
        }
        XCTAssertEqual(payload.steps.count, 2)
        XCTAssertEqual(payload.currentStepIndex, 0)
        XCTAssertEqual(payload.stage, "technique")
    }

    // MARK: Detection-state throttle

    func testDetectionStateThrottledWithinOneWindow() async throws {
        let dir = try makeOutputDir()
        let recorder = MessageRecorder()
        let handler = EnrollmentSocketHandler(
            sessionID: UUID(), outputDir: dir, assetsDir: dir, steps: [singleStep(slug: "a")],
            send: { message in await recorder.record(message) }
        )
        await handler.handle(.hello(sampleRate: sr, micSettings: nil))
        await handler.handle(.startStep(stepIndex: 0))

        // Many small chunks fed back-to-back, entirely in-process — this whole loop runs in well under
        // the 100ms throttle window, so only the very first call (racing against `.distantPast`) should
        // actually produce a `detectionState` send.
        let chunk = silenceBytes(0.01)
        for _ in 0..<50 {
            await handler.handle(binary: [UInt8](chunk))
        }

        let detectionCount = await recorder.messages.filter {
            if case .detectionState = $0 { return true }; return false
        }.count
        // Exactly 1 on a fast, idle machine (only the first call, racing `.distantPast`, should clear
        // the throttle) — but this is a real-wall-clock throttle, so a loaded CI runner could cross the
        // 100ms window once more mid-loop. The bound that actually matters is "far below 50 (unthrottled)".
        XCTAssertLessThanOrEqual(detectionCount, 3, "50 rapid feeds inside ~one throttle window should be heavily throttled")
        XCTAssertGreaterThanOrEqual(detectionCount, 1)
    }

    // MARK: Message choreography: kept-unchecked verdict -> segment -> session finished

    func testSingleTakeProducesKeptUncheckedVerdictThenSegmentThenFinished() async throws {
        let dir = try makeOutputDir()
        let recorder = MessageRecorder()
        let handler = EnrollmentSocketHandler(
            sessionID: UUID(), outputDir: dir, assetsDir: dir, steps: [singleStep(slug: "stepA")],
            send: { message in await recorder.record(message) },
            onSegment: { takeIndex, laneSlug, filename in
                await recorder.recordSegment(takeIndex, laneSlug, filename)
            }
        )
        await handler.handle(.hello(sampleRate: sr, micSettings: nil))
        await handler.handle(.startStep(stepIndex: 0))

        // `.single` carries a hardcoded 1.5s post-arm blackout — the tone must start after it clears.
        for chunk in [silenceBytes(1.7), toneBytes(1.0), silenceBytes(1.0)] {
            await handler.handle(binary: chunk)
        }
        // Room tone never pools this session (one short-armed take), so there's no grader — the take
        // is accepted unchecked, same as the native app before its live grader exists.
        try await waitUntil { await recorder.messages.contains {
            if case .sessionFinished = $0 { return true }; return false
        } }

        let messages = await recorder.messages
        let verdictIndex = messages.firstIndex { if case .takeVerdict = $0 { return true }; return false }
        let finishedIndex = messages.firstIndex { if case .sessionFinished = $0 { return true }; return false }
        guard let verdictIndex, case let .takeVerdict(verdict) = messages[verdictIndex] else {
            return XCTFail("expected a takeVerdict message, got \(messages)")
        }
        XCTAssertEqual(verdict.outcome, "keptUnchecked")
        XCTAssertNotNil(finishedIndex)
        XCTAssertLessThan(verdictIndex, finishedIndex!, "the verdict must be sent before the session finishes")

        let segments = await recorder.segments
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments.first?.laneSlug, "stepA")
    }

    // MARK: resume re-arms the same take index

    func testResumeReArmsSameTakeIndexAfterPartialAudio() async throws {
        let dir = try makeOutputDir()
        let recorder = MessageRecorder()
        let handler = EnrollmentSocketHandler(
            sessionID: UUID(), outputDir: dir, assetsDir: dir, steps: [singleStep(slug: "stepA")],
            send: { message in await recorder.record(message) }
        )
        await handler.handle(.hello(sampleRate: sr, micSettings: nil))
        await handler.handle(.startStep(stepIndex: 0))

        // Feed only the armed silence — no completed take yet — then resume mid-flight.
        await handler.handle(binary: silenceBytes(1.7))
        await handler.handle(.resume(lastAckedTake: 0))
        let stepIndexAfterResume = await handler.engine?.currentStepIndex
        XCTAssertEqual(stepIndexAfterResume, 0, "resume must not advance past the in-flight take")

        // A fresh, complete take fed afterward should still complete normally at the same index.
        for chunk in [silenceBytes(1.7), toneBytes(1.0), silenceBytes(1.0)] {
            await handler.handle(binary: chunk)
        }
        try await waitUntil { await recorder.messages.contains {
            if case .sessionFinished = $0 { return true }; return false
        } }
        let finalStage = await handler.engine?.stage
        XCTAssertEqual(finalStage, .finished)
    }

    private func waitUntil(timeout: TimeInterval = 5.0, _ condition: @escaping () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("condition never became true within \(timeout)s")
    }
}
