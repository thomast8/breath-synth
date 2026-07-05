import Testing
import Foundation
@testable import BreathBank
import BreathEngineCore

/// Policy tests for `TakeCaptureEngine`, written from `BreathRecorder`'s native semantics (the port this
/// engine must match): structural validity guards per detection kind, `TakeGate` retry/force-accept,
/// noise-floor seeding order (next take, never its own), unconditional ambient harvest on redo, and
/// overwrite-in-place segment file paths across a review-triggered redo.
struct TakeCaptureEngineTests {
    private let sr = 44_100.0

    // MARK: Signal builders (mirrors `CaptureAnalyzerTests`' fixtures)

    private func silence(_ sec: Double) -> [Float] { [Float](repeating: 0, count: Int(sec * sr)) }
    private func tone(_ sec: Double, _ amp: Float = 0.2) -> [Float] { [Float](repeating: amp, count: Int(sec * sr)) }

    /// A structurally valid calm cycle: armed silence, inhale, mid-pause, exhale, trailing silence.
    private func validCycleSignal() -> [Float] {
        silence(0.3) + tone(1.5) + silence(1.2) + tone(1.5) + silence(1.0)
    }
    private let validCycleDetection = CaptureDetection.cycle(
        minPhaseSec: 0.5, midPauseSec: 0.4, maxCycleSec: 20, trailingSilenceSec: 0.8)

    /// A structurally invalid cycle (no exhale ever detected) — one short armed pre-onset window, not
    /// long enough for `preOnsetFloorRMS`/`quietRangeFrames` to be estimated. `maxCycleSec` sits well
    /// past (~1.3s of margin over) the pause-detection lag, not right at its edge: a redo re-arms
    /// mid-stream, and this fixture is fed as one continuous stream across multiple simulated "takes"
    /// (`feed` doesn't know or care where a take boundary falls, matching real streamed audio) — the
    /// small (sub-hop) leftover a redo's cutoff leaves for the next arm shifts the pause-transition timing
    /// by a few hops each time, and a tight cap-vs-transition margin makes whether `.inhale`'s single
    /// segment gets emitted before the cap fires flip nondeterministically between attempts.
    private func missingExhaleSignal() -> [Float] { silence(0.3) + tone(1.0) + silence(1.8) }
    private let missingExhaleDetection = CaptureDetection.cycle(
        minPhaseSec: 0.4, midPauseSec: 0.4, maxCycleSec: 3.0, trailingSilenceSec: 0.8)

    /// Same structural defect, but with an armed pre-onset window long enough (>1.5s) to harvest a real
    /// `preOnsetFloorRMS`/`quietRangeFrames` — so a redo of this take still exercises the "unconditional
    /// ambient/noise-floor update even when the take is thrown away" contract.
    private func missingExhaleWithLongPreOnsetSignal() -> [Float] { silence(1.8) + tone(1.0) + silence(2.0) }
    private let missingExhaleWithLongPreOnsetDetection = CaptureDetection.cycle(
        minPhaseSec: 0.4, midPauseSec: 0.4, maxCycleSec: 4.5, trailingSilenceSec: 0.8)

    // MARK: Harness

    private func feed(_ engine: TakeCaptureEngine, _ signal: [Float]) async {
        var i = 0
        while i < signal.count {
            let end = min(signal.count, i + 4_096)  // realistic tap buffer size
            await engine.feed(Array(signal[i..<end]))
            i = end
        }
    }

    private func waitUntil(timeout: TimeInterval = 2.0, _ condition: @escaping () async -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    private func makeEngine() -> TakeCaptureEngine { TakeCaptureEngine() }

    // MARK: Structural guard + happy path

    @Test func validCycleTakeIsAcceptedImmediatelyAndAdvances() async throws {
        let engine = makeEngine()
        let recorder = CallRecorder()
        let dir = try makeTempDir()

        await engine.start(
            sampleRate: sr, takes: 1, detection: validCycleDetection, noiseFloorRMS: 0.001,
            fileURL: { takeIndex, label in dir.appendingPathComponent("take\(takeIndex)_\(label.rawValue).wav") },
            onSegment: { takeIndex, label, url, intervals, _ in
                recorder.recordSegment(takeIndex, label, url, intervals)
            },
            onFinished: { recorder.recordFinished() }
        )

        await feed(engine, validCycleSignal())

        #expect(recorder.segments.map(\.1) == [.inhale, .exhale])
        #expect(recorder.segments.allSatisfy { $0.0 == 0 })
        #expect(recorder.finishedCount == 1)
        #expect(await engine.invalidTakes == 0)
        #expect(await engine.lastTakeIssue == nil)
        #expect(await engine.takeIndex == 1)
        #expect(await engine.isRecording == false)
        for (_, _, url, _) in recorder.segments {
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
    }

    // MARK: TakeGate retry / force-accept

    @Test func structurallyInvalidCycleAutoRedoesUpToMaxRetriesThenForceAccepts() async throws {
        let engine = makeEngine()
        let recorder = CallRecorder()
        let dir = try makeTempDir()

        await engine.start(
            sampleRate: sr, takes: 1, detection: missingExhaleDetection, noiseFloorRMS: 0.001,
            fileURL: { takeIndex, label in dir.appendingPathComponent("take\(takeIndex)_\(label.rawValue).wav") },
            onSegment: { takeIndex, label, url, intervals, _ in
                recorder.recordSegment(takeIndex, label, url, intervals)
            },
            onFinished: { recorder.recordFinished() }
        )

        // 4 consecutive structurally-invalid attempts: the first 3 (retries 0,1,2 < maxRetries 3) redo
        // silently — no files written, no onSegment, session stays alive at takeIndex 0. The 4th
        // (retries == 3) is force-accepted so a user who can never pass the guard isn't trapped forever.
        for _ in 0..<4 {
            #expect(await engine.isRecording, "session must still be alive before the force-accept")
            await feed(engine, missingExhaleSignal())
        }

        #expect(await engine.invalidTakes == 4, "every attempt was structurally invalid, redone or not")
        #expect(await engine.lastTakeIssue == .noPauseDetected)
        #expect(recorder.segments.map(\.0) == [0], "fileURL/onSegment only fire once, on the force-accepted 4th attempt")
        #expect(recorder.finishedCount == 1)
        #expect(await engine.isRecording == false)
    }

    // MARK: Structural-retake callback (web UI parity: the participant must be told when a redo happens)

    @Test func structurallyInvalidCycleFiresOnTakeRetakeBeforeReArming() async throws {
        let engine = makeEngine()
        let recorder = CallRecorder()
        let retakeLog = RetakeCallLog()
        let dir = try makeTempDir()

        await engine.start(
            sampleRate: sr, takes: 1, detection: missingExhaleDetection, noiseFloorRMS: 0.001,
            fileURL: { takeIndex, label in dir.appendingPathComponent("take\(takeIndex)_\(label.rawValue).wav") },
            onSegment: { takeIndex, label, url, intervals, _ in
                recorder.recordSegment(takeIndex, label, url, intervals)
            },
            onFinished: { recorder.recordFinished() },
            onTakeRetake: { takeIndex, issue, retries in
                await retakeLog.record(takeIndex: takeIndex, issue: issue, retries: retries)
            }
        )

        // First attempt only: retries 0 < maxRetries 3, so this is a silent redo, not the force-accept —
        // exactly the call `onTakeRetake` exists to surface to the participant.
        await feed(engine, missingExhaleSignal())

        let calls = await retakeLog.calls
        #expect(calls.count == 1)
        #expect(calls.first?.takeIndex == 0)
        #expect(calls.first?.issue == .noPauseDetected)
        #expect(calls.first?.retries == 1, "retries reflects the count after this attempt")
        #expect(await engine.isRecording, "still a redo, not a force-accept")

        // Drive to the force-accepted 4th attempt: `onTakeRetake` must not fire again once the take is
        // actually emitted (that's `onSegment`'s job, a different signal).
        for _ in 0..<3 {
            await feed(engine, missingExhaleSignal())
        }
        let finalCalls = await retakeLog.calls
        #expect(finalCalls.count == 3, "only the 3 genuine redos fire the callback, not the force-accepted 4th")
        #expect(recorder.finishedCount == 1)
    }

    // MARK: Noise-floor seeding + unconditional ambient emission

    @Test func redoneTakeStillUpdatesRollingFloorAndFiresAmbientCallback() async throws {
        let engine = makeEngine()
        let recorder = CallRecorder()
        let dir = try makeTempDir()
        let initialFloor: Float = 0.0008

        await engine.start(
            sampleRate: sr, takes: 2, detection: missingExhaleWithLongPreOnsetDetection, noiseFloorRMS: initialFloor,
            fileURL: { takeIndex, label in dir.appendingPathComponent("take\(takeIndex)_\(label.rawValue).wav") },
            onSegment: { takeIndex, label, url, intervals, _ in
                recorder.recordSegment(takeIndex, label, url, intervals)
            },
            onFinished: { recorder.recordFinished() },
            onTakeAmbient: { samples in recorder.recordAmbient(samples) }
        )

        #expect(await engine.currentNoiseFloorRMS == initialFloor)

        await feed(engine, missingExhaleWithLongPreOnsetSignal())

        // Still just a redo (retries 0 < maxRetries 3) — no segment ever written or registered — but the
        // rolling floor and ambient pool must have updated regardless: "still valid data about current
        // conditions" even though the take itself was thrown away.
        #expect(await engine.invalidTakes == 1)
        #expect(recorder.segments.isEmpty)
        #expect(recorder.ambientCalls.count == 1, "onTakeAmbient fires once per finalized take, redo or not")
        #expect(await engine.currentNoiseFloorRMS != initialFloor, "the rolling floor must move off its seed")
        #expect(await engine.isRecording, "session is still alive — only one redo happened, not a force-accept")
    }

    // MARK: Overwrite-in-place across a reviewer-triggered redo

    @Test func reviewerRedoOverwritesSameFilesInPlaceThenAccepts() async throws {
        let engine = makeEngine()
        let recorder = CallRecorder()
        let dir = try makeTempDir()
        let reviewCalls = ReviewCallLog()

        await engine.start(
            sampleRate: sr, takes: 1, detection: validCycleDetection, noiseFloorRMS: 0.001,
            fileURL: { takeIndex, label in dir.appendingPathComponent("take\(takeIndex)_\(label.rawValue).wav") },
            onSegment: { takeIndex, label, url, intervals, _ in
                recorder.recordSegment(takeIndex, label, url, intervals)
            },
            onFinished: { recorder.recordFinished() },
            onTakeReview: { takeIndex, segments in
                let callNumber = await reviewCalls.record(takeIndex: takeIndex, segments: segments)
                return callNumber == 1 ? .redo : .accept
            }
        )

        // First pass: structurally valid, a reviewer is configured, retries are under the cap -> `.review`.
        // Files get written up front (so the async grade can read them), then the stubbed reviewer says
        // `.redo` on its first call.
        await feed(engine, validCycleSignal())
        await waitUntil { await reviewCalls.count >= 1 }

        #expect(recorder.segments.isEmpty, "onSegment must not fire for a take the reviewer rejects")
        #expect(await engine.invalidTakes == 1, "a review-triggered redo counts as an invalid take too")

        let firstWriteURLs = try await reviewCalls.segments(forCall: 1).map(\.url)
        for url in firstWriteURLs {
            #expect(FileManager.default.fileExists(atPath: url.path), "the rejected take's files are still written to disk")
        }

        // Second pass, same take index: the reviewer's second call accepts. The deterministic
        // `fileURL(takeIndex, label)` closure means this overwrites the exact same paths in place.
        await feed(engine, validCycleSignal())
        await waitUntil { await reviewCalls.count >= 2 }
        await waitUntil { recorder.finishedCount >= 1 }

        let secondWriteURLs = try await reviewCalls.segments(forCall: 2).map(\.url)
        #expect(Set(secondWriteURLs) == Set(firstWriteURLs), "the accepted take reuses the same take-0 file paths")
        #expect(recorder.segments.map(\.0) == [0, 0], "onSegment fires for takeIndex 0 once the reviewer accepts")
        #expect(recorder.finishedCount == 1)
        #expect(await engine.isRecording == false)
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

/// Thread-safe recorder for the `fileURL`/`onSegment`/`onFinished`/`onTakeAmbient` callbacks, which
/// `TakeCaptureEngine` (an actor) may invoke either directly from `feed` or from the unstructured
/// post-review `Task` — both serialized onto the engine's own actor, but observed here from the test's
/// own task, so a lock (not a plain `var`) is what makes reading them afterward safe.
private final class CallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _segments: [(Int, SegmentLabel, URL, [Int])] = []
    private var _finishedCount = 0
    private var _ambientCalls: [[Float]] = []

    var segments: [(Int, SegmentLabel, URL, [Int])] { lock.withLock { _segments } }
    var finishedCount: Int { lock.withLock { _finishedCount } }
    var ambientCalls: [[Float]] { lock.withLock { _ambientCalls } }

    func recordSegment(_ takeIndex: Int, _ label: SegmentLabel, _ url: URL, _ intervals: [Int]) {
        lock.withLock { _segments.append((takeIndex, label, url, intervals)) }
    }
    func recordFinished() { lock.withLock { _finishedCount += 1 } }
    func recordAmbient(_ samples: [Float]) { lock.withLock { _ambientCalls.append(samples) } }
}

/// Records each `onTakeReview` invocation (call number + the segments offered) so a test can drive a
/// scripted verdict sequence and later inspect exactly which files a given call saw.
private actor ReviewCallLog {
    private var calls: [(takeIndex: Int, segments: [(label: SegmentLabel, url: URL)])] = []

    func record(takeIndex: Int, segments: [(label: SegmentLabel, url: URL)]) -> Int {
        calls.append((takeIndex, segments))
        return calls.count
    }

    var count: Int { calls.count }

    struct MissingCall: Error {}

    func segments(forCall number: Int) throws -> [(label: SegmentLabel, url: URL)] {
        guard calls.indices.contains(number - 1) else { throw MissingCall() }
        return calls[number - 1].segments
    }
}

/// Records each `onTakeRetake` invocation for assertion.
private actor RetakeCallLog {
    struct Call: Equatable {
        let takeIndex: Int
        let issue: CaptureAnalyzer.TakeIssue
        let retries: Int
    }
    private(set) var calls: [Call] = []

    func record(takeIndex: Int, issue: CaptureAnalyzer.TakeIssue, retries: Int) {
        calls.append(Call(takeIndex: takeIndex, issue: issue, retries: retries))
    }
}
