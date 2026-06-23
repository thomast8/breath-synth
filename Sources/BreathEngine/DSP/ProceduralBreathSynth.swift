import Foundation

/// Pure procedural breath-like texture generator. It is designed for calm,
/// controllable breathing cues rather than close-mic human realism.
public enum ProceduralBreathSynth {
    private struct Profile {
        var gain: Double
        var smoothAlpha: Float
        var highpassHz: Double
        var lowpassHz: Double
        var band1Hz: Double
        var band2Hz: Double
        var band1Gain: Double
        var band2Gain: Double
        var detailMix: Double
        var wanderSeconds: Double
    }

    public static let supportedStyles: Set<BreathStyle> = ["neutral", "calm"]

    public static func render(
        spec: BreathSpec,
        sampleRate: Double = AudioConstants.workingSampleRate,
        config: ProceduralBreathConfig = .calmAir,
        deltas: VariationDeltas = .identity
    ) throws -> [Float] {
        switch config.generator {
        case .tract:
            return try VocalTractBreathSynth.render(
                spec: spec,
                sampleRate: sampleRate,
                config: config,
                deltas: deltas
            )
        case .klatt:
            return try KlattBreathSynth.render(
                spec: spec,
                sampleRate: sampleRate,
                config: config,
                deltas: deltas
            )
        case .granular:
            return try GranularBreathSynth.render(
                spec: spec,
                sampleRate: sampleRate,
                config: config,
                deltas: deltas
            )
        case .legacy:
            return try renderLegacy(
                spec: spec,
                sampleRate: sampleRate,
                config: config,
                deltas: deltas
            )
        }
    }

    private static func renderLegacy(
        spec: BreathSpec,
        sampleRate: Double,
        config: ProceduralBreathConfig,
        deltas: VariationDeltas
    ) throws -> [Float] {
        let durationSec = spec.clampedDurationSec
        let frames = max(1, Segments.frames(seconds: durationSec, sampleRate: sampleRate))
        let profile = try Self.profile(
            style: spec.style,
            type: spec.type,
            brightness: deltas.playbackRate
        )
        let seed = spec.seed ?? Variation.stableSeed(for: spec)
        var rng = SeededRNG(seed: seed)

        var raw = makeNoise(frames: frames, profile: profile, rng: &rng)
        let filtered = filter(raw, profile: profile, sampleRate: sampleRate, config: config)
        raw = applyIrregularDrift(
            filtered,
            profile: profile,
            sampleRate: sampleRate,
            config: config,
            rng: &rng
        )

        return ProceduralSupport.finish(
            raw,
            spec: spec,
            sampleRate: sampleRate,
            gain: profile.gain,
            config: config,
            deltas: deltas
        )
    }

    private static func makeNoise(frames: Int, profile: Profile, rng: inout SeededRNG) -> [Float] {
        var out = [Float](repeating: 0, count: frames)
        var pink0: Float = 0
        var pink1: Float = 0
        var pink2: Float = 0
        var body: Float = 0
        var air: Float = 0
        let detail = Float(profile.detailMix)
        for i in 0..<frames {
            let white = Float.random(in: -1...1, using: &rng)

            // A tiny pink-noise bank gives the source a less synthetic spectrum
            // than raw white noise, before the breath filters shape it further.
            pink0 = 0.99765 * pink0 + white * 0.0990460
            pink1 = 0.96300 * pink1 + white * 0.2965164
            pink2 = 0.57000 * pink2 + white * 1.0526913
            let pink = (pink0 + pink1 + pink2 + white * 0.1848) * 0.05

            body += profile.smoothAlpha * (pink - body)
            air += 0.035 * (pink - air)
            out[i] = body * (1 - detail) + air * detail
        }
        return out
    }

    private static func filter(
        _ raw: [Float],
        profile: Profile,
        sampleRate: Double,
        config: ProceduralBreathConfig
    ) -> [Float] {
        var main = raw
        var highpass = Biquad(kind: .highpass, sampleRate: sampleRate, frequency: profile.highpassHz, q: 0.70)
        var lowpass = Biquad(kind: .lowpass, sampleRate: sampleRate, frequency: profile.lowpassHz, q: 0.65)
        highpass.process(&main)
        lowpass.process(&main)

        var band1 = raw
        var band2 = raw
        var formant1 = Biquad(kind: .bandpass, sampleRate: sampleRate, frequency: profile.band1Hz, q: 0.90)
        var formant2 = Biquad(kind: .bandpass, sampleRate: sampleRate, frequency: profile.band2Hz, q: 0.80)
        formant1.process(&band1)
        formant2.process(&band2)

        let resonance = config.resonanceAmount
        for i in main.indices {
            main[i] += band1[i] * Float(profile.band1Gain * resonance)
            main[i] += band2[i] * Float(profile.band2Gain * resonance)
        }
        return main
    }

    private static func applyIrregularDrift(
        _ samples: [Float],
        profile: Profile,
        sampleRate: Double,
        config: ProceduralBreathConfig,
        rng: inout SeededRNG
    ) -> [Float] {
        guard config.modulationAmount > 0, !samples.isEmpty else { return samples }
        let interval = max(1, Int((profile.wanderSeconds * sampleRate).rounded()))
        let depth = Float(config.modulationAmount)
        var out = samples
        var current: Float = 1
        var start: Float = 1
        var target = Float.random(in: 1 - depth...1 + depth, using: &rng)
        var offset = 0
        for i in out.indices {
            if offset >= interval {
                offset = 0
                start = current
                target = Float.random(in: 1 - depth...1 + depth, using: &rng)
            }
            let t = Float(offset) / Float(max(1, interval - 1))
            let eased = t * t * (3 - 2 * t)
            current = start + (target - start) * eased
            out[i] *= current
            offset += 1
        }
        return out
    }

    private static func profile(style: BreathStyle, type: BreathType, brightness: Double) throws -> Profile {
        guard supportedStyles.contains(style) else {
            throw BreathError.unsupportedProceduralStyle(style)
        }
        let b = min(max(brightness, 0.90), 1.10)

        switch (style, type) {
        case ("neutral", .inhale):
            return Profile(
                gain: 1.00,
                smoothAlpha: 0.22,
                highpassHz: 360 * b,
                lowpassHz: 7_000 * b,
                band1Hz: 1_150 * b,
                band2Hz: 2_550 * b,
                band1Gain: 0.09,
                band2Gain: 0.03,
                detailMix: 0.20,
                wanderSeconds: 1.6
            )
        case ("neutral", .exhale):
            return Profile(
                gain: 1.05,
                smoothAlpha: 0.10,
                highpassHz: 150 * b,
                lowpassHz: 3_800 * b,
                band1Hz: 680 * b,
                band2Hz: 1_600 * b,
                band1Gain: 0.08,
                band2Gain: 0.025,
                detailMix: 0.16,
                wanderSeconds: 1.8
            )
        case ("calm", .inhale):
            return Profile(
                gain: 0.76,
                smoothAlpha: 0.13,
                highpassHz: 420 * b,
                lowpassHz: 3_800 * b,
                band1Hz: 1_050 * b,
                band2Hz: 2_200 * b,
                band1Gain: 0.055,
                band2Gain: 0.018,
                detailMix: 0.10,
                wanderSeconds: 2.2
            )
        case ("calm", .exhale):
            return Profile(
                gain: 0.82,
                smoothAlpha: 0.055,
                highpassHz: 190 * b,
                lowpassHz: 2_700 * b,
                band1Hz: 620 * b,
                band2Hz: 1_400 * b,
                band1Gain: 0.05,
                band2Gain: 0.015,
                detailMix: 0.08,
                wanderSeconds: 2.5
            )
        default:
            throw BreathError.unsupportedProceduralStyle(style)
        }
    }
}
