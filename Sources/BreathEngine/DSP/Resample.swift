import Foundation

/// Pure linear-interpolation resampling. Endpoints are preserved exactly, which
/// keeps click-free starts/ends intact. No AVFoundation.
public enum Resample {
    /// Resample `input` to exactly `targetFrames` samples.
    public static func toFrames(_ input: [Float], _ targetFrames: Int) -> [Float] {
        guard targetFrames > 0 else { return [] }
        guard input.count > 1 else {
            return [Float](repeating: input.first ?? 0, count: targetFrames)
        }
        if targetFrames == input.count { return input }
        var out = [Float](repeating: 0, count: targetFrames)
        let ratio = Double(input.count - 1) / Double(max(1, targetFrames - 1))
        for i in 0..<targetFrames {
            let pos = Double(i) * ratio
            let i0 = Int(pos)
            let frac = Float(pos - Double(i0))
            let a = input[i0]
            let b = (i0 + 1 < input.count) ? input[i0 + 1] : a
            out[i] = a + (b - a) * frac
        }
        // Guarantee exact endpoints despite floating-point.
        out[0] = input[0]
        out[targetFrames - 1] = input[input.count - 1]
        return out
    }

    /// Resample `input` by a rate `factor` (> 1 lengthens / lowers pitch).
    public static func byFactor(_ input: [Float], _ factor: Double) -> [Float] {
        guard factor > 0, !input.isEmpty else { return input }
        let target = max(1, Int((Double(input.count) * factor).rounded()))
        return toFrames(input, target)
    }
}
