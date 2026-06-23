import Foundation

struct PinkNoise {
    private var b0: Float = 0
    private var b1: Float = 0
    private var b2: Float = 0

    mutating func next<RNG: RandomNumberGenerator>(rng: inout RNG) -> Float {
        let white = Float.random(in: -1...1, using: &rng)
        b0 = 0.99765 * b0 + white * 0.0990460
        b1 = 0.96300 * b1 + white * 0.2965164
        b2 = 0.57000 * b2 + white * 1.0526913
        return (b0 + b1 + b2 + white * 0.1848) * 0.05
    }
}

enum ProceduralSupport {
    static func finish(
        _ rawInput: [Float],
        spec: BreathSpec,
        sampleRate: Double,
        gain: Double,
        config: ProceduralBreathConfig,
        deltas: VariationDeltas
    ) -> [Float] {
        guard !rawInput.isEmpty else { return [] }
        var raw = normalizePeak(rawInput, target: 0.90)
        let envelope = Envelope.curve(
            for: spec.type,
            frames: raw.count,
            durationSec: spec.clampedDurationSec
        )
        let scalar = Float(gain * config.airGain * deltas.gainScalar)
        for i in raw.indices {
            raw[i] = softLimit(raw[i] * envelope[i] * scalar)
            if !raw[i].isFinite { raw[i] = 0 }
        }
        raw[0] = 0
        raw[raw.count - 1] = 0

        // Kill any residual DC from asymmetric turbulence or tube boundaries.
        var highpass = Biquad(kind: .highpass, sampleRate: sampleRate, frequency: 18, q: 0.7)
        highpass.process(&raw)
        raw[0] = 0
        raw[raw.count - 1] = 0
        return raw
    }

    static func normalizePeak(_ samples: [Float], target: Float) -> [Float] {
        guard let peak = samples.map({ abs($0) }).max(), peak > 0 else { return samples }
        let scale = target / peak
        return samples.map { $0 * scale }
    }

    static func softLimit(_ x: Float) -> Float {
        tanh(x)
    }

    static func randomWalk(
        frames: Int,
        sampleRate: Double,
        intervalSeconds: Double,
        depth: Float,
        rng: inout SeededRNG
    ) -> [Float] {
        guard frames > 0 else { return [] }
        let interval = max(1, Int((intervalSeconds * sampleRate).rounded()))
        var out = [Float](repeating: 1, count: frames)
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
            out[i] = current
            offset += 1
        }
        return out
    }

    static func raisedCosineWindow(length: Int) -> [Float] {
        guard length > 1 else { return [1] }
        return (0..<length).map { i in
            let phase = 2 * Float.pi * Float(i) / Float(length - 1)
            return 0.5 - 0.5 * cos(phase)
        }
    }
}
