import XCTest
import BreathBank
import BreathEngine

/// End-to-end PR5: build a calm bank, then render through `BreathEngine` and confirm the engine draws
/// from the cross-take grain pool — deterministically, varying by seed, and audibly different from the
/// single-take loop it replaces. Built with the engine's *default* settings (denoise on) so the bank's
/// `preparedSig` matches what the engine expects and the pool is actually adopted.
@MainActor
final class PoolRenderTests: XCTestCase {
    private let sr = AudioConstants.workingSampleRate

    private func noise(seed: UInt64, count: Int, amplitude: Float) -> [Float] {
        var rng = SeededRNG(seed: seed)
        return (0..<count).map { _ in (Float(Double(rng.next()) / Double(UInt64.max)) * 2 - 1) * amplitude }
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Build a calm-inhale bank bundle from three steady takes and return its directory.
    private func buildCalmBank() throws -> (bundle: URL, cleanup: () -> Void) {
        let cap = try tempDir()
        let out = try tempDir()
        try AudioIO.writeMonoWAV(noise(seed: 9, count: Int(sr), amplitude: 0.001),
                                 sampleRate: sr, to: cap.appendingPathComponent("room_tone.wav"))
        for i in 1...3 {
            try AudioIO.writeMonoWAV(noise(seed: UInt64(i), count: Int(11 * sr), amplitude: 0.25),
                                     sampleRate: sr, to: cap.appendingPathComponent("calm_inhale_\(i).wav"))
        }
        let session = CaptureSession(roomTone: "room_tone.wav", steps: [
            .init(slug: "calm_inhale", style: "calm", type: .inhale, renderMode: .textured, role: "texture",
                  reference: nil, files: ["calm_inhale_1.wav", "calm_inhale_2.wav", "calm_inhale_3.wav"],
                  minSeconds: 5, maxSeconds: 20),
        ])
        try session.write(to: cap.appendingPathComponent("captures.json"))
        _ = try BankBuilder.build(capturesDir: cap, assetsDir: cap, outDir: out, builtAt: "test")
        return (out, {
            try? FileManager.default.removeItem(at: cap)
            try? FileManager.default.removeItem(at: out)
        })
    }

    private func spec(seed: UInt64) -> BreathSpec {
        BreathSpec(type: .inhale, durationSec: 8, style: "calm", seed: seed)
    }

    func testPooledRenderIsDeterministicAndSeedDependent() throws {
        let (bundle, cleanup) = try buildCalmBank()
        defer { cleanup() }
        let engine = try BreathEngine.load(assetsDirectory: bundle)

        let a = try engine.renderSamples(spec(seed: 42))
        let b = try engine.renderSamples(spec(seed: 42))
        XCTAssertEqual(a, b, "same seed → identical pooled render")

        let c = try engine.renderSamples(spec(seed: 99))
        XCTAssertEqual(a.count, c.count)
        XCTAssertNotEqual(a, c, "a different seed draws a different grain succession")
    }

    func testPoolChangesRenderVersusSingleTextureLoop() throws {
        let (bundle, cleanup) = try buildCalmBank()
        defer { cleanup() }

        let pooled = try BreathEngine.load(assetsDirectory: bundle).renderSamples(spec(seed: 7))
        // Drop the bank so a fresh engine falls back to the single-take texture loop on the same takes.
        try FileManager.default.removeItem(at: bundle.appendingPathComponent("fragments"))
        let single = try BreathEngine.load(assetsDirectory: bundle).renderSamples(spec(seed: 7))

        XCTAssertEqual(pooled.count, single.count)
        XCTAssertNotEqual(pooled, single, "the cross-take grain pool renders differently from the single-take loop")
    }

    /// Consecutive cycles must not be the same buffer repeated: the per-cycle golden-ratio seed makes
    /// each cycle draw an independent grain succession from the pool.
    func testSequenceCyclesDrawIndependentlyFromPool() throws {
        let (bundle, cleanup) = try buildCalmBank()
        defer { cleanup() }
        let engine = try BreathEngine.load(assetsDirectory: bundle)

        let pattern = BreathPattern(inhaleSec: 8, holdInSec: 0, exhaleSec: 8, holdOutSec: 0, style: "calm", seed: 1)
        let plan = try SequencePlanner.plan(total: 48, pattern: pattern, mode: .closest)
        let full = try engine.renderSequenceSamples(plan)

        // Slice the inhale of cycle 0 and cycle 1 (each cycle = inhale ++ exhale, no holds) and compare.
        let inhaleLen = Segments.frames(seconds: 8, sampleRate: sr)
        let cycleLen = inhaleLen * 2
        XCTAssertGreaterThanOrEqual(full.count, cycleLen * 2)
        let inhale0 = Array(full[0..<inhaleLen])
        let inhale1 = Array(full[cycleLen..<(cycleLen + inhaleLen)])
        XCTAssertNotEqual(inhale0, inhale1, "consecutive cycles must not be the identical buffer")
    }
}
