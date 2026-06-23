import Foundation

enum KlattBreathSynth {
    private struct Profile {
        var gain: Double
        var aspirationLowpass: Double
        var fricationHighpass: Double
        var formants: [(hz: Double, q: Double, gain: Float)]
        var nasalHz: Double
        var nasalGain: Float
        var fricationGain: Float
        var aspirationGain: Float
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
        var rng = SeededRNG(seed: seed ^ 0x4B1A_77D0_0000_0002)
        var pink = PinkNoise()
        var aspirationLow = Biquad(kind: .lowpass, sampleRate: sampleRate, frequency: profile.aspirationLowpass, q: 0.7)
        var fricationHigh = Biquad(kind: .highpass, sampleRate: sampleRate, frequency: profile.fricationHighpass, q: 0.7)
        var oralFormants = profile.formants.map {
            Biquad(kind: .bandpass, sampleRate: sampleRate, frequency: $0.hz, q: $0.q)
        }
        var nasal = Biquad(kind: .bandpass, sampleRate: sampleRate, frequency: profile.nasalHz, q: 0.55)
        let drift = ProceduralSupport.randomWalk(
            frames: frames,
            sampleRate: sampleRate,
            intervalSeconds: spec.type == .inhale ? 0.25 : 0.38,
            depth: Float(0.10 + config.modulationAmount),
            rng: &rng
        )

        var out = [Float](repeating: 0, count: frames)
        for i in 0..<frames {
            let p = drift[i]
            let white = Float.random(in: -1...1, using: &rng)
            let source = pink.next(rng: &rng) * 0.74 + white * 0.08
            let aspiration = aspirationLow.process(source) * profile.aspirationGain
            let frication = fricationHigh.process(source) * profile.fricationGain
            var sample = aspiration * 0.45 + frication * 0.22
            for j in oralFormants.indices {
                sample += oralFormants[j].process(aspiration + frication) * profile.formants[j].gain
            }
            sample += nasal.process(aspiration) * profile.nasalGain
            out[i] = sample * p
        }

        return ProceduralSupport.finish(
            out,
            spec: spec,
            sampleRate: sampleRate,
            gain: profile.gain * (0.75 + config.resonanceAmount * 0.25),
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
                aspirationLowpass: 3_000 * b,
                fricationHighpass: 900 * b,
                formants: [(760 * b, 1.2, 0.28), (1_750 * b, 1.0, 0.16), (2_900 * b, 0.8, 0.08)],
                nasalHz: 320,
                nasalGain: 0.10,
                fricationGain: 0.35,
                aspirationGain: 0.70
            )
        case ("calm", .exhale):
            return Profile(
                gain: 0.98,
                aspirationLowpass: 2_250 * b,
                fricationHighpass: 520 * b,
                formants: [(560 * b, 1.0, 0.34), (1_250 * b, 0.85, 0.18), (2_350 * b, 0.7, 0.07)],
                nasalHz: 260,
                nasalGain: 0.13,
                fricationGain: 0.24,
                aspirationGain: 0.82
            )
        case ("neutral", .inhale):
            return Profile(
                gain: 1.08,
                aspirationLowpass: 4_100 * b,
                fricationHighpass: 1_050 * b,
                formants: [(880 * b, 1.3, 0.32), (2_050 * b, 1.0, 0.18), (3_200 * b, 0.85, 0.10)],
                nasalHz: 340,
                nasalGain: 0.08,
                fricationGain: 0.44,
                aspirationGain: 0.66
            )
        default:
            return Profile(
                gain: 1.12,
                aspirationLowpass: 2_700 * b,
                fricationHighpass: 620 * b,
                formants: [(620 * b, 1.1, 0.36), (1_420 * b, 0.9, 0.20), (2_550 * b, 0.72, 0.08)],
                nasalHz: 280,
                nasalGain: 0.11,
                fricationGain: 0.30,
                aspirationGain: 0.78
            )
        }
    }
}
