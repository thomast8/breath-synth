import XCTest
import AVFoundation
@testable import BreathEngine

/// Multi-cycle playback must render `cycles` DISTINCT cycles (the per-cycle golden-ratio seed stride),
/// not one buffer replayed — while cycle 0 still equals a plain single-cycle render (backward
/// compatible). Driven through a synthetic single-take calm palette so it needs no fixtures on disk.
@MainActor
final class CycleIndependenceTests: XCTestCase {
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

    /// A temp assets dir with one steady-noise calm-inhale take + a manifest pointing at it.
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

    func testCyclesDecorrelateAndCycleZeroMatchesSingleRender() throws {
        let (engine, dir) = try makeEngine()
        defer { try? FileManager.default.removeItem(at: dir) }

        let cycle = CycleSpec(
            inhale: BreathSpec(type: .inhale, durationSec: 6, style: "calm", seed: 5),
            holdAfterInhaleSec: 0,
            exhale: BreathSpec(type: .inhale, durationSec: 6, style: "calm", seed: 9),
            holdAfterExhaleSec: 0, loop: false, cycles: 3
        )
        let c0 = try engine.renderCycleSamples(cycle, cycleIndex: 0)
        let c1 = try engine.renderCycleSamples(cycle, cycleIndex: 1)
        let c2 = try engine.renderCycleSamples(cycle, cycleIndex: 2)
        XCTAssertEqual(c0.count, c1.count)
        XCTAssertNotEqual(c0, c1, "consecutive cycles must differ")
        XCTAssertNotEqual(c1, c2)
        XCTAssertNotEqual(c0, c2)

        // Cycle 0 equals a plain single-cycle render of the same seeds (backward compatible).
        let manual = try engine.renderSamples(BreathSpec(type: .inhale, durationSec: 6, style: "calm", seed: 5))
            + (try engine.renderSamples(BreathSpec(type: .inhale, durationSec: 6, style: "calm", seed: 9)))
        XCTAssertEqual(c0, manual)

        // The multi-cycle buffer is exactly the three distinct cycles concatenated.
        let buffer = try engine.renderCycle(cycle)
        XCTAssertEqual(Int(buffer.frameLength), c0.count + c1.count + c2.count)
    }
}
