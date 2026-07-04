import Testing
import BreathBank
import BreathEngine

/// The segmenter must cut fragments whose offsets reproduce the exact audio the engine renders, with
/// the same grain geometry as `recordedShapeBranch` and the same cores as `assembleHybrid`. Denoise
/// is off so the prepared signal is a deterministic function of the input (trim + high-pass only).
struct SegmenterTests {
    private let sr = AudioConstants.workingSampleRate
    private var settings: AssemblerSettings { AssemblerSettings(enableSpectralDenoise: false) }

    private func noise(seed: UInt64, count: Int, amplitude: Float) -> [Float] {
        var rng = SeededRNG(seed: seed)
        return (0..<count).map { _ in (Float(Double(rng.next()) / Double(UInt64.max)) * 2 - 1) * amplitude }
    }

    // MARK: - texture → grains

    @Test
    func testTextureGrainsTileWithEngineGeometry() {
        let take = noise(seed: 1, count: Int(10 * sr), amplitude: 0.25)
        let out = Segmenter.segment(rawTake: take, role: "texture", type: .inhale,
                                    settings: settings, roomToneProfile: nil)
        let texture = try? #require(out.cacheSignal)
        guard let texture else { return }

        let grain = min(texture.count, Segments.frames(seconds: 2.5, sampleRate: sr))
        #expect(out.fragments.count >= 3, "a 10 s take should yield several grains")
        for f in out.fragments {
            #expect(f.kind == .grain)
            #expect(f.endFrame - f.startFrame == grain, "uniform grain length")
            #expect(Array(texture[f.startFrame..<f.endFrame]) == f.audio, "offset reproduces the grain audio")
        }
        // Stride mirrors the engine: 2.5 s grain − 0.7 s crossfade.
        let stride = out.fragments[1].startFrame - out.fragments[0].startFrame
        #expect(stride == grain - Segments.frames(seconds: 0.7, sampleRate: sr))
    }

    // MARK: - oneShotBody → whole trimmed maneuver

    @Test
    func testOneShotBodyIsWholeTrimmedBodyAndNeedsNoCache() {
        var sig = [Float](repeating: 0, count: Int(0.5 * sr))
        sig += noise(seed: 2, count: Int(3 * sr), amplitude: 0.3)
        sig += [Float](repeating: 0, count: Int(0.5 * sr))

        let out = Segmenter.segment(rawTake: sig, role: "oneShotBody", type: .exhale,
                                    settings: settings, roomToneProfile: nil)
        #expect(out.cacheSignal == nil, "frc/rv are re-derived per take at render — no on-disk cache")
        #expect(out.fragments.count == 1)
        let body = out.fragments[0]
        #expect(body.kind == .oneShotBody)
        #expect(body.startFrame == 0)
        #expect(body.endFrame == body.audio.count)
        #expect(body.audio.count < sig.count, "the padded silence is trimmed off")
        #expect(body.audio.count > Int(2 * sr), "the ~3 s body survives")
        #expect(body.peakHeight != nil)
    }

    // MARK: - cores → declicked gulp events

    @Test
    func testCoresReproduceDeclickedPreparedSlices() {
        var sig = [Float]()
        for i in 0..<6 {
            sig += noise(seed: UInt64(100 + i), count: Int(0.1 * sr), amplitude: 0.4)
            sig += [Float](repeating: 0, count: Int(0.5 * sr))
        }
        let out = Segmenter.segment(rawTake: sig, role: "cores", type: .inhale,
                                    settings: settings, roomToneProfile: nil)
        let prepared = try? #require(out.cacheSignal)
        guard let prepared else { return }

        #expect(out.fragments.count >= 4, "≈6 separated bursts detected")
        for f in out.fragments {
            #expect(f.kind == .gulpCore)
            let expected = UnitExtractor.declickedCore(Array(prepared[f.startFrame..<f.endFrame]), sampleRate: sr)
            #expect(f.audio == expected, "offset + declick reproduces the rendered core")
            #expect(f.peakHeight != nil)
        }
        #expect(out.fragments.first?.gapToNext != nil, "interior cores carry the inter-onset gap")
        #expect(out.fragments.last?.gapToNext == nil, "the last core has no successor")
    }

    /// Invariant #2 against the engine itself: the bank's core audios must equal what the engine
    /// renders via `UnitExtractor.gulpCores(prepared)` — not merely be self-consistent. This pins the
    /// `gulpCores ≡ gulpCoreRanges.map { declickedCore }` identity that PR6's render path relies on.
    @Test
    func testCoresMatchEngineGulpCoresExactly() {
        var sig = [Float]()
        for i in 0..<6 {
            sig += noise(seed: UInt64(300 + i), count: Int(0.1 * sr), amplitude: 0.4)
            sig += [Float](repeating: 0, count: Int(0.5 * sr))
        }
        let out = Segmenter.segment(rawTake: sig, role: "cores", type: .inhale,
                                    settings: settings, roomToneProfile: nil)
        let prepared = try? #require(out.cacheSignal)
        guard let prepared else { return }
        #expect(out.fragments.map(\.audio) == UnitExtractor.gulpCores(from: prepared, sampleRate: sr))
    }

    // MARK: - gaps → cadence intervals

    @Test
    func testGapsAreRhythmIntervalsWithNoAudio() throws {
        var sig = [Float]()
        for i in 0..<6 {
            sig += noise(seed: UInt64(200 + i), count: Int(0.1 * sr), amplitude: 0.4)
            sig += [Float](repeating: 0, count: Int(0.5 * sr))
        }
        let out = Segmenter.segment(rawTake: sig, role: "gaps", type: .inhale,
                                    settings: settings, roomToneProfile: nil)
        #expect(out.cacheSignal == nil)
        #expect(out.fragments.count >= 3)
        var lastStart = -1
        for f in out.fragments {
            #expect(f.kind == .gap)
            #expect(f.audio.isEmpty)
            let gap = try #require(f.gapToNext)
            #expect(gap > 0)
            #expect(f.endFrame == f.startFrame + gap)
            #expect(f.startFrame > lastStart, "onset offsets increase so the cadence order survives a stable sort")
            lastStart = f.startFrame
        }
    }

    // MARK: - minEventDistSec (Step 5.1 — style-aware event spacing)

    /// Recovery's hook-breath double-sip must merge at `hookMinDistSec`, not the packing-tuned
    /// `gulpMinDistSec` default — aligning `Segmenter`'s bank-side geometry (cores and gaps) with the
    /// engine's own one-take `UnitExtractor.extract` render path, which already merges at this floor.
    @Test
    func testCoresMinEventDistSecMergesRecoverySpacing() {
        var sig = [Float]()
        for i in 0..<4 {
            sig += noise(seed: UInt64(400 + i), count: Int(0.1 * sr), amplitude: 0.4)
            sig += [Float](repeating: 0, count: Int(0.5 * sr))   // 0.5s apart: merges under hook, splits under gulp
        }
        let gulpSpaced = Segmenter.segment(rawTake: sig, role: "cores", type: .inhale, settings: settings,
                                           roomToneProfile: nil, minEventDistSec: UnitExtractor.gulpMinDistSec)
        let hookSpaced = Segmenter.segment(rawTake: sig, role: "cores", type: .inhale, settings: settings,
                                           roomToneProfile: nil, minEventDistSec: UnitExtractor.hookMinDistSec)
        #expect(gulpSpaced.fragments.count > hookSpaced.fragments.count,
                             "the 0.22s floor must resolve more distinct cores than the 0.70s floor on the same audio")
    }

    @Test
    func testGapsMinEventDistSecMergesRecoverySpacing() {
        var sig = [Float]()
        for i in 0..<4 {
            sig += noise(seed: UInt64(500 + i), count: Int(0.1 * sr), amplitude: 0.4)
            sig += [Float](repeating: 0, count: Int(0.5 * sr))
        }
        let gulpSpaced = Segmenter.segment(rawTake: sig, role: "gaps", type: .inhale, settings: settings,
                                           roomToneProfile: nil, minEventDistSec: UnitExtractor.gulpMinDistSec)
        let hookSpaced = Segmenter.segment(rawTake: sig, role: "gaps", type: .inhale, settings: settings,
                                           roomToneProfile: nil, minEventDistSec: UnitExtractor.hookMinDistSec)
        #expect(gulpSpaced.fragments.count > hookSpaced.fragments.count,
                             "the 0.22s floor must resolve more distinct gaps than the 0.70s floor on the same audio")
    }

    @Test
    func testEventSpacingForStyle() {
        #expect(Segmenter.eventSpacing(forStyle: "recovery") == UnitExtractor.hookMinDistSec)
        #expect(Segmenter.eventSpacing(forStyle: "packing") == UnitExtractor.gulpMinDistSec)
        #expect(Segmenter.eventSpacing(forStyle: "calm") == UnitExtractor.gulpMinDistSec)
    }
}
