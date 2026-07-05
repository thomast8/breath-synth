import Testing
import Foundation
@testable import BreathBank
import BreathEngineCore

/// Orchestration tests for `EnrollmentEngine`, written from `EnrollModel`'s native semantics: room-tone
/// pooling writes once and creates the live grader once, a take is `.keptUnchecked` before that grader
/// exists, and step advancement/packing-fallback insertion match the native session flow. Full grading
/// verdict fidelity (the hard/advisory `redoReasons` split) needs a real gold-reference-driven grade —
/// that's genuinely integration-level and is covered by Phase 6's native-vs-web side-by-side session,
/// not here.
struct EnrollmentEngineTests {
    private let sr = 44_100.0

    private func silence(_ sec: Double) -> [Float] { [Float](repeating: 0, count: Int(sec * sr)) }
    private func tone(_ sec: Double, _ amp: Float = 0.2) -> [Float] { [Float](repeating: amp, count: Int(sec * sr)) }
    private func sineBurst(_ sec: Double, freqHz: Double = 6000, amp: Float = 0.3) -> [Float] {
        let n = Int(sec * sr)
        return (0..<n).map { i in Float(Double(amp) * sin(2 * Double.pi * freqHz * Double(i) / sr)) }
    }

    /// A minimal `.single` step (short blackout, no spectral gate, no counted events) — the simplest
    /// detection kind, used wherever a test just needs *a* take to complete without exercising counted-
    /// event or cycle-split machinery.
    private func singleStep(title: String, slug: String, takes: Int = 1) -> EnrollmentStep {
        EnrollmentStep(
            title: title, prompt: "", demoReference: nil, takes: takes, renderMode: .textured, detection: .single,
            minSeconds: 0.3, maxSeconds: 10, targetEvents: nil,
            lanes: [CaptureLane(label: .whole, slug: slug, style: "calm", type: .inhale, role: "texture", reference: nil)]
        )
    }

    private func makeDirs() throws -> (output: URL, assets: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let output = root.appendingPathComponent("output")
        let assets = root.appendingPathComponent("assets")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        return (output, assets)
    }

    private func feed(_ enrollment: EnrollmentEngine, _ signal: [Float]) async {
        var i = 0
        while i < signal.count {
            let end = min(signal.count, i + 4_096)
            await enrollment.engine.feed(Array(signal[i..<end]))
            i = end
        }
    }

    private func waitUntil(timeout: TimeInterval = 8.0, _ condition: @escaping () async -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    // MARK: Pre-grader takes are kept unchecked

    @Test func takeBeforeRoomToneFillsIsKeptUnchecked() async throws {
        let dirs = try makeDirs()
        let step = singleStep(title: "Step A", slug: "stepA")
        let enrollment = EnrollmentEngine(outputDir: dirs.output, assetsDir: dirs.assets, sampleRate: sr, steps: [step])
        await enrollment.start()
        await enrollment.startStepCapture()

        // `.single` carries a hardcoded 1.5s post-arm onset blackout, so the pre-onset window must clear
        // that before the tone can even register as onset. 1.7s does — and its harvested ambient (~1.7s)
        // stays well under the 4.0s pool target on its own, so `roomToneFile` stays nil and the grader
        // never gets created for this one-take step.
        let signal = silence(1.7) + tone(1.0) + silence(1.0)
        await feed(enrollment, signal)
        await waitUntil { await enrollment.stage == .finished }

        #expect(await enrollment.roomToneFile == nil)
        #expect(await enrollment.liveCheck == .keptUnchecked(take: 0))
        #expect(await enrollment.stage == .finished)
        #expect(await enrollment.totalFilesCaptured == 1)
    }

    // MARK: Room tone pools once, grader created once

    @Test func roomTonePoolsToTargetThenWritesOnceAndNeverAgain() async throws {
        let dirs = try makeDirs()
        let step = singleStep(title: "Step A", slug: "stepA", takes: 2)
        // Take 1 crosses the pool target, so its own finalize creates the live grader before the review
        // decision runs (see below) — both takes then route through real grading. The outcome doesn't
        // matter to this test, so a short injected deadline keeps them resolving quickly instead of
        // racing the real 15s `liveGradeDeadlineSec`.
        let enrollment = EnrollmentEngine(
            outputDir: dirs.output, assetsDir: dirs.assets, sampleRate: sr, steps: [step], gradeDeadlineSec: 1.0)
        await enrollment.start()
        await enrollment.startStepCapture()

        // Take 1: a long (4.5s) pure-silence armed window — comfortably past `ambientPoolTargetSec`
        // (4.0s) on its own, so `room_tone.wav` gets written and the live grader created during *this*
        // take's own finalize (ambient pooling runs before the review decision — see `TakeCaptureEngine
        // .finalize`'s ordering).
        await feed(enrollment, silence(4.5) + tone(1.0) + silence(1.0))
        await waitUntil { await enrollment.roomToneFile != nil }
        // `roomToneFile` is set mid-review (pooling settles before the review decision), so waiting on
        // it alone races take 1's still-in-flight async grade — take 2's signal, sent too early, would
        // land while `armed == false` and be silently dropped. Wait for take 1 to fully resolve (take
        // index advances to 1) before feeding take 2.
        await waitUntil { await enrollment.engine.takeIndex == 1 }

        let roomToneURL = dirs.output.appendingPathComponent("room_tone.wav")
        let sizeAfterTake1 = try FileManager.default.attributesOfItem(atPath: roomToneURL.path)[.size] as? Int

        // Take 2: another long silent window that *would* cross the pool target again if pooling were
        // still active — it must not be, so the file must be byte-identical afterward.
        await feed(enrollment, silence(4.5) + tone(1.0) + silence(1.0))
        await waitUntil { await enrollment.stage == .finished }

        let sizeAfterTake2 = try FileManager.default.attributesOfItem(atPath: roomToneURL.path)[.size] as? Int
        #expect(await enrollment.stage == .finished, "the session must actually complete, not just time out waiting")
        #expect(sizeAfterTake1 != nil && sizeAfterTake1! > 0)
        #expect(sizeAfterTake2 == sizeAfterTake1, "a second take's ambient must not append to or rewrite room_tone.wav")
        #expect(await enrollment.roomToneFile == "room_tone.wav")
    }

    // MARK: Step advancement

    @Test func sessionAdvancesThroughStepsThenFinishes() async throws {
        let dirs = try makeDirs()
        let steps = [singleStep(title: "Step A", slug: "stepA"), singleStep(title: "Step B", slug: "stepB")]
        let enrollment = EnrollmentEngine(outputDir: dirs.output, assetsDir: dirs.assets, sampleRate: sr, steps: steps)
        await enrollment.start()

        #expect(await enrollment.currentStepIndex == 0)
        await enrollment.startStepCapture()
        await feed(enrollment, silence(1.7) + tone(1.0) + silence(1.0))
        await waitUntil {
            let index = await enrollment.currentStepIndex
            let stage = await enrollment.stage
            return index == 1 || stage == .finished
        }

        #expect(await enrollment.stage == .technique(step: 1))
        await enrollment.startStepCapture()
        await feed(enrollment, silence(1.7) + tone(1.0) + silence(1.0))
        await waitUntil { await enrollment.stage == .finished }

        #expect(await enrollment.stage == .finished)
        #expect(await enrollment.totalFilesCaptured == 2)
        #expect(await enrollment.captured["stepA"]?.count == 1)
        #expect(await enrollment.captured["stepB"]?.count == 1)

        let manifestURL = dirs.output.appendingPathComponent("captures.json")
        #expect(FileManager.default.fileExists(atPath: manifestURL.path))
    }

    // MARK: Event stream

    private actor EventCollector {
        private(set) var events: [EnrollmentEngine.Event] = []
        func record(_ event: EnrollmentEngine.Event) { events.append(event) }
    }

    /// `takeVerdict`/`stepComplete`/`sessionFinished` all originate from the detached post-review
    /// continuation, outside any `feed()` call — a WebSocket handler can't reconstruct them by polling
    /// state the way it can `detectionState`/`ambientHold`, hence this dedicated event-stream contract.
    @Test func eventStreamEmitsVerdictsStepCompleteAndFinished() async throws {
        let dirs = try makeDirs()
        let steps = [singleStep(title: "Step A", slug: "stepA"), singleStep(title: "Step B", slug: "stepB")]
        let enrollment = EnrollmentEngine(outputDir: dirs.output, assetsDir: dirs.assets, sampleRate: sr, steps: steps)
        let collector = EventCollector()
        let stream = await enrollment.makeEventStream()
        let consumer = Task {
            for await event in stream { await collector.record(event) }
        }

        await enrollment.start()
        await enrollment.startStepCapture()
        await feed(enrollment, silence(1.7) + tone(1.0) + silence(1.0))
        await waitUntil { await enrollment.stage == .technique(step: 1) }
        await enrollment.startStepCapture()
        await feed(enrollment, silence(1.7) + tone(1.0) + silence(1.0))
        await waitUntil { await enrollment.stage == .finished }
        await consumer.value  // the stream's `finish()` (on session completion) ends the for-await loop

        let events = await collector.events
        #expect(events.count == 6, "\(events)")
        guard events.count == 6 else { return }
        #expect(events[0] == .takeVerdict(takeIndex: 0, check: .keptUnchecked(take: 0)))
        #expect(events[1] == .segmentWritten(takeIndex: 0, laneSlug: "stepA", filename: "stepA_1.wav"))
        #expect(events[2] == .stepComplete(nextStepIndex: 1, insertedFallbackNotice: nil))
        #expect(events[3] == .takeVerdict(takeIndex: 0, check: .keptUnchecked(take: 0)))
        #expect(events[4] == .segmentWritten(takeIndex: 0, laneSlug: "stepB", filename: "stepB_1.wav"))
        #expect(events[5] == .sessionFinished)
    }

    // MARK: Skipping a step

    @Test func skippingAStepRecordsItAndAdvancesWithoutCapturingATake() async throws {
        let dirs = try makeDirs()
        let steps = [singleStep(title: "Packing", slug: "packing_cadence"), singleStep(title: "Step B", slug: "stepB")]
        let enrollment = EnrollmentEngine(outputDir: dirs.output, assetsDir: dirs.assets, sampleRate: sr, steps: steps)
        await enrollment.start()
        await enrollment.startStepCapture()

        // Skip before ever feeding any audio — the common case (declined before attempting).
        await enrollment.skipCurrentStep()

        #expect(await enrollment.stage == .technique(step: 1))
        #expect(await enrollment.skippedSteps == ["Packing"])
        #expect(await enrollment.captured["packing_cadence"] == nil)
        #expect(await enrollment.totalFilesCaptured == 0)

        await enrollment.startStepCapture()
        await feed(enrollment, silence(1.7) + tone(1.0) + silence(1.0))
        await waitUntil { await enrollment.stage == .finished }

        #expect(await enrollment.stage == .finished)
        #expect(await enrollment.captured["stepB"]?.count == 1)

        let manifest = try CaptureSession.load(from: dirs.output.appendingPathComponent("captures.json"))
        #expect(manifest.skippedSteps == ["Packing"])
    }

    @Test func skippingMidTakeDiscardsWhateverWasCapturedSoFar() async throws {
        let dirs = try makeDirs()
        let step = singleStep(title: "Packing", slug: "packing_cadence")
        let enrollment = EnrollmentEngine(outputDir: dirs.output, assetsDir: dirs.assets, sampleRate: sr, steps: [step])
        await enrollment.start()
        await enrollment.startStepCapture()

        // Feed only the armed pre-onset silence — no completed take yet — then skip mid-flight.
        await feed(enrollment, silence(1.7))
        await enrollment.skipCurrentStep()

        #expect(await enrollment.stage == .finished, "skipping the only step must finish the session")
        #expect(await enrollment.skippedSteps == ["Packing"])
        #expect(await enrollment.totalFilesCaptured == 0)
    }

    // MARK: Packing core-isolation fallback insertion

    @Test func tightPackingCadenceInsertsSeparatedFallbackStep() async throws {
        let dirs = try makeDirs()
        // minSeconds/maxSeconds are sized to this test's *actual* synthetic take length (~1.8s of burst
        // train), not the real packing step's native values (8-25s) — a mismatch there fails the live
        // grader's length gate, forcing an endless redo this single-shot fixture can never satisfy (it
        // has no more signal to feed a retry).
        let step = EnrollmentStep(
            title: "Packing", prompt: "", demoReference: nil, takes: 1, renderMode: .counted, detection: .naturalRhythm,
            minSeconds: 1.0, maxSeconds: 5.0, targetEvents: nil,
            lanes: [CaptureLane(label: .whole, slug: "packing_cadence", style: "packing", type: .inhale, role: "gaps", reference: nil)]
        )
        // This step always routes through `.review` (a reviewer is always configured) — the outcome of
        // that grade is irrelevant to what this test checks, so a short injected deadline keeps the take
        // resolving quickly instead of racing the real 15s `liveGradeDeadlineSec`.
        let enrollment = EnrollmentEngine(
            outputDir: dirs.output, assetsDir: dirs.assets, sampleRate: sr, steps: [step], gradeDeadlineSec: 1.0)
        await enrollment.start()
        await enrollment.startStepCapture()

        // `naturalRhythm` always carries a 5.0s post-arm blackout (baked into `EnrollmentDetection`,
        // not a per-step knob) and a `.gulp` spectral gate (`minCentroidHz: 4500`) — a high-frequency
        // sine burst (not a flat tone) is needed to clear it. Six bursts at 0.3s spacing (< the 0.45s
        // `packingCoreIsolationSec` bar) simulate a too-tight natural cadence.
        var signal = silence(5.2)
        for _ in 0..<6 {
            signal += sineBurst(0.2)
            signal += silence(0.1)
        }
        signal += silence(2.0)
        await feed(enrollment, signal)
        // Inserting the fallback step *advances into it* (not `.finished` — `advance(fromStep:)` checks
        // `step + 1 < steps.count` after the insertion already grew `steps`), so this is the step's own
        // one-and-only take completing, one step short of the whole (single-step) session ending.
        await waitUntil(timeout: 15.0) { await enrollment.stage == .technique(step: 1) }

        #expect(await enrollment.steps.count == 2, "a too-tight cadence must insert the separated fallback step")
        #expect(await enrollment.steps.last?.title == EnrollmentScript.packingSeparatedFallback.title)
        #expect(await enrollment.stepInsertedNotice != nil)
    }
}
