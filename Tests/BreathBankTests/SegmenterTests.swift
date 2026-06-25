import XCTest
import BreathBank
import BreathEngine

/// The segmenter must cut fragments whose offsets reproduce the exact audio the engine renders, with
/// the same grain geometry as `recordedShapeBranch` and the same cores as `assembleHybrid`. Denoise
/// is off so the prepared signal is a deterministic function of the input (trim + high-pass only).
final class SegmenterTests: XCTestCase {
    private let sr = AudioConstants.workingSampleRate
    private var settings: AssemblerSettings { AssemblerSettings(enableSpectralDenoise: false) }

    private func noise(seed: UInt64, count: Int, amplitude: Float) -> [Float] {
        var rng = SeededRNG(seed: seed)
        return (0..<count).map { _ in (Float(Double(rng.next()) / Double(UInt64.max)) * 2 - 1) * amplitude }
    }

    // MARK: - texture → grains

    func testTextureGrainsTileWithEngineGeometry() {
        let take = noise(seed: 1, count: Int(10 * sr), amplitude: 0.25)
        let out = Segmenter.segment(rawTake: take, role: "texture", type: .inhale,
                                    settings: settings, roomToneProfile: nil)
        let texture = try? XCTUnwrap(out.cacheSignal)
        guard let texture else { return }

        let grain = min(texture.count, Segments.frames(seconds: 2.5, sampleRate: sr))
        XCTAssertGreaterThanOrEqual(out.fragments.count, 3, "a 10 s take should yield several grains")
        for f in out.fragments {
            XCTAssertEqual(f.kind, .grain)
            XCTAssertEqual(f.endFrame - f.startFrame, grain, "uniform grain length")
            XCTAssertEqual(Array(texture[f.startFrame..<f.endFrame]), f.audio, "offset reproduces the grain audio")
        }
        // Stride mirrors the engine: 2.5 s grain − 0.7 s crossfade.
        let stride = out.fragments[1].startFrame - out.fragments[0].startFrame
        XCTAssertEqual(stride, grain - Segments.frames(seconds: 0.7, sampleRate: sr))
    }

    // MARK: - oneShotBody → whole trimmed maneuver

    func testOneShotBodyIsWholeTrimmedBodyAndNeedsNoCache() {
        var sig = [Float](repeating: 0, count: Int(0.5 * sr))
        sig += noise(seed: 2, count: Int(3 * sr), amplitude: 0.3)
        sig += [Float](repeating: 0, count: Int(0.5 * sr))

        let out = Segmenter.segment(rawTake: sig, role: "oneShotBody", type: .exhale,
                                    settings: settings, roomToneProfile: nil)
        XCTAssertNil(out.cacheSignal, "frc/rv are re-derived per take at render — no on-disk cache")
        XCTAssertEqual(out.fragments.count, 1)
        let body = out.fragments[0]
        XCTAssertEqual(body.kind, .oneShotBody)
        XCTAssertEqual(body.startFrame, 0)
        XCTAssertEqual(body.endFrame, body.audio.count)
        XCTAssertLessThan(body.audio.count, sig.count, "the padded silence is trimmed off")
        XCTAssertGreaterThan(body.audio.count, Int(2 * sr), "the ~3 s body survives")
        XCTAssertNotNil(body.peakHeight)
    }

    // MARK: - cores → declicked gulp events

    func testCoresReproduceDeclickedPreparedSlices() {
        var sig = [Float]()
        for i in 0..<6 {
            sig += noise(seed: UInt64(100 + i), count: Int(0.1 * sr), amplitude: 0.4)
            sig += [Float](repeating: 0, count: Int(0.5 * sr))
        }
        let out = Segmenter.segment(rawTake: sig, role: "cores", type: .inhale,
                                    settings: settings, roomToneProfile: nil)
        let prepared = try? XCTUnwrap(out.cacheSignal)
        guard let prepared else { return }

        XCTAssertGreaterThanOrEqual(out.fragments.count, 4, "≈6 separated bursts detected")
        for f in out.fragments {
            XCTAssertEqual(f.kind, .gulpCore)
            let expected = UnitExtractor.declickedCore(Array(prepared[f.startFrame..<f.endFrame]), sampleRate: sr)
            XCTAssertEqual(f.audio, expected, "offset + declick reproduces the rendered core")
            XCTAssertNotNil(f.peakHeight)
        }
        XCTAssertNotNil(out.fragments.first?.gapToNext, "interior cores carry the inter-onset gap")
        XCTAssertNil(out.fragments.last?.gapToNext, "the last core has no successor")
    }

    /// Invariant #2 against the engine itself: the bank's core audios must equal what the engine
    /// renders via `UnitExtractor.gulpCores(prepared)` — not merely be self-consistent. This pins the
    /// `gulpCores ≡ gulpCoreRanges.map { declickedCore }` identity that PR6's render path relies on.
    func testCoresMatchEngineGulpCoresExactly() {
        var sig = [Float]()
        for i in 0..<6 {
            sig += noise(seed: UInt64(300 + i), count: Int(0.1 * sr), amplitude: 0.4)
            sig += [Float](repeating: 0, count: Int(0.5 * sr))
        }
        let out = Segmenter.segment(rawTake: sig, role: "cores", type: .inhale,
                                    settings: settings, roomToneProfile: nil)
        let prepared = try? XCTUnwrap(out.cacheSignal)
        guard let prepared else { return }
        XCTAssertEqual(out.fragments.map(\.audio), UnitExtractor.gulpCores(from: prepared, sampleRate: sr))
    }

    // MARK: - gaps → cadence intervals

    func testGapsAreRhythmIntervalsWithNoAudio() throws {
        var sig = [Float]()
        for i in 0..<6 {
            sig += noise(seed: UInt64(200 + i), count: Int(0.1 * sr), amplitude: 0.4)
            sig += [Float](repeating: 0, count: Int(0.5 * sr))
        }
        let out = Segmenter.segment(rawTake: sig, role: "gaps", type: .inhale,
                                    settings: settings, roomToneProfile: nil)
        XCTAssertNil(out.cacheSignal)
        XCTAssertGreaterThanOrEqual(out.fragments.count, 3)
        var lastStart = -1
        for f in out.fragments {
            XCTAssertEqual(f.kind, .gap)
            XCTAssertTrue(f.audio.isEmpty)
            let gap = try XCTUnwrap(f.gapToNext)
            XCTAssertGreaterThan(gap, 0)
            XCTAssertEqual(f.endFrame, f.startFrame + gap)
            XCTAssertGreaterThan(f.startFrame, lastStart, "onset offsets increase so the cadence order survives a stable sort")
            lastStart = f.startFrame
        }
    }
}
