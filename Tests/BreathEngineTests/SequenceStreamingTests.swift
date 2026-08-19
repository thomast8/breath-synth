import Testing
import Foundation
import AVFoundation
@testable import BreathEngine

/// Streaming a sequence must not change what it sounds like.
///
/// `playSequence` renders one cycle at a time and queues it ahead of the playhead, so that
/// time-to-first-sound and resident audio stay flat as the sequence gets longer. Each cycle is
/// seeded off its index, so the only way that is safe is if the cycles it renders are the same
/// cycles, in the same order, as the whole-buffer render would have produced. This pins that:
/// the concatenation of the per-cycle renders is sample-for-sample `renderSequenceSamples`.
///
/// Driven through a synthetic single-take calm palette so it needs no fixtures on disk, and it
/// tests the render decomposition rather than the audio queue — scheduling on a real
/// `AVAudioPlayerNode` needs an output device, which CI does not have.
@MainActor
struct SequenceStreamingTests {
    private let sr = AudioConstants.workingSampleRate

    private func writeWAV(_ samples: [Float], to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sr, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
        ]
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sr, channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        try file.write(from: buffer)
    }

    private func makeEngine() throws -> (engine: BreathEngine, dir: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var rng = SeededRNG(seed: 1)
        let take = (0..<Int(10 * sr)).map { _ in (Float(Double(rng.next()) / Double(UInt64.max)) * 2 - 1) * 0.25 }
        try writeWAV(take, to: dir.appendingPathComponent("calm.wav"))
        var manifest = BreathManifest()
        manifest.styles["calm"] = StyleManifest(
            inhale: RolePalette(oneShot: [BreathAsset(file: "calm.wav", durationSec: 10, sampleRate: sr, channels: 1)])
        )
        try manifest.write(to: dir.appendingPathComponent("manifest.json"))
        return (try BreathEngine.load(assetsDirectory: dir), dir)
    }

    private func plan(cycles: Int, holdIn: Double = 0, holdOut: Double = 0) throws -> SequencePlan {
        let pattern = BreathPattern(
            inhaleSec: 3, holdInSec: holdIn, exhaleSec: 4, holdOutSec: holdOut, style: "calm"
        )
        return try SequencePlanner.plan(
            total: Double(cycles) * pattern.cycleSec, pattern: pattern, mode: .strict
        )
    }

    @Test
    func testStreamedCyclesConcatenateToTheWholeBufferRender() throws {
        let (engine, dir) = try makeEngine()
        defer { try? FileManager.default.removeItem(at: dir) }

        let plan = try plan(cycles: 4)
        let whole = try engine.renderSequenceSamples(plan)

        var streamed: [Float] = []
        for index in 0..<plan.cycles {
            streamed += try engine.sequenceCycleSamples(plan.pattern, cycleIndex: index)
        }

        #expect(streamed == whole)
    }

    /// The holds are part of a cycle, not glue between cycles — a streamed cycle has to carry its
    /// own silence or the seams lose time.
    @Test
    func testCycleSamplesCarryTheirOwnHolds() throws {
        let (engine, dir) = try makeEngine()
        defer { try? FileManager.default.removeItem(at: dir) }

        let plan = try plan(cycles: 3, holdIn: 1, holdOut: 2)
        var streamed: [Float] = []
        for index in 0..<plan.cycles {
            streamed += try engine.sequenceCycleSamples(plan.pattern, cycleIndex: index)
        }

        #expect(streamed == (try engine.renderSequenceSamples(plan)))
        // 3 cycles of 3 + 1 + 4 + 2 seconds, within a frame of rounding per segment.
        #expect(abs(Double(streamed.count) / sr - 30) < 0.01)
    }

    /// Consecutive cycles must still decorrelate when they come from the streaming path — the
    /// whole point of seeding by index is that a sequence does not sound like one loop.
    @Test
    func testStreamedCyclesStillDecorrelate() throws {
        let (engine, dir) = try makeEngine()
        defer { try? FileManager.default.removeItem(at: dir) }

        let pattern = try plan(cycles: 2).pattern
        let first = try engine.sequenceCycleSamples(pattern, cycleIndex: 0)
        let second = try engine.sequenceCycleSamples(pattern, cycleIndex: 1)

        #expect(first.count == second.count)
        #expect(first != second)
    }
}
