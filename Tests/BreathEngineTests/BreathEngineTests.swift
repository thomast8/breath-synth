import XCTest
@testable import BreathEngine

final class SegmentsTests: XCTestCase {
    func testFramesRounding() {
        XCTAssertEqual(Segments.frames(seconds: 1, sampleRate: 44_100), 44_100)
        XCTAssertEqual(Segments.frames(seconds: 0.5, sampleRate: 44_100), 22_050)
        XCTAssertEqual(Segments.frames(seconds: 0, sampleRate: 44_100), 0)
    }

    func testClampCrossfade() {
        XCTAssertEqual(Segments.clampCrossfade(1000, loopLen: 500, startLen: 800, endLen: 800), 499)
        XCTAssertEqual(Segments.clampCrossfade(100, loopLen: 500, startLen: 800, endLen: 800), 100)
        XCTAssertEqual(Segments.clampCrossfade(0, loopLen: 500, startLen: 800, endLen: 800), 1)
    }

    func testLoopIterationCountIsMinimalCovering() {
        let loopLen = 1000, x = 200
        let middleLen = 3000
        let n = Segments.loopIterationCount(middleLen: middleLen, loopLen: loopLen, crossfadeLen: x)
        let span = Segments.spannedFrames(iterations: n, loopLen: loopLen, crossfadeLen: x)
        let prevSpan = Segments.spannedFrames(iterations: n - 1, loopLen: loopLen, crossfadeLen: x)
        XCTAssertGreaterThanOrEqual(span, middleLen)
        XCTAssertLessThan(prevSpan, middleLen)
    }

    func testSingleIterationWhenMiddleShorterThanLoop() {
        XCTAssertEqual(Segments.loopIterationCount(middleLen: 400, loopLen: 1000, crossfadeLen: 200), 1)
    }
}

final class CrossfadeTests: XCTestCase {
    func testFadeEndpoints() {
        let n = 256
        let fIn = Crossfade.fadeIn(n)
        let fOut = Crossfade.fadeOut(n)
        XCTAssertEqual(fIn.first!, 0, accuracy: 1e-6)
        XCTAssertEqual(fIn.last!, 1, accuracy: 1e-6)
        XCTAssertEqual(fOut.first!, 1, accuracy: 1e-6)
        XCTAssertEqual(fOut.last!, 0, accuracy: 1e-6)
    }

    func testEqualPowerInvariant() {
        let n = 512
        let fIn = Crossfade.fadeIn(n)
        let fOut = Crossfade.fadeOut(n)
        for i in 0..<n {
            XCTAssertEqual(fIn[i] * fIn[i] + fOut[i] * fOut[i], 1, accuracy: 1e-5)
        }
    }

    func testPlaceNoLoudnessDipForCorrelatedSignals() {
        // Mixing two DC-1 signals across an equal-power crossfade never dips below 1.
        let n = 300
        var out = [Float](repeating: 1, count: n)
        let segment = [Float](repeating: 1, count: n)
        Crossfade.place(into: &out, segment: segment, at: 0, headCrossfade: n)
        for value in out {
            XCTAssertGreaterThanOrEqual(value, 1 - 1e-4)
        }
    }

    func testAssembleLoopedMiddleExactLength() {
        let loop = (0..<1000).map { sin(Float($0) * 0.01) }
        let multi = Crossfade.assembleLoopedMiddle(loop: loop, targetLen: 3333, crossfadeLen: 200)
        XCTAssertEqual(multi.count, 3333)
        // The loop content must actually be written, not left as the pre-allocated zeros.
        XCTAssertGreaterThan(multi.map { abs($0) }.max()!, 0.01)
        XCTAssertEqual(Crossfade.assembleLoopedMiddle(loop: loop, targetLen: 400, crossfadeLen: 200).count, 400)
    }
}

final class EnvelopeTests: XCTestCase {
    func testEndpointsAreZero() {
        for type in BreathType.allCases {
            let curve = Envelope.curve(for: type, frames: 44_100, durationSec: 4)
            XCTAssertEqual(curve.first!, 0, accuracy: 1e-7)
            XCTAssertEqual(curve.last!, 0, accuracy: 1e-7)
        }
    }

    func testLength() {
        XCTAssertEqual(Envelope.curve(for: .inhale, frames: 12_345, durationSec: 3).count, 12_345)
    }

    func testLongBreathIsQuieter() {
        XCTAssertEqual(Envelope.longBreathGainScale(durationSec: 4), 1, accuracy: 1e-6)
        XCTAssertLessThan(Envelope.longBreathGainScale(durationSec: 30),
                          Envelope.longBreathGainScale(durationSec: 4))
    }

    func testInhaleRisesEarlyExhaleDecaysLate() {
        let inhale = Envelope.curve(for: .inhale, frames: 1000, durationSec: 4)
        let exhale = Envelope.curve(for: .exhale, frames: 1000, durationSec: 4)
        // Inhale energy is concentrated later than exhale (which peaks early).
        XCTAssertLessThan(inhale[100], inhale[500])
        XCTAssertGreaterThan(exhale[100], exhale[700])
    }

    func testPeakRegions() {
        // Inhale peaks in the later-middle; exhale peaks early. argmax survives only
        // if the curves broadly match their design intent.
        let inhale = Envelope.curve(for: .inhale, frames: 1000, durationSec: 4)
        let exhale = Envelope.curve(for: .exhale, frames: 1000, durationSec: 4)
        let iPeak = inhale.indices.max(by: { inhale[$0] < inhale[$1] })!
        let ePeak = exhale.indices.max(by: { exhale[$0] < exhale[$1] })!
        XCTAssertTrue((300...800).contains(iPeak), "inhale peak at \(iPeak)")
        XCTAssertTrue((50...450).contains(ePeak), "exhale peak at \(ePeak)")
    }
}

final class VariationTests: XCTestCase {
    func testDbToGain() {
        XCTAssertEqual(Variation.dbToGain(0), 1, accuracy: 1e-9)
        XCTAssertEqual(Variation.dbToGain(-6), 0.501, accuracy: 1e-3)
    }

    func testSeededRNGDeterministic() {
        var a = SeededRNG(seed: 42)
        var b = SeededRNG(seed: 42)
        for _ in 0..<100 { XCTAssertEqual(a.next(), b.next()) }
        var d = SeededRNG(seed: 42)
        var e = SeededRNG(seed: 43)
        XCTAssertNotEqual(d.next(), e.next())
    }

    func testDrawWithinRangeAndDeterministic() {
        let opts = VariationOptions(enabled: true, gainDb: 2, playbackRatePct: 2)
        var r1 = SeededRNG(seed: 7)
        var r2 = SeededRNG(seed: 7)
        let d1 = Variation.draw(opts, rng: &r1)
        let d2 = Variation.draw(opts, rng: &r2)
        XCTAssertEqual(d1, d2)
        XCTAssertGreaterThanOrEqual(d1.gainScalar, Variation.dbToGain(-2))
        XCTAssertLessThanOrEqual(d1.gainScalar, Variation.dbToGain(2))
        XCTAssertGreaterThanOrEqual(d1.playbackRate, 0.98)
        XCTAssertLessThanOrEqual(d1.playbackRate, 1.02)
    }

    func testStableSeedDependsOnSpec() {
        let a = BreathSpec(type: .inhale, durationSec: 4, style: "neutral")
        let b = BreathSpec(type: .inhale, durationSec: 4, style: "neutral")
        let c = BreathSpec(type: .inhale, durationSec: 8, style: "neutral")
        XCTAssertEqual(Variation.stableSeed(for: a), Variation.stableSeed(for: b))
        XCTAssertNotEqual(Variation.stableSeed(for: a), Variation.stableSeed(for: c))
    }

    func testStableSeedUsesClampedDuration() {
        // 0.1s and 1.0s both clamp to the 1.0s floor, so the seed is identical.
        let belowFloor = BreathSpec(type: .inhale, durationSec: 0.1, style: "neutral")
        let atFloor = BreathSpec(type: .inhale, durationSec: 1.0, style: "neutral")
        XCTAssertEqual(Variation.stableSeed(for: belowFloor), Variation.stableSeed(for: atFloor))
    }
}

final class ResampleTests: XCTestCase {
    func testTargetLengthAndEndpoints() {
        let input = (0..<100).map { Float($0) }
        let out = Resample.toFrames(input, 250)
        XCTAssertEqual(out.count, 250)
        XCTAssertEqual(out.first!, input.first!, accuracy: 1e-6)
        XCTAssertEqual(out.last!, input.last!, accuracy: 1e-6)
    }

    func testByFactor() {
        let input = [Float](repeating: 0.5, count: 1000)
        XCTAssertEqual(Resample.byFactor(input, 1.02).count, 1020)  // lengthen
        XCTAssertEqual(Resample.byFactor(input, 0.98).count, 980)   // shorten (pitch up)
    }
}

final class BiquadTests: XCTestCase {
    func testHighpassReducesDC() {
        var samples = [Float](repeating: 1, count: 4_096)
        var filter = Biquad(kind: .highpass, sampleRate: 44_100, frequency: 300, q: 0.7)
        filter.process(&samples)
        let tailMean = samples.suffix(1_000).reduce(Float(0), +) / 1_000
        XCTAssertLessThan(abs(tailMean), 0.01)
    }

    func testLowpassReducesFastAlternatingSignal() {
        let input = (0..<4_096).map { Float($0.isMultiple(of: 2) ? 1 : -1) }
        var filtered = input
        var filter = Biquad(kind: .lowpass, sampleRate: 44_100, frequency: 300, q: 0.7)
        filter.process(&filtered)
        XCTAssertLessThan(rms(filtered), rms(input) * 0.25)
    }
}

final class ProceduralBreathSynthTests: XCTestCase {
    func testExactLengthFiniteNonSilentAndZeroEndpointsForAllProceduralGenerators() throws {
        for generator in ProceduralGeneratorKind.allCases {
            for type in BreathType.allCases {
                for duration in [1.0, 4.0, 12.0] {
                    let spec = BreathSpec(
                        type: type,
                        durationSec: duration,
                        style: "calm",
                        seed: 123,
                        variation: .none
                    )
                    let out = try ProceduralBreathSynth.render(
                        spec: spec,
                        config: ProceduralBreathConfig(generator: generator)
                    )
                    XCTAssertEqual(out.count, Int((duration * AudioConstants.workingSampleRate).rounded()))
                    XCTAssertEqual(out.first!, 0, accuracy: 1e-7)
                    XCTAssertEqual(out.last!, 0, accuracy: 1e-7)
                    XCTAssertTrue(out.allSatisfy(\.isFinite))
                    XCTAssertGreaterThan(out.map { abs($0) }.max()!, 0.001)
                    XCTAssertLessThanOrEqual(out.map { abs($0) }.max()!, 1.0)
                }
            }
        }
    }

    func testDefaultGeneratorHandlesLongBreath() throws {
        let duration = 30.0
        let out = try ProceduralBreathSynth.render(
            spec: BreathSpec(type: .exhale, durationSec: duration, style: "calm", seed: 123, variation: .none)
        )
        XCTAssertEqual(out.count, Int((duration * AudioConstants.workingSampleRate).rounded()))
        XCTAssertEqual(out.first!, 0, accuracy: 1e-7)
        XCTAssertEqual(out.last!, 0, accuracy: 1e-7)
        XCTAssertTrue(out.allSatisfy(\.isFinite))
        XCTAssertGreaterThan(out.map { abs($0) }.max()!, 0.001)
        XCTAssertLessThanOrEqual(out.map { abs($0) }.max()!, 1.0)
    }

    func testDeterministicForSameSeedAndDifferentAcrossSeeds() throws {
        let a = try ProceduralBreathSynth.render(spec: BreathSpec(type: .inhale, durationSec: 4, style: "calm", seed: 1))
        let b = try ProceduralBreathSynth.render(spec: BreathSpec(type: .inhale, durationSec: 4, style: "calm", seed: 1))
        let c = try ProceduralBreathSynth.render(spec: BreathSpec(type: .inhale, durationSec: 4, style: "calm", seed: 2))
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    func testShootoutGeneratorsProduceDifferentSignals() throws {
        let spec = BreathSpec(type: .exhale, durationSec: 6, style: "calm", seed: 7, variation: .none)
        let tract = try ProceduralBreathSynth.render(spec: spec, config: ProceduralBreathConfig(generator: .tract))
        let klatt = try ProceduralBreathSynth.render(spec: spec, config: ProceduralBreathConfig(generator: .klatt))
        let granular = try ProceduralBreathSynth.render(spec: spec, config: ProceduralBreathConfig(generator: .granular))
        XCTAssertGreaterThan(meanAbsoluteDifference(tract, klatt), 0.001)
        XCTAssertGreaterThan(meanAbsoluteDifference(tract, granular), 0.001)
        XCTAssertGreaterThan(meanAbsoluteDifference(klatt, granular), 0.001)
    }

    func testLegacyCalmStyleIsSofterThanNeutral() throws {
        let config = ProceduralBreathConfig(generator: .legacy)
        let neutral = try ProceduralBreathSynth.render(
            spec: BreathSpec(type: .exhale, durationSec: 6, style: "neutral", seed: 7, variation: .none),
            config: config
        )
        let calm = try ProceduralBreathSynth.render(
            spec: BreathSpec(type: .exhale, durationSec: 6, style: "calm", seed: 7, variation: .none),
            config: config
        )
        XCTAssertLessThan(rms(calm), rms(neutral))
        XCTAssertLessThan(highFrequencyEnergy(calm), highFrequencyEnergy(neutral))
    }

    func testUnsupportedProceduralStyleThrows() {
        let spec = BreathSpec(type: .inhale, durationSec: 4, style: "unknown", seed: 1)
        XCTAssertThrowsError(try ProceduralBreathSynth.render(spec: spec)) { error in
            XCTAssertEqual(error as? BreathError, .unsupportedProceduralStyle("unknown"))
        }
    }

    @MainActor
    func testEngineDefaultRendersWithoutAssets() throws {
        let engine = try BreathEngine(config: BreathEngine.Config())
        let out = try engine.renderSamples(BreathSpec(type: .inhale, durationSec: 2, style: "calm", seed: 5))
        XCTAssertEqual(out.count, Int((2 * AudioConstants.workingSampleRate).rounded()))
        XCTAssertGreaterThan(out.map { abs($0) }.max()!, 0.001)
    }

    @MainActor
    func testEngineRendersEachShootoutGenerator() throws {
        for generator in [ProceduralGeneratorKind.tract, .klatt, .granular] {
            let engine = try BreathEngine(config: BreathEngine.Config(
                source: .procedural(ProceduralBreathConfig(generator: generator))
            ))
            let out = try engine.renderSamples(BreathSpec(type: .inhale, durationSec: 2, style: "calm", seed: 5))
            XCTAssertEqual(out.count, Int((2 * AudioConstants.workingSampleRate).rounded()))
            XCTAssertGreaterThan(out.map { abs($0) }.max()!, 0.001)
        }
    }
}

final class ManifestTests: XCTestCase {
    func testCodableRoundTrip() throws {
        var manifest = BreathManifest()
        var style = StyleManifest()
        style.inhale.loop = [BreathAsset(file: "a.wav", durationSec: 4, sampleRate: 44_100, channels: 1)]
        manifest.styles["neutral"] = style
        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(BreathManifest.self, from: data)
        XCTAssertEqual(decoded, manifest)
        XCTAssertEqual(decoded.palette(style: "neutral", type: .inhale)?.loop.first?.file, "a.wav")
    }
}

private func rms(_ samples: [Float]) -> Float {
    guard !samples.isEmpty else { return 0 }
    let sum = samples.reduce(Float(0)) { $0 + $1 * $1 }
    return sqrt(sum / Float(samples.count))
}

private func highFrequencyEnergy(_ samples: [Float]) -> Float {
    guard samples.count > 1 else { return 0 }
    var sum: Float = 0
    for i in 1..<samples.count {
        sum += abs(samples[i] - samples[i - 1])
    }
    return sum / Float(samples.count - 1)
}

private func meanAbsoluteDifference(_ a: [Float], _ b: [Float]) -> Float {
    let count = min(a.count, b.count)
    guard count > 0 else { return 0 }
    var sum: Float = 0
    for i in 0..<count {
        sum += abs(a[i] - b[i])
    }
    return sum / Float(count)
}

final class AssemblerTests: XCTestCase {
    private func clips(sampleRate sr: Double) -> BreathSourceClips {
        BreathSourceClips(
            start: [Float](repeating: 0.5, count: Int(0.8 * sr)),
            loop: (0..<Int(4 * sr)).map { 0.5 * sin(Float($0) * 0.02) },
            end: [Float](repeating: 0.5, count: Int(1.0 * sr)),
            oneShot: [Float](repeating: 0.5, count: Int(1.2 * sr))
        )
    }

    func testNormalBranchExactLengthAndZeroEndpoints() {
        let settings = AssemblerSettings()
        let sr = settings.sampleRate
        let dur = 8.0
        let out = BreathAssembler.assemble(
            type: .inhale, durationSec: dur, clips: clips(sampleRate: sr), settings: settings
        )
        XCTAssertEqual(out.count, Int((dur * sr).rounded()))
        XCTAssertEqual(out.first!, 0, accuracy: 1e-6)
        XCTAssertEqual(out.last!, 0, accuracy: 1e-6)
        XCTAssertLessThanOrEqual(out.map { abs($0) }.max()!, 1.0)
        // Guard against a silent-but-correct-length regression.
        XCTAssertGreaterThan(out.map { abs($0) }.max()!, 0.01)
    }

    func testShortBranchExactLength() {
        let settings = AssemblerSettings()
        let sr = settings.sampleRate
        let dur = 1.0
        let out = BreathAssembler.assemble(
            type: .exhale, durationSec: dur, clips: clips(sampleRate: sr), settings: settings
        )
        XCTAssertEqual(out.count, Int((dur * sr).rounded()))
        XCTAssertEqual(out.first!, 0, accuracy: 1e-6)
        XCTAssertEqual(out.last!, 0, accuracy: 1e-6)
        XCTAssertGreaterThan(out.map { abs($0) }.max()!, 0.01)
    }

    func testShortNormalBoundaryAt1Point5s() {
        // Exactly 1.5s routes to the normal branch (strict `<` threshold).
        let settings = AssemblerSettings()
        let sr = settings.sampleRate
        let dur = 1.5
        let out = BreathAssembler.assemble(
            type: .inhale, durationSec: dur, clips: clips(sampleRate: sr), settings: settings
        )
        XCTAssertEqual(out.count, Int((dur * sr).rounded()))
        XCTAssertEqual(out.first!, 0, accuracy: 1e-6)
        XCTAssertEqual(out.last!, 0, accuracy: 1e-6)
        XCTAssertGreaterThan(out.map { abs($0) }.max()!, 0.01)
    }

    func testLongBreathExactLength() {
        let settings = AssemblerSettings()
        let sr = settings.sampleRate
        let dur = 30.0
        let out = BreathAssembler.assemble(
            type: .exhale, durationSec: dur, clips: clips(sampleRate: sr), settings: settings
        )
        XCTAssertEqual(out.count, Int((dur * sr).rounded()))
        XCTAssertGreaterThan(out.map { abs($0) }.max()!, 0.01)
    }

    func testSustainOnlyExactLengthAndZeroEndpoints() {
        let settings = AssemblerSettings(assemblyMode: .sustainOnly)
        let sr = settings.sampleRate
        let dur = 8.0
        let out = BreathAssembler.assemble(
            type: .exhale, durationSec: dur, clips: clips(sampleRate: sr), settings: settings
        )
        XCTAssertEqual(out.count, Int((dur * sr).rounded()))
        XCTAssertEqual(out.first!, 0, accuracy: 1e-6)
        XCTAssertEqual(out.last!, 0, accuracy: 1e-6)
        XCTAssertGreaterThan(out.map { abs($0) }.max()!, 0.01)
    }

    func testSustainOnlyIgnoresStartAndEndClips() {
        let settings = AssemblerSettings(assemblyMode: .sustainOnly)
        let sr = settings.sampleRate
        let loop = (0..<Int(2 * sr)).map { 0.25 * sin(Float($0) * 0.01) }
        let clips = BreathSourceClips(
            start: [Float](repeating: 50, count: Int(0.8 * sr)),
            loop: loop,
            end: [Float](repeating: -50, count: Int(0.8 * sr)),
            oneShot: [Float](repeating: 50, count: Int(1.2 * sr))
        )
        let out = BreathAssembler.assemble(
            type: .inhale, durationSec: 4, clips: clips, settings: settings
        )
        XCTAssertLessThan(out.map { abs($0) }.max()!, 0.4)
    }

    func testSustainLoopWindowRejectsQuietTail() {
        let sr = 1_000.0
        let loud = (0..<2_000).map { 0.6 * sin(Float($0) * 0.05) }
        let quiet = (0..<3_000).map { 0.03 * sin(Float($0) * 0.05) }
        let loop = loud + quiet

        let window = BreathAssembler.sustainLoopWindow(for: .inhale, loop: loop, sampleRate: sr)

        XCTAssertLessThan(window.count, loop.count)
        XCTAssertGreaterThan(rms(window), 0.25)
    }

    func testInhaleSustainTexturePingPongsTheSelectedWindow() {
        let sr = 1_000.0
        let loud = (0..<2_500).map { 0.6 * sin(Float($0) * 0.05) }
        let quiet = (0..<2_500).map { 0.03 * sin(Float($0) * 0.05) }
        let loop = loud + quiet

        let window = BreathAssembler.sustainLoopWindow(for: .inhale, loop: loop, sampleRate: sr)
        let texture = BreathAssembler.sustainLoopTexture(for: .inhale, loop: loop, sampleRate: sr)
        let exhaleTexture = BreathAssembler.sustainLoopTexture(for: .exhale, loop: loop, sampleRate: sr)

        XCTAssertEqual(texture.count, window.count * 2)
        XCTAssertEqual(texture.first!, window.first!)
        XCTAssertEqual(texture.last!, window.first!)
        XCTAssertLessThan(exhaleTexture.count, texture.count)
    }

    func testSustainOnlyDoesNotFollowSourceDropout() {
        let sr = 1_000.0
        let settings = AssemblerSettings(sampleRate: sr, assemblyMode: .sustainOnly, crossfadeSec: 0.1)
        let loud = (0..<2_000).map { 0.6 * sin(Float($0) * 0.05) }
        let quiet = (0..<3_000).map { 0.03 * sin(Float($0) * 0.05) }
        let clips = BreathSourceClips(start: [], loop: loud + quiet, end: [], oneShot: nil)

        let out = BreathAssembler.assemble(type: .inhale, durationSec: 6, clips: clips, settings: settings)
        let early = rms(Array(out[2_000..<2_500]))
        let mid = rms(Array(out[3_000..<3_500]))

        XCTAssertGreaterThan(mid, early * 0.55)
    }

    func testRecordedShapeModeRendersExactLengthFromFullBreath() {
        let sr = 1_000.0
        let settings = AssemblerSettings(sampleRate: sr, assemblyMode: .recordedShape, crossfadeSec: 0.1)
        let full = shapedBreathFrames(sampleRate: sr, seconds: 10)
        let clips = BreathSourceClips(start: [], loop: [], end: [], oneShot: full)

        let out = BreathAssembler.assemble(type: .inhale, durationSec: 8, clips: clips, settings: settings)

        XCTAssertEqual(out.count, 8_000)
        XCTAssertEqual(out.first!, 0, accuracy: 1e-6)
        XCTAssertEqual(out.last!, 0, accuracy: 1e-6)
        XCTAssertGreaterThan(rms(out), 0.02)
    }

    func testRecordedShapeModeCompressesEnvelopeForShortBreath() {
        let sr = 1_000.0
        let settings = AssemblerSettings(sampleRate: sr, assemblyMode: .recordedShape, crossfadeSec: 0.1)
        let full = shapedBreathFrames(sampleRate: sr, seconds: 10)
        let clips = BreathSourceClips(start: [], loop: [], end: [], oneShot: full)

        let out = BreathAssembler.assemble(type: .inhale, durationSec: 4, clips: clips, settings: settings)
        let early = rms(Array(out[0..<500]))
        let middle = rms(Array(out[1_500..<2_500]))
        let tail = rms(Array(out[3_500..<4_000]))

        XCTAssertEqual(out.count, 4_000)
        XCTAssertLessThan(early, middle * 0.65)
        XCTAssertLessThan(tail, middle * 0.65)
        XCTAssertGreaterThan(middle, 0.02)
    }

    func testRecordedShapeModeSmoothsAttackAndReleaseWobbles() {
        let sr = 1_000.0
        let settings = AssemblerSettings(sampleRate: sr, assemblyMode: .recordedShape, crossfadeSec: 0.1)
        let full = wobblyShapedBreathFrames(sampleRate: sr, seconds: 10)
        let clips = BreathSourceClips(start: [], loop: [], end: [], oneShot: full)

        let out = BreathAssembler.assemble(type: .inhale, durationSec: 4, clips: clips, settings: settings)
        let envelope = chunkRMS(out, chunkSize: 250)
        let peakIndex = envelope.indices.max(by: { envelope[$0] < envelope[$1] })!
        let attack = Array(envelope[0...peakIndex])
        let release = Array(envelope[peakIndex..<envelope.count])

        XCTAssertTrue(isMostlyNondecreasing(attack, tolerance: 0.003), "attack RMS: \(attack)")
        XCTAssertTrue(isMostlyNonincreasing(release, tolerance: 0.003), "release RMS: \(release)")
    }

    func testRecordedShapeNearLengthModeSmoothsDirectFadeWobbles() {
        let sr = 1_000.0
        let settings = AssemblerSettings(sampleRate: sr, assemblyMode: .recordedShape, crossfadeSec: 0.1)
        let full = wobblyShapedBreathFrames(sampleRate: sr, seconds: 10)
        let clips = BreathSourceClips(start: [], loop: [], end: [], oneShot: full)

        let out = BreathAssembler.assemble(type: .exhale, durationSec: 8, clips: clips, settings: settings)
        let envelope = chunkRMS(out, chunkSize: 250)
        let peakIndex = envelope.indices.max(by: { envelope[$0] < envelope[$1] })!
        let attack = Array(envelope[0...peakIndex])
        let release = Array(envelope[peakIndex..<envelope.count])

        XCTAssertTrue(isMostlyNondecreasing(attack, tolerance: 0.003), "attack RMS: \(attack)")
        XCTAssertTrue(isMostlyNonincreasing(release, tolerance: 0.003), "release RMS: \(release)")
    }
}

private func shapedBreathFrames(sampleRate: Double, seconds: Double) -> [Float] {
    let count = Int((sampleRate * seconds).rounded())
    return (0..<count).map { i in
        let t = Double(i) / Double(max(1, count - 1))
        let envelope: Double
        if t < 0.25 {
            envelope = t / 0.25
        } else if t > 0.72 {
            envelope = max(0, (1 - t) / 0.28)
        } else {
            envelope = 1
        }
        let carrier = sin(2 * Double.pi * 220 * Double(i) / sampleRate)
        return Float(0.35 * envelope * carrier)
    }
}

private func wobblyShapedBreathFrames(sampleRate: Double, seconds: Double) -> [Float] {
    let count = Int((sampleRate * seconds).rounded())
    return (0..<count).map { i in
        let t = Double(i) / Double(max(1, count - 1))
        let base: Double
        if t < 0.25 {
            base = t / 0.25
        } else if t > 0.72 {
            base = max(0, (1 - t) / 0.28)
        } else {
            base = 1
        }
        let wobble = 1 + 0.18 * sin(2 * Double.pi * 16 * t)
        let carrier = sin(2 * Double.pi * 220 * Double(i) / sampleRate)
        return Float(0.35 * base * wobble * carrier)
    }
}

private func chunkRMS(_ samples: [Float], chunkSize: Int) -> [Float] {
    stride(from: 0, to: samples.count, by: chunkSize).map { start in
        let end = min(samples.count, start + chunkSize)
        return rms(Array(samples[start..<end]))
    }
}

private func isMostlyNondecreasing(_ values: [Float], tolerance: Float) -> Bool {
    guard values.count > 1 else { return true }
    for i in 1..<values.count where values[i] + tolerance < values[i - 1] {
        return false
    }
    return true
}

private func isMostlyNonincreasing(_ values: [Float], tolerance: Float) -> Bool {
    guard values.count > 1 else { return true }
    for i in 1..<values.count where values[i] > values[i - 1] + tolerance {
        return false
    }
    return true
}
