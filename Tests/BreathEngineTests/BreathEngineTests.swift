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

    func testAssembleTexturedLoopExactLengthAndWindow() {
        let texture = (0..<1000).map { sin(Float($0) * 0.01) }
        var rng = SeededRNG(seed: 7)
        let body = Crossfade.assembleTexturedLoop(texture: texture, targetLen: 3333, grainLen: 400, crossfadeLen: 100, rng: &rng)
        XCTAssertEqual(body.count, 3333)
        XCTAssertGreaterThan(body.map { abs($0) }.max()!, 0.01)
        // Deterministic: the same seed reproduces the same output.
        var rngA = SeededRNG(seed: 7)
        var rngB = SeededRNG(seed: 7)
        let a = Crossfade.assembleTexturedLoop(texture: texture, targetLen: 3333, grainLen: 400, crossfadeLen: 100, rng: &rngA)
        let b = Crossfade.assembleTexturedLoop(texture: texture, targetLen: 3333, grainLen: 400, crossfadeLen: 100, rng: &rngB)
        XCTAssertEqual(a, b)
        // When the target fits the texture, a single seam-free window is returned.
        var rngW = SeededRNG(seed: 1)
        let window = Crossfade.assembleTexturedLoop(texture: texture, targetLen: 400, grainLen: 400, crossfadeLen: 100, rng: &rngW)
        XCTAssertEqual(window, Array(texture[0..<400]))
    }

    func testAssembleTexturedLoopPullsFromMultipleOffsets() {
        // Ramp texture: each sample's value encodes its own offset. Probing the clean
        // (non-crossfade) region of successive grains therefore reveals which offset
        // each grain came from. Whole-texture looping would replay offset 0 every time;
        // random offset-hopping must source grains from several distinct offsets.
        let n = 4000
        let texture = (0..<n).map { Float($0) / Float(n - 1) }
        let grain = 1000, x = 200, stride = 800
        var rng = SeededRNG(seed: 3)
        let body = Crossfade.assembleTexturedLoop(texture: texture, targetLen: 8000, grainLen: grain, crossfadeLen: x, rng: &rng)
        var offsetsSeen = Set<Int>()
        for k in 0..<6 {
            let probe = k * stride + x + 10  // just past this grain's head-crossfade
            if probe < body.count { offsetsSeen.insert(Int((body[probe] * 1000).rounded())) }
        }
        XCTAssertGreaterThan(offsetsSeen.count, 1, "grains should be pulled from multiple offsets")
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

final class AssemblerTests: XCTestCase {
    private func clips(sampleRate sr: Double) -> BreathSourceClips {
        BreathSourceClips(
            start: [Float](repeating: 0.5, count: Int(0.8 * sr)),
            loop: (0..<Int(4 * sr)).map { 0.5 * sin(Float($0) * 0.02) },
            end: [Float](repeating: 0.5, count: Int(1.0 * sr)),
            oneShot: [Float](repeating: 0.5, count: Int(1.2 * sr))
        )
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

    func testRecordedShapeModeRendersExactLengthFromFullBreath() {
        let sr = 1_000.0
        let settings = AssemblerSettings(sampleRate: sr, crossfadeSec: 0.1)
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
        let settings = AssemblerSettings(sampleRate: sr, crossfadeSec: 0.1)
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
        let settings = AssemblerSettings(sampleRate: sr, crossfadeSec: 0.1)
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
        let settings = AssemblerSettings(sampleRate: sr, crossfadeSec: 0.1)
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

    func testRecordedShapeInhaleOnsetIsPromptWithNoInteriorDip() {
        // The designed envelope gives every duration the same prompt onset: a long
        // inhale must become audible within the attack window (no multi-second
        // near-silent lead-in), and the climb to the peak must not dip (guards the
        // old recording-derived double-attack/notch regression).
        let sr = 1_000.0
        let settings = AssemblerSettings(sampleRate: sr, crossfadeSec: 0.1)
        let full = shapedBreathFrames(sampleRate: sr, seconds: 10)
        let clips = BreathSourceClips(start: [], loop: [], end: [], oneShot: full)

        let out = BreathAssembler.assemble(type: .inhale, durationSec: 12, clips: clips, settings: settings)
        XCTAssertEqual(out.count, 12_000)

        // 0.1 s RMS chunks: chunk index == tenths of a second.
        let envelope = chunkRMS(out, chunkSize: 100)
        let peak = envelope.max()!
        XCTAssertGreaterThan(peak, 0.02)

        // RMS crosses 25% of peak well within the first 0.5 s (chunk 5).
        let crossing = envelope.firstIndex(where: { $0 >= 0.25 * peak })!
        XCTAssertLessThan(crossing, 5, "onset crossing chunk \(crossing)")

        // No structural interior notch on the way up to the peak (guards the old
        // double-attack regression, a ~50% drawdown). The granular texture body has a
        // few percent of natural ripple, so we bound the worst drawdown from the
        // running maximum rather than every adjacent step.
        let peakIndex = envelope.indices.max(by: { envelope[$0] < envelope[$1] })!
        var running = envelope[0]
        var worstDrawdown: Float = 0
        for i in 0...peakIndex {
            running = max(running, envelope[i])
            worstDrawdown = max(worstDrawdown, (running - envelope[i]) / peak)
        }
        XCTAssertLessThan(worstDrawdown, 0.15, "interior drawdown \(worstDrawdown) - attack RMS: \(envelope[0...peakIndex])")
    }

    func testRecordedShapeRemovesLowFrequencyRumble() {
        // A synthetic "recording": a breath-shaped mid-band texture (600/1100/1900 Hz)
        // plus a strong 50 Hz room rumble. The recordedShape path's high-pass stages
        // must strip the sub-band before delivery, so the rendered output should carry
        // far less sub-120 Hz energy than its 300-3000 Hz mid-band energy.
        let sr = 16_000.0
        let settings = AssemblerSettings(sampleRate: sr, crossfadeSec: 0.1)
        let full = rumblyBreathFrames(sampleRate: sr, seconds: 10)
        let clips = BreathSourceClips(start: [], loop: [], end: [], oneShot: full)

        let out = BreathAssembler.assemble(type: .inhale, durationSec: 6, clips: clips, settings: settings)

        // Probe band energy on a central 1.0 s window where the breath plateaus.
        // With exactly `sr` samples, integer-Hz probes land on DFT bin centres, so
        // the naive single-bin Goertzel below stays numerically stable and free of
        // spectral leakage.
        let windowLen = Int(sr)
        let windowStart = max(0, out.count / 2 - windowLen / 2)
        let window = Array(out[windowStart..<min(out.count, windowStart + windowLen)])

        let lowProbes: [Double] = [40, 50, 60, 100]
        let midProbes: [Double] = [600, 1_100, 1_900]
        let lowEnergy = lowProbes.map { goertzelMagnitude(window, sampleRate: sr, frequency: $0) }.reduce(0, +) / Double(lowProbes.count)
        let midEnergy = midProbes.map { goertzelMagnitude(window, sampleRate: sr, frequency: $0) }.reduce(0, +) / Double(midProbes.count)

        XCTAssertGreaterThan(midEnergy, 0, "mid-band energy should be present")
        XCTAssertLessThan(lowEnergy / midEnergy, 0.5, "sub-120 Hz energy \(lowEnergy) vs mid \(midEnergy)")
    }
}

/// Deterministic breath-shaped mid-band texture with a strong 50 Hz rumble added
/// on top, used to verify the recordedShape path's low-cut filtering.
private func rumblyBreathFrames(sampleRate: Double, seconds: Double) -> [Float] {
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
        let phase = Double(i) / sampleRate
        // Mid-band "breath" texture: a few partials between ~500 and ~2000 Hz.
        let breath = sin(2 * Double.pi * 600 * phase)
            + 0.8 * sin(2 * Double.pi * 1_100 * phase)
            + 0.6 * sin(2 * Double.pi * 1_900 * phase)
        // Strong low-frequency room rumble.
        let rumble = 1.2 * sin(2 * Double.pi * 50 * phase)
        return Float(envelope * (0.18 * breath + rumble))
    }
}

/// Naive single-bin Goertzel magnitude at `frequency`, used to probe band energy
/// without a full FFT dependency.
private func goertzelMagnitude(_ samples: [Float], sampleRate: Double, frequency: Double) -> Double {
    guard samples.count > 1 else { return 0 }
    let omega = 2 * Double.pi * frequency / sampleRate
    let coeff = 2 * cos(omega)
    var s0 = 0.0
    var s1 = 0.0
    var s2 = 0.0
    for sample in samples {
        s0 = Double(sample) + coeff * s1 - s2
        s2 = s1
        s1 = s0
    }
    let power = s1 * s1 + s2 * s2 - coeff * s1 * s2
    return sqrt(max(0, power)) / Double(samples.count)
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
