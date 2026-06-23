import Foundation

enum GranularBreathSynth {
    private struct Profile {
        var gain: Double
        var backgroundGain: Float
        var grainGain: Float
        var minGapMs: Double
        var maxGapMs: Double
        var minGrainMs: Double
        var maxGrainMs: Double
        var bodyLowpass: Double
        var detailHighpass: Double
        var throatHz: Double
        var mouthHz: Double
    }

    static func render(
        spec: BreathSpec,
        sampleRate: Double,
        config: ProceduralBreathConfig,
        deltas: VariationDeltas
    ) throws -> [Float] {
        guard ProceduralBreathSynth.supportedStyles.contains(spec.style) else {
            throw BreathError.unsupportedProceduralStyle(spec.style)
        }

        let frames = max(1, Segments.frames(seconds: spec.clampedDurationSec, sampleRate: sampleRate))
        let profile = makeProfile(style: spec.style, type: spec.type, brightness: deltas.playbackRate)
        let seed = spec.seed ?? Variation.stableSeed(for: spec)
        var rng = SeededRNG(seed: seed ^ 0x6A44_3A11_0000_0003)
        var out = [Float](repeating: 0, count: frames)
        var pink = PinkNoise()
        let drift = ProceduralSupport.randomWalk(
            frames: frames,
            sampleRate: sampleRate,
            intervalSeconds: spec.type == .inhale ? 0.19 : 0.31,
            depth: Float(0.08 + config.modulationAmount),
            rng: &rng
        )

        for i in 0..<frames {
            out[i] = pink.next(rng: &rng) * profile.backgroundGain * drift[i]
        }

        var cursor = 0
        while cursor < frames {
            let gap = Double.random(in: profile.minGapMs...profile.maxGapMs, using: &rng) / 1_000
            cursor += max(1, Int((gap * sampleRate).rounded()))
            guard cursor < frames else { break }
            let grainSeconds = Double.random(in: profile.minGrainMs...profile.maxGrainMs, using: &rng) / 1_000
            let grainFrames = max(8, Int((grainSeconds * sampleRate).rounded()))
            let window = ProceduralSupport.raisedCosineWindow(length: grainFrames)
            let grainGain = profile.grainGain * Float.random(in: 0.45...1.25, using: &rng)
            var grainNoise = PinkNoise()
            for j in 0..<grainFrames where cursor + j < frames {
                let rough = grainNoise.next(rng: &rng) + Float.random(in: -0.12...0.12, using: &rng)
                out[cursor + j] += rough * window[j] * grainGain * drift[cursor + j]
            }
        }

        var body = out
        var detail = out
        var throat = out
        var mouth = out
        var bodyFilter = Biquad(kind: .lowpass, sampleRate: sampleRate, frequency: profile.bodyLowpass, q: 0.65)
        var detailFilter = Biquad(kind: .highpass, sampleRate: sampleRate, frequency: profile.detailHighpass, q: 0.65)
        var throatFilter = Biquad(kind: .bandpass, sampleRate: sampleRate, frequency: profile.throatHz, q: 0.85)
        var mouthFilter = Biquad(kind: .bandpass, sampleRate: sampleRate, frequency: profile.mouthHz, q: 0.75)
        bodyFilter.process(&body)
        detailFilter.process(&detail)
        throatFilter.process(&throat)
        mouthFilter.process(&mouth)

        let resonance = Float(config.resonanceAmount)
        for i in out.indices {
            out[i] = body[i] * 0.46 + detail[i] * 0.26
            out[i] += throat[i] * 0.20 * resonance
            out[i] += mouth[i] * 0.13 * resonance
        }

        return ProceduralSupport.finish(
            out,
            spec: spec,
            sampleRate: sampleRate,
            gain: profile.gain,
            config: config,
            deltas: deltas
        )
    }

    private static func makeProfile(style: BreathStyle, type: BreathType, brightness: Double) -> Profile {
        let b = min(max(brightness, 0.92), 1.08)
        switch (style, type) {
        case ("calm", .inhale):
            return Profile(
                gain: 0.90,
                backgroundGain: 0.10,
                grainGain: 0.15,
                minGapMs: 9,
                maxGapMs: 34,
                minGrainMs: 8,
                maxGrainMs: 42,
                bodyLowpass: 2_200 * b,
                detailHighpass: 950 * b,
                throatHz: 830 * b,
                mouthHz: 2_100 * b
            )
        case ("calm", .exhale):
            return Profile(
                gain: 0.98,
                backgroundGain: 0.13,
                grainGain: 0.13,
                minGapMs: 15,
                maxGapMs: 52,
                minGrainMs: 14,
                maxGrainMs: 72,
                bodyLowpass: 1_650 * b,
                detailHighpass: 560 * b,
                throatHz: 560 * b,
                mouthHz: 1_350 * b
            )
        case ("neutral", .inhale):
            return Profile(
                gain: 1.08,
                backgroundGain: 0.12,
                grainGain: 0.20,
                minGapMs: 7,
                maxGapMs: 26,
                minGrainMs: 6,
                maxGrainMs: 34,
                bodyLowpass: 3_100 * b,
                detailHighpass: 1_100 * b,
                throatHz: 920 * b,
                mouthHz: 2_350 * b
            )
        default:
            return Profile(
                gain: 1.12,
                backgroundGain: 0.15,
                grainGain: 0.17,
                minGapMs: 12,
                maxGapMs: 40,
                minGrainMs: 12,
                maxGrainMs: 58,
                bodyLowpass: 2_000 * b,
                detailHighpass: 650 * b,
                throatHz: 620 * b,
                mouthHz: 1_520 * b
            )
        }
    }
}
