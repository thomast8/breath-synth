import Testing
import Foundation
@testable import BreathBank
import BreathEngineCore

/// Proves `TakeCaptureEngine.feed` is chunk-size-invariant: a caller's WebSocket frame has no reason to
/// align with any detector boundary, so the exact same fixture fed through in a fixed 4096-sample chunk
/// size and in wildly irregular sizes (1 sample up to 10k+) must produce byte-identical written segments
/// and identical policy outcomes (take index, invalid-take count, structural issue). Covers the two
/// structurally distinct state-machine paths — phase-split (`cycle`) and counted-event (`naturalRhythm`)
/// — rather than all five detection kinds: `finalPhase`/`single` are phase-split variants and
/// `cleanEvents` is a counted-event variant, not fresh machinery.
struct ChunkedReplayTests {
    private let sr = 44_100.0

    private func silence(_ sec: Double) -> [Float] { [Float](repeating: 0, count: Int(sec * sr)) }
    private func tone(_ sec: Double, _ amp: Float = 0.2) -> [Float] { [Float](repeating: amp, count: Int(sec * sr)) }
    private func sineBurst(_ sec: Double, freqHz: Double = 6000, amp: Float = 0.3) -> [Float] {
        let n = Int(sec * sr)
        return (0..<n).map { i in Float(Double(amp) * sin(2 * Double.pi * freqHz * Double(i) / sr)) }
    }

    private struct Outcome {
        var takeIndex: Int
        var invalidTakes: Int
        var lastIssue: CaptureAnalyzer.TakeIssue?
        var segmentBytes: [Data]
    }

    /// Feeds `signal` through a fresh `TakeCaptureEngine`, cycling through `chunkSizes` for each
    /// successive external chunk (a single-element array behaves like a fixed chunk size).
    private func replay(
        _ signal: [Float], detection: CaptureDetection, chunkSizes: [Int], label: String
    ) async throws -> Outcome {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-" + label)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let engine = TakeCaptureEngine()
        let recorder = CallRecorder()
        await engine.start(
            sampleRate: sr, takes: 1, detection: detection, noiseFloorRMS: 0.001,
            fileURL: { i, label in dir.appendingPathComponent("take\(i)_\(label.rawValue).wav") },
            onSegment: { takeIndex, label, url, intervals, _ in recorder.recordSegment(takeIndex, label, url, intervals) },
            onFinished: { recorder.recordFinished() }
        )
        var i = 0
        var chunkCursor = 0
        while i < signal.count {
            let size = max(1, chunkSizes[chunkCursor % chunkSizes.count])
            let end = min(signal.count, i + size)
            await engine.feed(Array(signal[i..<end]))
            i = end
            chunkCursor += 1
        }
        let segmentBytes = try recorder.segments.map { try Data(contentsOf: $0.2) }
        return Outcome(
            takeIndex: await engine.takeIndex, invalidTakes: await engine.invalidTakes,
            lastIssue: await engine.lastTakeIssue, segmentBytes: segmentBytes
        )
    }

    private final class CallRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _segments: [(Int, SegmentLabel, URL, [Int])] = []
        private var _finishedCount = 0
        var segments: [(Int, SegmentLabel, URL, [Int])] { lock.withLock { _segments } }
        var finishedCount: Int { lock.withLock { _finishedCount } }
        func recordSegment(_ takeIndex: Int, _ label: SegmentLabel, _ url: URL, _ intervals: [Int]) {
            lock.withLock { _segments.append((takeIndex, label, url, intervals)) }
        }
        func recordFinished() { lock.withLock { _finishedCount += 1 } }
    }

    @Test func cycleSegmentationIsChunkSizeInvariant() async throws {
        let signal = silence(0.3) + tone(1.5) + silence(1.2) + tone(1.5) + silence(1.0)
        let detection = CaptureDetection.cycle(minPhaseSec: 0.5, midPauseSec: 0.4, maxCycleSec: 20, trailingSilenceSec: 0.8)

        let fixed = try await replay(signal, detection: detection, chunkSizes: [4096], label: "fixed")
        let irregular = try await replay(signal, detection: detection, chunkSizes: [1, 37, 129, 4096, 10007, 512, 3], label: "irregular")

        #expect(fixed.takeIndex == irregular.takeIndex)
        #expect(fixed.invalidTakes == irregular.invalidTakes)
        #expect(fixed.lastIssue == irregular.lastIssue)
        #expect(fixed.segmentBytes.count == 2, "a valid cycle writes inhale + exhale")
        #expect(fixed.segmentBytes == irregular.segmentBytes, "written WAV bytes must be identical regardless of chunking")
    }

    @Test func naturalRhythmCountedEventsAreChunkSizeInvariant() async throws {
        var signal = silence(5.2)  // clears naturalRhythm's fixed 5.0s post-arm blackout
        for _ in 0..<6 {
            signal += sineBurst(0.2)  // clears the .gulp spectral gate's minCentroidHz
            signal += silence(0.4)   // wide gaps: not a tight-cadence case, just needs to segment cleanly
        }
        signal += silence(2.0)
        let detection = CaptureDetection.naturalRhythm(
            minActiveSec: 1.0, maxTakeSec: 15, trailingSilenceSec: 1.0,
            eventMinDistSec: UnitExtractor.gulpMinDistSec, spectralGate: .gulp, postArmBlackoutSec: 5.0
        )

        let fixed = try await replay(signal, detection: detection, chunkSizes: [4096], label: "fixed")
        let irregular = try await replay(signal, detection: detection, chunkSizes: [1, 37, 129, 4096, 10007, 512, 3], label: "irregular")

        #expect(fixed.takeIndex == irregular.takeIndex)
        #expect(fixed.invalidTakes == irregular.invalidTakes)
        #expect(fixed.lastIssue == irregular.lastIssue)
        #expect(fixed.segmentBytes.count == 1, "naturalRhythm writes one whole segment")
        #expect(fixed.segmentBytes == irregular.segmentBytes, "written WAV bytes must be identical regardless of chunking")
    }
}
