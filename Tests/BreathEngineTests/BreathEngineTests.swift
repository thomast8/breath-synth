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
        // 0.1s and 1.0s both clamp to the 1.0s floor → identical seed.
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
}
