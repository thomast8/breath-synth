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

    /// Packing renders from the banked cross-take core + cadence pools. Rigorous + hermetic: the
    /// engine's render must equal `assembleHybrid` over the bank's accepted cores (re-cut + declicked
    /// from the cache, exactly as `AssetLibrary.gulpCorePool` does) and accepted gaps, with the
    /// engine's master gain applied — proving the counted path assembles from the graded pool, not the
    /// raw take.
    /// A banked counted render with no explicit count must default to ONE cadence take's worth of
    /// gulps, not the pooled cross-take total (which would scale the breath with the take count).
    func testBankedCountedDefaultIsOneTakeNotPooledTotal() throws {
        let cap = try tempDir()
        let out = try tempDir()
        defer {
            try? FileManager.default.removeItem(at: cap)
            try? FileManager.default.removeItem(at: out)
        }
        try AudioIO.writeMonoWAV(noise(seed: 9, count: Int(sr), amplitude: 0.001),
                                 sampleRate: sr, to: cap.appendingPathComponent("room_tone.wav"))
        func packing(seed: UInt64) -> [Float] {
            var sig = [Float]()
            for _ in 0..<8 {
                sig += noise(seed: seed, count: Int(0.1 * sr), amplitude: 0.4)
                sig += [Float](repeating: 0, count: Int(0.5 * sr))
            }
            return sig
        }
        try AudioIO.writeMonoWAV(packing(seed: 10), sampleRate: sr, to: cap.appendingPathComponent("pack_sep.wav"))
        try AudioIO.writeMonoWAV(packing(seed: 20), sampleRate: sr, to: cap.appendingPathComponent("pack_cad1.wav"))
        try AudioIO.writeMonoWAV(packing(seed: 30), sampleRate: sr, to: cap.appendingPathComponent("pack_cad2.wav"))
        let session = CaptureSession(roomTone: "room_tone.wav", steps: [
            .init(slug: "packing_separated", style: "packing", type: .inhale, renderMode: .counted,
                  role: "cores", reference: nil, files: ["pack_sep.wav"]),
            .init(slug: "packing_cadence", style: "packing", type: .inhale, renderMode: .counted,
                  role: "gaps", reference: nil, files: ["pack_cad1.wav", "pack_cad2.wav"]),
        ])
        try session.write(to: cap.appendingPathComponent("captures.json"))
        _ = try BankBuilder.build(capturesDir: cap, assetsDir: cap, outDir: out, builtAt: "test")

        let bank = try FragmentBank.load(from: out.appendingPathComponent("fragments/packing_inhale.frags.json"))
        let perTake = Dictionary(grouping: bank.acceptedFragments(kind: .gap), by: \.file).mapValues(\.count)
        let totalGaps = bank.acceptedFragments(kind: .gap).count
        XCTAssertGreaterThan(perTake.count, 1, "two cadence takes pooled")

        let manifest = try BreathManifest.load(from: out.appendingPathComponent("manifest.json"))
        let library = AssetLibrary(baseURL: out, manifest: manifest)
        let defaultEvents = try XCTUnwrap(library.defaultCountedEvents(style: "packing", type: .inhale, expectedSig: nil))
        XCTAssertLessThan(defaultEvents, totalGaps + 1, "default must not be the pooled cross-take total")
        let median = perTake.values.sorted()[perTake.count / 2]
        XCTAssertEqual(defaultEvents, median + 1, "default is one cadence take's worth of gulps")
    }

    func testPackingRendersFromBankPoolMatchingAssembleHybrid() throws {
        let cap = try tempDir()
        let out = try tempDir()
        defer {
            try? FileManager.default.removeItem(at: cap)
            try? FileManager.default.removeItem(at: out)
        }
        try AudioIO.writeMonoWAV(noise(seed: 9, count: Int(sr), amplitude: 0.001),
                                 sampleRate: sr, to: cap.appendingPathComponent("room_tone.wav"))
        // Identical bursts so every core/gap is graded-accepted: the faithful-reconstruction property
        // (bank pool == full single-take set) holds only when grading rejects nothing. (Grading's
        // filtering of bad fragments is covered separately in BankBuilderTests.)
        func packing(seed: UInt64, gapSec: Double) -> [Float] {
            var sig = [Float]()
            for _ in 0..<8 {
                sig += noise(seed: seed, count: Int(0.1 * sr), amplitude: 0.4)
                sig += [Float](repeating: 0, count: Int(gapSec * sr))
            }
            return sig
        }
        try AudioIO.writeMonoWAV(packing(seed: 10, gapSec: 0.6), sampleRate: sr,
                                 to: cap.appendingPathComponent("pack_sep.wav"))
        try AudioIO.writeMonoWAV(packing(seed: 20, gapSec: 0.4), sampleRate: sr,
                                 to: cap.appendingPathComponent("pack_cad.wav"))
        let session = CaptureSession(roomTone: "room_tone.wav", steps: [
            .init(slug: "packing_separated", style: "packing", type: .inhale, renderMode: .counted,
                  role: "cores", reference: nil, files: ["pack_sep.wav"]),
            .init(slug: "packing_cadence", style: "packing", type: .inhale, renderMode: .counted,
                  role: "gaps", reference: nil, files: ["pack_cad.wav"]),
        ])
        try session.write(to: cap.appendingPathComponent("captures.json"))
        _ = try BankBuilder.build(capturesDir: cap, assetsDir: cap, outDir: out, builtAt: "test")

        let engine = try BreathEngine.load(assetsDirectory: out)
        let a = try engine.renderCountedSamples(style: "packing", type: .inhale, count: 12, seed: 7)
        let b = try engine.renderCountedSamples(style: "packing", type: .inhale, count: 12, seed: 7)
        XCTAssertEqual(a, b, "same seed → identical pooled hybrid render")

        // Reconstruct the expected render from the bank pool exactly as the engine's counted path does:
        // accepted cores re-cut + declicked from the cache, accepted gaps in order, assembleHybrid at
        // the same seed, then the engine's master gain (masterGain 1.0 · headroom -1 dB) and clamp.
        let bank = try FragmentBank.load(from: out.appendingPathComponent("fragments/packing_inhale.frags.json"))
        let cache = try AudioIO.decodeMono(url: out.appendingPathComponent("pack_sep.prepared.wav"))
        let cores = bank.acceptedFragments(kind: .gulpCore).map {
            UnitExtractor.declickedCore(Array(cache[$0.startFrame..<$0.endFrame]), sampleRate: sr)
        }
        let gaps = bank.acceptedFragments(kind: .gap).compactMap(\.gapToNext).filter { $0 > 0 }
        XCTAssertFalse(cores.isEmpty)
        XCTAssertFalse(gaps.isEmpty)
        var expected = BreathAssembler.assembleHybrid(cores: cores, gaps: gaps, count: 12,
                                                      settings: AssemblerSettings(), seed: 7)
        let gain = Float(Variation.dbToGain(-1.0))
        expected = expected.map { min(1, max(-1, $0 * gain)) }
        XCTAssertEqual(a, expected, "engine counted render equals assembleHybrid over the accepted pool")
    }

    /// frc/rv (oneShot) restrict the take pick to the bank's accepted takes. The rejected take here is
    /// distinctly LONGER (and clipped, so it's rejected): a no-bank engine sometimes renders that long
    /// length across seeds, but the bank engine — filtered to the short accepted takes — never does.
    func testOneShotPickRestrictedToAcceptedTakes() throws {
        let cap = try tempDir()
        let out = try tempDir()
        defer {
            try? FileManager.default.removeItem(at: cap)
            try? FileManager.default.removeItem(at: out)
        }
        try AudioIO.writeMonoWAV(noise(seed: 9, count: Int(sr), amplitude: 0.001),
                                 sampleRate: sr, to: cap.appendingPathComponent("room_tone.wav"))
        func body(seed: UInt64, seconds: Double) -> [Float] {
            var s = [Float](repeating: 0, count: Int(0.3 * sr))
            s += noise(seed: seed, count: Int(seconds * sr), amplitude: 0.3)
            s += [Float](repeating: 0, count: Int(0.3 * sr))
            return s
        }
        for i in 1...3 {  // three clean, short (~4 s) accepted bodies
            try AudioIO.writeMonoWAV(body(seed: UInt64(i), seconds: 4), sampleRate: sr,
                                     to: cap.appendingPathComponent("frc_\(i).wav"))
        }
        var bad = body(seed: 4, seconds: 8)  // distinctly long, and clipped → rejected
        for k in 2_000..<2_012 { bad[k] = 1.0 }
        try AudioIO.writeMonoWAV(bad, sampleRate: sr, to: cap.appendingPathComponent("frc_4.wav"))

        let session = CaptureSession(roomTone: "room_tone.wav", steps: [
            .init(slug: "frc_exhale", style: "frc", type: .exhale, renderMode: .oneShot, role: "oneShotBody",
                  reference: nil, files: ["frc_1.wav", "frc_2.wav", "frc_3.wav", "frc_4.wav"]),
        ])
        try session.write(to: cap.appendingPathComponent("captures.json"))
        _ = try BankBuilder.build(capturesDir: cap, assetsDir: cap, outDir: out, builtAt: "test")

        let bank = try FragmentBank.load(from: out.appendingPathComponent("fragments/frc_exhale.frags.json"))
        XCTAssertEqual(bank.fragments.filter { !$0.accept }.map(\.file), ["frc_4.wav"])
        XCTAssertEqual(Set(bank.acceptedFragments(kind: .oneShotBody).map(\.file)),
                       ["frc_1.wav", "frc_2.wav", "frc_3.wav"])

        func lengths(_ engine: BreathEngine) throws -> Set<Int> {
            var lens = Set<Int>()
            for seed: UInt64 in 0..<32 {
                lens.insert(try engine.renderSamples(BreathSpec(type: .exhale, durationSec: 4, style: "frc", seed: seed)).count)
            }
            return lens
        }

        let banked = try lengths(BreathEngine.load(assetsDirectory: out))
        try FileManager.default.removeItem(at: out.appendingPathComponent("fragments"))
        let unbanked = try lengths(BreathEngine.load(assetsDirectory: out))

        let longest = unbanked.max() ?? 0           // the long frc_4 body — only reachable without the bank
        XCTAssertGreaterThan(longest, banked.max() ?? 0, "no-bank can draw the long rejected take")
        XCTAssertFalse(banked.contains(longest), "the bank never renders the rejected take")
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
