import Testing
import Foundation
@testable import BreathEngine

struct SegmentsTests {
    @Test
    func testFramesRounding() {
        #expect(Segments.frames(seconds: 1, sampleRate: 44_100) == 44_100)
        #expect(Segments.frames(seconds: 0.5, sampleRate: 44_100) == 22_050)
        #expect(Segments.frames(seconds: 0, sampleRate: 44_100) == 0)
    }

    @Test
    func testClampCrossfade() {
        #expect(Segments.clampCrossfade(1000, loopLen: 500, startLen: 800, endLen: 800) == 499)
        #expect(Segments.clampCrossfade(100, loopLen: 500, startLen: 800, endLen: 800) == 100)
        #expect(Segments.clampCrossfade(0, loopLen: 500, startLen: 800, endLen: 800) == 1)
    }
}

struct CrossfadeTests {
    @Test
    func testFadeEndpoints() {
        let n = 256
        let fIn = Crossfade.fadeIn(n)
        let fOut = Crossfade.fadeOut(n)
        #expect(abs(fIn.first! - 0) <= 1e-6)
        #expect(abs(fIn.last! - 1) <= 1e-6)
        #expect(abs(fOut.first! - 1) <= 1e-6)
        #expect(abs(fOut.last! - 0) <= 1e-6)
    }

    @Test
    func testEqualPowerInvariant() {
        let n = 512
        let fIn = Crossfade.fadeIn(n)
        let fOut = Crossfade.fadeOut(n)
        for i in 0..<n {
            #expect(abs(fIn[i] * fIn[i] + fOut[i] * fOut[i] - 1) <= 1e-5)
        }
    }

    @Test
    func testPlaceNoLoudnessDipForCorrelatedSignals() {
        // Mixing two DC-1 signals across an equal-power crossfade never dips below 1.
        let n = 300
        var out = [Float](repeating: 1, count: n)
        let segment = [Float](repeating: 1, count: n)
        Crossfade.place(into: &out, segment: segment, at: 0, headCrossfade: n)
        for value in out {
            #expect(value >= 1 - 1e-4)
        }
    }

    @Test
    func testAssembleTexturedLoopExactLengthAndWindow() {
        let texture = (0..<1000).map { sin(Float($0) * 0.01) }
        var rng = SeededRNG(seed: 7)
        let body = Crossfade.assembleTexturedLoop(texture: texture, targetLen: 3333, grainLen: 400, crossfadeLen: 100, rng: &rng)
        #expect(body.count == 3333)
        #expect(body.map { abs($0) }.max()! > 0.01)
        // Deterministic: the same seed reproduces the same output.
        var rngA = SeededRNG(seed: 7)
        var rngB = SeededRNG(seed: 7)
        let a = Crossfade.assembleTexturedLoop(texture: texture, targetLen: 3333, grainLen: 400, crossfadeLen: 100, rng: &rngA)
        let b = Crossfade.assembleTexturedLoop(texture: texture, targetLen: 3333, grainLen: 400, crossfadeLen: 100, rng: &rngB)
        #expect(a == b)
        // When the target fits the texture, a single seam-free window is returned.
        var rngW = SeededRNG(seed: 1)
        let window = Crossfade.assembleTexturedLoop(texture: texture, targetLen: 400, grainLen: 400, crossfadeLen: 100, rng: &rngW)
        #expect(window == Array(texture[0..<400]))
    }

    @Test
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
        #expect(offsetsSeen.count > 1, "grains should be pulled from multiple offsets")
    }
}

struct EnvelopeTests {
    @Test
    func testEndpointsAreZero() {
        for type in BreathType.allCases {
            let curve = Envelope.curve(for: type, frames: 44_100, durationSec: 4)
            #expect(abs(curve.first! - 0) <= 1e-7)
            #expect(abs(curve.last! - 0) <= 1e-7)
        }
    }

    @Test
    func testLength() {
        #expect(Envelope.curve(for: .inhale, frames: 12_345, durationSec: 3).count == 12_345)
    }

    @Test
    func testLongBreathIsQuieter() {
        #expect(abs(Envelope.longBreathGainScale(durationSec: 4) - 1) <= 1e-6)
        #expect(Envelope.longBreathGainScale(durationSec: 30) <
                          Envelope.longBreathGainScale(durationSec: 4))
    }

    @Test
    func testInhaleRisesEarlyExhaleDecaysLate() {
        let inhale = Envelope.curve(for: .inhale, frames: 1000, durationSec: 4)
        let exhale = Envelope.curve(for: .exhale, frames: 1000, durationSec: 4)
        // Inhale energy is concentrated later than exhale (which peaks early).
        #expect(inhale[100] < inhale[500])
        #expect(exhale[100] > exhale[700])
    }

    @Test
    func testPeakRegions() {
        // Inhale peaks in the later-middle; exhale peaks early. argmax survives only
        // if the curves broadly match their design intent.
        let inhale = Envelope.curve(for: .inhale, frames: 1000, durationSec: 4)
        let exhale = Envelope.curve(for: .exhale, frames: 1000, durationSec: 4)
        let iPeak = inhale.indices.max(by: { inhale[$0] < inhale[$1] })!
        let ePeak = exhale.indices.max(by: { exhale[$0] < exhale[$1] })!
        #expect((300...800).contains(iPeak), "inhale peak at \(iPeak)")
        #expect((50...450).contains(ePeak), "exhale peak at \(ePeak)")
    }
}

struct VariationTests {
    @Test
    func testDbToGain() {
        #expect(abs(Variation.dbToGain(0) - 1) <= 1e-9)
        #expect(abs(Variation.dbToGain(-6) - 0.501) <= 1e-3)
    }

    @Test
    func testSeededRNGDeterministic() {
        var a = SeededRNG(seed: 42)
        var b = SeededRNG(seed: 42)
        for _ in 0..<100 { #expect(a.next() == b.next()) }
        var d = SeededRNG(seed: 42)
        var e = SeededRNG(seed: 43)
        #expect(d.next() != e.next())
    }

    @Test
    func testDrawWithinRangeAndDeterministic() {
        let opts = VariationOptions(enabled: true, gainDb: 2, playbackRatePct: 2)
        var r1 = SeededRNG(seed: 7)
        var r2 = SeededRNG(seed: 7)
        let d1 = Variation.draw(opts, rng: &r1)
        let d2 = Variation.draw(opts, rng: &r2)
        #expect(d1 == d2)
        #expect(d1.gainScalar >= Variation.dbToGain(-2))
        #expect(d1.gainScalar <= Variation.dbToGain(2))
        #expect(d1.playbackRate >= 0.98)
        #expect(d1.playbackRate <= 1.02)
    }

    @Test
    func testStableSeedDependsOnSpec() {
        let a = BreathSpec(type: .inhale, durationSec: 4, style: "neutral")
        let b = BreathSpec(type: .inhale, durationSec: 4, style: "neutral")
        let c = BreathSpec(type: .inhale, durationSec: 8, style: "neutral")
        #expect(Variation.stableSeed(for: a) == Variation.stableSeed(for: b))
        #expect(Variation.stableSeed(for: a) != Variation.stableSeed(for: c))
    }

    @Test
    func testStableSeedUsesClampedDuration() {
        // 0.1s and 1.0s both clamp to the 1.0s floor, so the seed is identical.
        let belowFloor = BreathSpec(type: .inhale, durationSec: 0.1, style: "neutral")
        let atFloor = BreathSpec(type: .inhale, durationSec: 1.0, style: "neutral")
        #expect(Variation.stableSeed(for: belowFloor) == Variation.stableSeed(for: atFloor))
    }
}

struct ResampleTests {
    @Test
    func testTargetLengthAndEndpoints() {
        let input = (0..<100).map { Float($0) }
        let out = Resample.toFrames(input, 250)
        #expect(out.count == 250)
        #expect(abs(out.first! - input.first!) <= 1e-6)
        #expect(abs(out.last! - input.last!) <= 1e-6)
    }

    @Test
    func testByFactor() {
        let input = [Float](repeating: 0.5, count: 1000)
        #expect(Resample.byFactor(input, 1.02).count == 1020)  // lengthen
        #expect(Resample.byFactor(input, 0.98).count == 980)   // shorten (pitch up)
    }
}

struct BiquadTests {
    @Test
    func testHighpassReducesDC() {
        var samples = [Float](repeating: 1, count: 4_096)
        var filter = Biquad(kind: .highpass, sampleRate: 44_100, frequency: 300, q: 0.7)
        filter.process(&samples)
        let tailMean = samples.suffix(1_000).reduce(Float(0), +) / 1_000
        #expect(abs(tailMean) < 0.01)
    }

    @Test
    func testLowpassReducesFastAlternatingSignal() {
        let input = (0..<4_096).map { Float($0.isMultiple(of: 2) ? 1 : -1) }
        var filtered = input
        var filter = Biquad(kind: .lowpass, sampleRate: 44_100, frequency: 300, q: 0.7)
        filter.process(&filtered)
        #expect(rms(filtered) < rms(input) * 0.25)
    }
}

struct ManifestTests {
    @Test
    func testCodableRoundTrip() throws {
        var manifest = BreathManifest()
        var style = StyleManifest()
        style.inhale.loop = [BreathAsset(file: "a.wav", durationSec: 4, sampleRate: 44_100, channels: 1)]
        manifest.styles["neutral"] = style
        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(BreathManifest.self, from: data)
        #expect(decoded == manifest)
        #expect(decoded.palette(style: "neutral", type: .inhale)?.loop.first?.file == "a.wav")
    }
}

private func rms(_ samples: [Float]) -> Float {
    guard !samples.isEmpty else { return 0 }
    let sum = samples.reduce(Float(0)) { $0 + $1 * $1 }
    return sqrt(sum / Float(samples.count))
}

struct AssemblerTests {
    private func clips(sampleRate sr: Double) -> BreathSourceClips {
        BreathSourceClips(oneShot: [Float](repeating: 0.5, count: Int(1.2 * sr)))
    }

    @Test
    func testLongBreathExactLength() {
        let settings = AssemblerSettings()
        let sr = settings.sampleRate
        let dur = 30.0
        let out = BreathAssembler.assemble(
            type: .exhale, durationSec: dur, clips: clips(sampleRate: sr), settings: settings
        )
        #expect(out.count == Int((dur * sr).rounded()))
        #expect(out.map { abs($0) }.max()! > 0.01)
    }

    @Test
    func testRecordedShapeModeRendersExactLengthFromFullBreath() {
        let sr = 1_000.0
        let settings = AssemblerSettings(sampleRate: sr, crossfadeSec: 0.1)
        let full = shapedBreathFrames(sampleRate: sr, seconds: 10)
        let clips = BreathSourceClips(oneShot: full)

        let out = BreathAssembler.assemble(type: .inhale, durationSec: 8, clips: clips, settings: settings)

        #expect(out.count == 8_000)
        #expect(abs(out.first! - 0) <= 1e-6)
        #expect(abs(out.last! - 0) <= 1e-6)
        #expect(rms(out) > 0.02)
    }

    @Test
    func testRecordedShapeModeCompressesEnvelopeForShortBreath() {
        let sr = 1_000.0
        let settings = AssemblerSettings(sampleRate: sr, crossfadeSec: 0.1)
        let full = shapedBreathFrames(sampleRate: sr, seconds: 10)
        let clips = BreathSourceClips(oneShot: full)

        let out = BreathAssembler.assemble(type: .inhale, durationSec: 4, clips: clips, settings: settings)
        let early = rms(Array(out[0..<500]))
        let middle = rms(Array(out[1_500..<2_500]))
        let tail = rms(Array(out[3_500..<4_000]))

        #expect(out.count == 4_000)
        #expect(early < middle * 0.65)
        #expect(tail < middle * 0.65)
        #expect(middle > 0.02)
    }

    @Test
    func testRecordedShapeModeSmoothsAttackAndReleaseWobbles() {
        let sr = 1_000.0
        let settings = AssemblerSettings(sampleRate: sr, crossfadeSec: 0.1)
        let full = wobblyShapedBreathFrames(sampleRate: sr, seconds: 10)
        let clips = BreathSourceClips(oneShot: full)

        let out = BreathAssembler.assemble(type: .inhale, durationSec: 4, clips: clips, settings: settings)
        let envelope = chunkRMS(out, chunkSize: 250)
        let peakIndex = envelope.indices.max(by: { envelope[$0] < envelope[$1] })!
        let attack = Array(envelope[0...peakIndex])
        let release = Array(envelope[peakIndex..<envelope.count])

        #expect(isMostlyNondecreasing(attack, tolerance: 0.003), "attack RMS: \(attack)")
        #expect(isMostlyNonincreasing(release, tolerance: 0.003), "release RMS: \(release)")
    }

    @Test
    func testRecordedShapeNearLengthModeSmoothsDirectFadeWobbles() {
        let sr = 1_000.0
        let settings = AssemblerSettings(sampleRate: sr, crossfadeSec: 0.1)
        let full = wobblyShapedBreathFrames(sampleRate: sr, seconds: 10)
        let clips = BreathSourceClips(oneShot: full)

        let out = BreathAssembler.assemble(type: .exhale, durationSec: 8, clips: clips, settings: settings)
        let envelope = chunkRMS(out, chunkSize: 250)
        let peakIndex = envelope.indices.max(by: { envelope[$0] < envelope[$1] })!
        let attack = Array(envelope[0...peakIndex])
        let release = Array(envelope[peakIndex..<envelope.count])

        #expect(isMostlyNondecreasing(attack, tolerance: 0.003), "attack RMS: \(attack)")
        #expect(isMostlyNonincreasing(release, tolerance: 0.003), "release RMS: \(release)")
    }

    @Test
    func testRecordedShapeInhaleOnsetIsPromptWithNoInteriorDip() {
        // The designed envelope gives every duration the same prompt onset: a long
        // inhale must become audible within the attack window (no multi-second
        // near-silent lead-in), and the climb to the peak must not dip (guards the
        // old recording-derived double-attack/notch regression).
        let sr = 1_000.0
        let settings = AssemblerSettings(sampleRate: sr, crossfadeSec: 0.1)
        let full = shapedBreathFrames(sampleRate: sr, seconds: 10)
        let clips = BreathSourceClips(oneShot: full)

        let out = BreathAssembler.assemble(type: .inhale, durationSec: 12, clips: clips, settings: settings)
        #expect(out.count == 12_000)

        // 0.1 s RMS chunks: chunk index == tenths of a second.
        let envelope = chunkRMS(out, chunkSize: 100)
        let peak = envelope.max()!
        #expect(peak > 0.02)

        // RMS crosses 25% of peak well within the first 0.5 s (chunk 5).
        let crossing = envelope.firstIndex(where: { $0 >= 0.25 * peak })!
        #expect(crossing < 5, "onset crossing chunk \(crossing)")

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
        #expect(worstDrawdown < 0.15, "interior drawdown \(worstDrawdown) - attack RMS: \(envelope[0...peakIndex])")
    }

    @Test
    func testRecordedShapeRemovesLowFrequencyRumble() {
        // A synthetic "recording": a breath-shaped mid-band texture (600/1100/1900 Hz)
        // plus a strong 50 Hz room rumble. The recordedShape path's high-pass stages
        // must strip the sub-band before delivery, so the rendered output should carry
        // far less sub-120 Hz energy than its 300-3000 Hz mid-band energy.
        let sr = 16_000.0
        let settings = AssemblerSettings(sampleRate: sr, crossfadeSec: 0.1)
        let full = rumblyBreathFrames(sampleRate: sr, seconds: 10)
        let clips = BreathSourceClips(oneShot: full)

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

        #expect(midEnergy > 0, "mid-band energy should be present")
        #expect(lowEnergy / midEnergy < 0.5, "sub-120 Hz energy \(lowEnergy) vs mid \(midEnergy)")
    }

    @Test
    func testRecordedShapeSpectralDenoiseChangesSourceWhenEnabled() {
        // The `enableSpectralDenoise` branch in recordedShapeBranch must actually run and feed a
        // cleaned source into texture extraction: a skipped or no-op branch would make the
        // enabled render byte-identical to the default-off render.
        let sr = 16_000.0
        let full = rumblyBreathFrames(sampleRate: sr, seconds: 10)
        let clips = BreathSourceClips(oneShot: full)

        let off = BreathAssembler.assemble(
            type: .inhale, durationSec: 6, clips: clips,
            // Explicit off: spectral denoise now defaults to ON, so the baseline must opt out.
            settings: AssemblerSettings(sampleRate: sr, crossfadeSec: 0.1, enableSpectralDenoise: false)
        )
        let on = BreathAssembler.assemble(
            type: .inhale, durationSec: 6, clips: clips,
            settings: AssemblerSettings(sampleRate: sr, crossfadeSec: 0.1, enableSpectralDenoise: true)
        )

        #expect(on.count == 6 * Int(sr))
        #expect(on.count == off.count)
        #expect(on.allSatisfy { $0.isFinite }, "denoised output must stay finite")
        #expect(rms(on) > 0, "denoised breath should still be audible")
        #expect(on != off, "enabling denoise must change the rendered output")
    }
}

struct SpectralDenoiseTests {
    @Test
    func testUnityGainReconstruction() {
        // With overSubtraction 0 the per-bin gain is max(mag, floorGain*mag) = mag, so denoise
        // is the identity transform. This isolates the STFT/overlap-add machinery: the interior
        // (away from the window-overlap ramp at the edges) must reconstruct the input exactly.
        let sr = 16_000.0
        let n = 8_192
        let signal = zip(
            (0..<n).map { Float(0.3 * sin(2 * Double.pi * 1_000 * Double($0) / sr)) },
            seededNoise(count: n, seed: 99, amplitude: 0.05)
        ).map(+)

        let out = SpectralDenoise.denoise(signal, sampleRate: sr, overSubtraction: 0, floorGain: 0)
        #expect(out.count == signal.count)

        let pad = 1_024 // skip the first/last frame where the window overlap is still ramping
        var maxErr: Float = 0
        for i in pad..<(n - pad) {
            maxErr = max(maxErr, abs(out[i] - signal[i]))
        }
        #expect(maxErr < 1e-3, "interior reconstruction error \(maxErr)")
    }

    @Test
    func testSuppressesSteadyNoisePreservesTone() {
        // A 1200 Hz tone present only in a central window (so the per-bin minimum statistics
        // capture the noise floor, not the tone) over steady broadband noise spanning the whole
        // signal. Denoise should crush the noise-only band while leaving the tone intact.
        let sr = 16_000.0
        let n = 64_000 // 4 s
        let toneStart = Int(1.5 * sr)
        let toneEnd = Int(3.0 * sr)
        var signal = seededNoise(count: n, seed: 123, amplitude: 0.04)
        for i in toneStart..<toneEnd {
            signal[i] += Float(0.3 * sin(2 * Double.pi * 1_200 * Double(i) / sr))
        }

        // 1.0 s probe windows (== sr samples) so integer-Hz probes land on DFT bin centres.
        let noiseWin = 3_200..<(3_200 + Int(sr)) // inside the leading noise-only stretch
        let toneWin = 28_800..<(28_800 + Int(sr)) // inside the tone stretch
        // Probe both the high hiss band and an in-band (800 Hz) noise-only frequency, to confirm
        // the denoiser reduces quiet-moment energy inside the breath band too, not just up high.
        let noiseProbes: [Double] = [800, 2_500, 3_500, 5_000]
        func noiseEnergy(_ x: [Float]) -> Double {
            noiseProbes.map { goertzelMagnitude(Array(x[noiseWin]), sampleRate: sr, frequency: $0) }.reduce(0, +)
        }
        func toneEnergy(_ x: [Float]) -> Double {
            goertzelMagnitude(Array(x[toneWin]), sampleRate: sr, frequency: 1_200)
        }

        let noiseBefore = noiseEnergy(signal)
        let toneBefore = toneEnergy(signal)
        let out = SpectralDenoise.denoise(signal, sampleRate: sr, overSubtraction: 2.0, floorGain: 0.05)
        let noiseAfter = noiseEnergy(out)
        let toneAfter = toneEnergy(out)

        #expect(noiseBefore > 0)
        #expect(toneBefore > 0)
        #expect(noiseAfter / noiseBefore < 0.5, "noise band \(noiseAfter) vs \(noiseBefore)")
        #expect(toneAfter / toneBefore > 0.7, "tone \(toneAfter) vs \(toneBefore)")
    }

    @Test
    func testDeterministic() {
        let sr = 16_000.0
        let n = 4_096
        let signal = zip(
            (0..<n).map { Float(0.2 * sin(2 * Double.pi * 800 * Double($0) / sr)) },
            seededNoise(count: n, seed: 7, amplitude: 0.05)
        ).map(+)
        let a = SpectralDenoise.denoise(signal, sampleRate: sr, overSubtraction: 1.8, floorGain: 0.05)
        let b = SpectralDenoise.denoise(signal, sampleRate: sr, overSubtraction: 1.8, floorGain: 0.05)
        #expect(a == b)
    }

    @Test
    func testShortInputReturnedUnchanged() {
        // Inputs no longer than one analysis frame (1024) can't be denoised; pass them through
        // untouched rather than crash.
        let short = (0..<1_024).map { Float(0.1 * sin(2 * Double.pi * 500 * Double($0) / 16_000.0)) }
        let out = SpectralDenoise.denoise(short, sampleRate: 16_000, overSubtraction: 2.0, floorGain: 0.05)
        #expect(out == short)
    }

    @Test
    func testAllSilenceStaysSilentAndFinite() {
        let silence = [Float](repeating: 0, count: 8_192)
        let out = SpectralDenoise.denoise(silence, sampleRate: 16_000, overSubtraction: 2.0, floorGain: 0.05)
        #expect(out.count == silence.count)
        #expect(out.allSatisfy { $0 == 0 }, "silence in, silence out (no NaN / denormal blowup)")
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

/// Deterministic broadband noise in [-amplitude, amplitude] from the engine's seeded RNG, so
/// the denoise tests stay reproducible run to run.
private func seededNoise(count: Int, seed: UInt64, amplitude: Float) -> [Float] {
    var rng = SeededRNG(seed: seed)
    return (0..<count).map { _ in
        let unit = Double(rng.next()) / Double(UInt64.max) // [0, 1]
        return Float(unit * 2 - 1) * amplitude
    }
}
