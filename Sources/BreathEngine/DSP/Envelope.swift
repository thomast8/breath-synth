import Foundation

/// Pure amplitude-envelope generation. The envelope gives the breath its macro
/// contour and guarantees the first/last sample are exactly 0 (click-free starts,
/// ends, and cycle joins). No AVFoundation.
public enum Envelope {
    /// Normalized control points (t, gain), both in 0...1, sorted by t, starting at
    /// (0, 0) and ending at (1, 0).
    ///
    /// Inhale: quiet start → rising → steady draw → slight taper.
    /// Exhale: soft onset → fuller airflow → long decay → near silence.
    public static func controlPoints(for type: BreathType) -> [(t: Double, gain: Double)] {
        switch type {
        case .inhale:
            return [
                (0.00, 0.00),
                (0.10, 0.40),
                (0.40, 0.90),
                (0.75, 0.92),
                (0.95, 0.70),
                (1.00, 0.00),
            ]
        case .exhale:
            return [
                (0.00, 0.00),
                (0.06, 0.60),
                (0.18, 0.95),
                (0.50, 0.60),
                (0.85, 0.20),
                (1.00, 0.00),
            ]
        }
    }

    /// For very long breaths the contour is scaled down and softened so it reads as
    /// quiet and meditative rather than "continuously hoovering air".
    /// 1.0 up to 18s, easing to 0.6 by 30s.
    public static func longBreathGainScale(durationSec: Double) -> Float {
        guard durationSec > 18 else { return 1 }
        let t = min(1, (durationSec - 18) / (30 - 18))
        return Float(1 - 0.4 * t)
    }

    /// Sample the contour to `frames` samples, scaled for long breaths. First and
    /// last samples are forced to exactly 0.
    public static func curve(for type: BreathType, frames: Int, durationSec: Double) -> [Float] {
        guard frames > 0 else { return [] }
        let points = controlPoints(for: type)
        let scale = longBreathGainScale(durationSec: durationSec)
        if frames == 1 { return [0] }

        var out = [Float](repeating: 0, count: frames)
        var segment = 0
        for i in 0..<frames {
            let x = Double(i) / Double(frames - 1)
            // Advance to the segment containing x.
            while segment < points.count - 2, x > points[segment + 1].t {
                segment += 1
            }
            let a = points[segment]
            let b = points[segment + 1]
            let span = b.t - a.t
            let frac = span > 0 ? (x - a.t) / span : 0
            let g = a.gain + (b.gain - a.gain) * frac
            out[i] = Float(g) * scale
        }
        out[0] = 0
        out[frames - 1] = 0
        return out
    }
}
