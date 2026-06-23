import Foundation

enum BiquadKind {
    case lowpass
    case highpass
    case bandpass
}

/// Small RBJ biquad filter used by the procedural breath synth.
struct Biquad: Sendable {
    private var b0: Float
    private var b1: Float
    private var b2: Float
    private var a1: Float
    private var a2: Float
    private var z1: Float = 0
    private var z2: Float = 0

    init(kind: BiquadKind, sampleRate: Double, frequency: Double, q: Double) {
        let nyquistSafe = max(20, min(frequency, sampleRate * 0.45))
        let qSafe = max(0.1, q)
        let omega = 2 * Double.pi * nyquistSafe / sampleRate
        let sinW = sin(omega)
        let cosW = cos(omega)
        let alpha = sinW / (2 * qSafe)

        let rawB0: Double
        let rawB1: Double
        let rawB2: Double
        let rawA0: Double
        let rawA1: Double
        let rawA2: Double

        switch kind {
        case .lowpass:
            rawB0 = (1 - cosW) / 2
            rawB1 = 1 - cosW
            rawB2 = (1 - cosW) / 2
            rawA0 = 1 + alpha
            rawA1 = -2 * cosW
            rawA2 = 1 - alpha
        case .highpass:
            rawB0 = (1 + cosW) / 2
            rawB1 = -(1 + cosW)
            rawB2 = (1 + cosW) / 2
            rawA0 = 1 + alpha
            rawA1 = -2 * cosW
            rawA2 = 1 - alpha
        case .bandpass:
            rawB0 = alpha
            rawB1 = 0
            rawB2 = -alpha
            rawA0 = 1 + alpha
            rawA1 = -2 * cosW
            rawA2 = 1 - alpha
        }

        self.b0 = Float(rawB0 / rawA0)
        self.b1 = Float(rawB1 / rawA0)
        self.b2 = Float(rawB2 / rawA0)
        self.a1 = Float(rawA1 / rawA0)
        self.a2 = Float(rawA2 / rawA0)
    }

    mutating func process(_ input: Float) -> Float {
        let output = b0 * input + z1
        z1 = b1 * input - a1 * output + z2
        z2 = b2 * input - a2 * output
        return output.isFinite ? output : 0
    }

    mutating func process(_ samples: inout [Float]) {
        for i in samples.indices {
            samples[i] = process(samples[i])
        }
    }
}
