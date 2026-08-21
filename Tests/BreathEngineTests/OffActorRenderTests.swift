import Testing
import Foundation
import AVFoundation
@testable import BreathEngine

/// `BreathEngine` is `@MainActor`, so until the render was split every caller assembled breath
/// audio on the main thread and froze for as long as it took — about 0.9s for a five-minute
/// sequence in release, and roughly 75 seconds in debug, where the DSP is unoptimised. In the
/// app that read as a hang: no clock, no touches, no accessibility hierarchy.
///
/// Two things have to stay true for the split to be worth anything. The off-actor render must
/// produce *exactly* what the main-actor one did — this is audio, and "nearly" is a different
/// sound — and it must genuinely be able to run somewhere that is not the main actor.
@MainActor
struct OffActorRenderTests {
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
        var rng = SeededRNG(seed: 7)
        let take = (0..<Int(10 * sr)).map { _ in (Float(Double(rng.next()) / Double(UInt64.max)) * 2 - 1) * 0.25 }
        try writeWAV(take, to: dir.appendingPathComponent("calm.wav"))
        var manifest = BreathManifest()
        manifest.styles["calm"] = StyleManifest(
            inhale: RolePalette(oneShot: [BreathAsset(file: "calm.wav", durationSec: 10, sampleRate: sr, channels: 1)])
        )
        try manifest.write(to: dir.appendingPathComponent("manifest.json"))
        return (try BreathEngine.load(assetsDirectory: dir), dir)
    }

    @Test
    func offActorRenderIsByteIdenticalToTheMainActorOne() async throws {
        let (engine, dir) = try makeEngine()
        defer { try? FileManager.default.removeItem(at: dir) }

        let spec = BreathSpec(type: .inhale, durationSec: 4, style: "calm", seed: 42)
        let onActor = try engine.renderSamples(spec)
        let offActor = try await engine.renderSamplesOffActor(spec)

        #expect(offActor == onActor, "moving the render off the actor changed the audio")
        #expect(!onActor.isEmpty)
    }

    @Test
    func offActorSequenceRenderIsByteIdenticalToTheMainActorOne() async throws {
        let (engine, dir) = try makeEngine()
        defer { try? FileManager.default.removeItem(at: dir) }

        let pattern = BreathPattern(inhaleSec: 3, holdInSec: 1, exhaleSec: 3, holdOutSec: 1, style: "calm", seed: 3)
        let plan = try SequencePlanner.plan(total: 24, pattern: pattern, mode: .closest)

        let onActor = try engine.renderSequenceSamples(plan)
        let offActor = try await engine.renderSequenceSamplesOffActor(plan)

        #expect(offActor == onActor, "moving the sequence render off the actor changed the audio")
        #expect(!onActor.isEmpty)
    }

    /// The property the fix exists for: the assembly runs with no actor at all. If this ever
    /// stops compiling, something has reached back into the engine and the freeze is back.
    @Test
    func theAssemblyNeedsNoActor() async throws {
        let (engine, dir) = try makeEngine()
        defer { try? FileManager.default.removeItem(at: dir) }

        let pattern = BreathPattern(inhaleSec: 3, holdInSec: 0, exhaleSec: 3, holdOutSec: 0, style: "calm", seed: 1)
        let plan = try SequencePlanner.plan(total: 12, pattern: pattern, mode: .closest)
        let entries = try engine.sequenceJobsForTesting(plan)

        let rendered = await Task.detached { BreathEngine.assemble(entries) }.value
        #expect(!rendered.isEmpty)
    }
}
