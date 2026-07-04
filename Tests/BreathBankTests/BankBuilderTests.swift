import XCTest
import BreathBank
import BreathEngine

/// End-to-end builder: a synthetic enrollment folder (room tone + good takes + a deliberately clipped
/// take) must produce a v2 manifest, a loadable bank, the prepared caches, and — the invariant PR5/6
/// rely on — fragment offsets that slice the written cache back to the exact graded audio. Denoise is
/// off so the prepared signal is deterministic.
final class BankBuilderTests: XCTestCase {
    private let sr = AudioConstants.workingSampleRate
    private var settings: AssemblerSettings { AssemblerSettings(enableSpectralDenoise: false) }

    private func noise(seed: UInt64, count: Int, amplitude: Float) -> [Float] {
        var rng = SeededRNG(seed: seed)
        return (0..<count).map { _ in (Float(Double(rng.next()) / Double(UInt64.max)) * 2 - 1) * amplitude }
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func assertClose(_ a: [Float], _ b: [Float], tol: Float = 1e-5, _ message: String = "") {
        XCTAssertEqual(a.count, b.count, "length \(message)")
        guard a.count == b.count else { return }
        for i in a.indices where abs(a[i] - b[i]) > tol {
            return XCTFail("sample \(i) differs by \(abs(a[i] - b[i])) \(message)")
        }
    }

    func testBuildCalmBankEndToEnd() throws {
        let cap = try tempDir()
        let out = try tempDir()
        defer {
            try? FileManager.default.removeItem(at: cap)
            try? FileManager.default.removeItem(at: out)
        }

        // Room tone (quiet floor) + three good steady takes + one clipped take.
        try AudioIO.writeMonoWAV(noise(seed: 9, count: Int(sr), amplitude: 0.001),
                                 sampleRate: sr, to: cap.appendingPathComponent("room_tone.wav"))
        for i in 1...3 {
            try AudioIO.writeMonoWAV(noise(seed: UInt64(i), count: Int(10 * sr), amplitude: 0.25),
                                     sampleRate: sr, to: cap.appendingPathComponent("calm_inhale_\(i).wav"))
        }
        var clipped = noise(seed: 4, count: Int(10 * sr), amplitude: 0.25)
        for k in 1_000..<1_012 { clipped[k] = 1.0 }   // a run well above the clip peak
        try AudioIO.writeMonoWAV(clipped, sampleRate: sr, to: cap.appendingPathComponent("calm_inhale_4.wav"))

        let session = CaptureSession(roomTone: "room_tone.wav", steps: [
            .init(slug: "calm_inhale", style: "calm", type: .inhale, renderMode: .textured, role: "texture",
                  reference: nil,
                  files: ["calm_inhale_1.wav", "calm_inhale_2.wav", "calm_inhale_3.wav", "calm_inhale_4.wav"],
                  minSeconds: 5, maxSeconds: 20),
        ])
        try session.write(to: cap.appendingPathComponent("captures.json"))

        let summary = try BankBuilder.build(
            capturesDir: cap, assetsDir: cap, outDir: out, settings: settings, builtAt: "test"
        )
        XCTAssertEqual(summary.banks.count, 1)

        // v2 manifest, room tone wired, fragment-bank sidecar named, takes listed.
        let manifest = try BreathManifest.load(from: out.appendingPathComponent("manifest.json"))
        XCTAssertEqual(manifest.version, 2)
        XCTAssertEqual(manifest.noiseProfile, "room_tone.wav")
        let palette = try XCTUnwrap(manifest.palette(style: "calm", type: .inhale))
        XCTAssertEqual(palette.fragmentBank, "fragments/calm_inhale.frags.json")
        XCTAssertEqual(palette.oneShot.count, 4)

        // Bank loads; its preparedSig matches what the engine would compute from the same config.
        let bank = try FragmentBank.load(from: out.appendingPathComponent("fragments/calm_inhale.frags.json"))
        let roomProfile = SpectralDenoise.magnitudeProfile(
            from: try AudioIO.decodeMono(url: cap.appendingPathComponent("room_tone.wav")), sampleRate: sr
        )
        XCTAssertEqual(bank.preparedSig,
                       FragmentBank.preparedSignature(settings: settings, roomToneProfile: roomProfile))

        // The clipped take is fully rejected; a good take is fully accepted.
        let clippedFrags = bank.fragments.filter { $0.file == "calm_inhale_4.wav" }
        XCTAssertFalse(clippedFrags.isEmpty)
        XCTAssertTrue(clippedFrags.allSatisfy { !$0.accept && $0.reason == "clipped" })
        let goodFrags = bank.acceptedFragments(kind: .grain).filter { $0.file == "calm_inhale_1.wav" }
        XCTAssertFalse(goodFrags.isEmpty)

        // The invariant: slicing the written prepared cache at a fragment's offsets returns exactly
        // the graded grain audio (lossless WAV round-trip + correct bookkeeping).
        let cache = try AudioIO.decodeMono(url: out.appendingPathComponent("calm_inhale_1.prepared.wav"))
        let expected = Segmenter.segment(
            rawTake: try AudioIO.decodeMono(url: cap.appendingPathComponent("calm_inhale_1.wav")),
            role: "texture", type: .inhale, settings: settings, roomToneProfile: roomProfile
        )
        assertClose(cache, try XCTUnwrap(expected.cacheSignal), "prepared cache == segmenter texture")
        for f in goodFrags {
            let slice = Array(cache[f.startFrame..<f.endFrame])
            assertClose(slice, Array(try XCTUnwrap(expected.cacheSignal)[f.startFrame..<f.endFrame]),
                        "grain \(f.startFrame)..<\(f.endFrame)")
        }
    }

    func testBuildPackingBankHasCoresAndGaps() throws {
        let cap = try tempDir()
        let out = try tempDir()
        defer {
            try? FileManager.default.removeItem(at: cap)
            try? FileManager.default.removeItem(at: out)
        }

        try AudioIO.writeMonoWAV(noise(seed: 9, count: Int(sr), amplitude: 0.001),
                                 sampleRate: sr, to: cap.appendingPathComponent("room_tone.wav"))
        // Separated packs (cores) and a steadier-cadence take (gaps).
        func packing(seed: UInt64, gapSec: Double) -> [Float] {
            var sig = [Float]()
            for i in 0..<8 {
                sig += noise(seed: seed &+ UInt64(i), count: Int(0.1 * sr), amplitude: 0.4)
                sig += [Float](repeating: 0, count: Int(gapSec * sr))
            }
            return sig
        }
        try AudioIO.writeMonoWAV(packing(seed: 10, gapSec: 0.6), sampleRate: sr,
                                 to: cap.appendingPathComponent("pack_sep.wav"))
        try AudioIO.writeMonoWAV(packing(seed: 20, gapSec: 0.35), sampleRate: sr,
                                 to: cap.appendingPathComponent("pack_cad.wav"))

        let session = CaptureSession(roomTone: "room_tone.wav", steps: [
            .init(slug: "packing_separated", style: "packing", type: .inhale, renderMode: .counted,
                  role: "cores", reference: nil, files: ["pack_sep.wav"]),
            .init(slug: "packing_cadence", style: "packing", type: .inhale, renderMode: .counted,
                  role: "gaps", reference: nil, files: ["pack_cad.wav"]),
        ])
        try session.write(to: cap.appendingPathComponent("captures.json"))

        _ = try BankBuilder.build(capturesDir: cap, assetsDir: cap, outDir: out, settings: settings, builtAt: "test")

        let bank = try FragmentBank.load(from: out.appendingPathComponent("fragments/packing_inhale.frags.json"))
        XCTAssertGreaterThanOrEqual(bank.acceptedFragments(kind: .gulpCore).count, 4)
        XCTAssertGreaterThanOrEqual(bank.acceptedFragments(kind: .gap).count, 4)

        // Counted styles read oneShot[0] (cores) and oneShot[1] (gaps): the builder orders them so.
        let manifest = try BreathManifest.load(from: out.appendingPathComponent("manifest.json"))
        let palette = try XCTUnwrap(manifest.palette(style: "packing", type: .inhale))
        XCTAssertEqual(palette.oneShot.first?.file, "pack_sep.wav")
        XCTAssertEqual(palette.oneShot.dropFirst().first?.file, "pack_cad.wav")
        XCTAssertEqual(manifest.styles["packing"]?.effectiveRender, .counted)

        // Cores slice their prepared cache; gaps carry only a frame count, no cache.
        let coreCache = try AudioIO.decodeMono(url: out.appendingPathComponent("pack_sep.prepared.wav"))
        for f in bank.acceptedFragments(kind: .gulpCore) {
            XCTAssertEqual(f.file, "pack_sep.wav")
            XCTAssertLessThanOrEqual(f.endFrame, coreCache.count)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.appendingPathComponent("pack_cad.prepared.wav").path))
    }
}
