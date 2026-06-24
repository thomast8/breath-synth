import Foundation

/// Pure amplitude-envelope generation. The envelope gives the breath its macro
/// contour and guarantees the first/last sample are exactly 0 (click-free starts,
/// ends, and cycle joins). No AVFoundation.
///
/// The contour is *designed*, not derived from the recording: it is built from an
/// **absolute** attack and release (in seconds) plus a proportional sustain shape.
/// Absolute edges are what make a long breath start promptly - a 12 s inhale becomes
/// audible within the attack window instead of ramping near-silent for over a second
/// the way a recording-derived envelope did. Identical dynamics for every duration.
public enum Envelope {
    /// Per-type design parameters for the macro contour. Every field is taken from the
    /// matching source recording's measured envelope, so inhale and exhale have
    /// genuinely different attacks *and* fall-offs.
    private struct Design {
        /// Attack length in seconds (0 -> `attackLevel`), raised-cosine.
        let attackSec: Double
        /// Level reached at the end of the attack (the "prompt but soft" onset).
        let attackLevel: Double
        /// Fraction of the breath where amplitude hits its 1.0 peak.
        let peakFrac: Double
        /// How front-loaded the drop from the peak toward the floor is. 1.0 is a steady
        /// decline; larger deflates faster right after the peak (the exhale "huff").
        let decaySteepness: Double
        /// Level the body settles to and holds before the final tail (0 = decay all the
        /// way down, used by the inhale, which has no held airflow).
        let sustainFloor: Double
        /// Fraction of the whole breath spent fading the floor gently to true zero.
        let tailFraction: Double
    }

    private static func design(for type: BreathType, style: BreathStyle) -> Design {
        // Forceful, fast breathing holds near full intensity rather than swelling and
        // decaying like a relaxed breath: quick attack, early peak, a high sustain floor so
        // the level stays strong across the whole breath, and only a short end fade. Without
        // this, the default contour's back-half decay reads as the level "dropping".
        if style == "hyperventilation" {
            switch type {
            case .inhale:
                return Design(attackSec: 0.18, attackLevel: 0.85, peakFrac: 0.22,
                              decaySteepness: 0.7, sustainFloor: 0.82, tailFraction: 0.10)
            case .exhale:
                // Forceful and fairly even: a longer, gentler attack ramps up over the take's
                // glottal onset ("ungh") instead of a hard hit, then holds high (~0.72) with only a
                // gentle decline so the power doesn't visibly sag, ending with a short tail fade.
                return Design(attackSec: 0.28, attackLevel: 0.45, peakFrac: 0.20,
                              decaySteepness: 0.6, sustainFloor: 0.88, tailFraction: 0.12)
            }
        }
        // Peak locations and fall-off character are measured from the source recordings:
        //  * inhale: a slow, gradual draw - broad peak ~60%, then a steady decline over
        //    the back third that lands softly. No held airflow, so no floor/tail.
        //  * exhale: a fast attack to an early peak (~13%), a quick deflation to a low
        //    airflow it sustains (~0.3) through the middle, then a long fade at the end.
        // The fall-off is proportional to duration (see `curve`), so a long breath
        // decays slowly and naturally rather than cutting off.
        switch type {
        case .inhale:
            return Design(attackSec: 0.30, attackLevel: 0.70, peakFrac: 0.62,
                          decaySteepness: 1.3, sustainFloor: 0.0, tailFraction: 0.0)
        case .exhale:
            return Design(attackSec: 0.15, attackLevel: 0.95, peakFrac: 0.13,
                          decaySteepness: 2.5, sustainFloor: 0.30, tailFraction: 0.18)
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

    /// Sample the designed contour to `frames` samples, scaled for long breaths. First
    /// and last samples are forced to exactly 0.
    public static func curve(for type: BreathType, style: BreathStyle = "neutral", frames: Int, durationSec: Double) -> [Float] {
        guard frames > 0 else { return [] }
        if frames == 1 { return [0] }

        let d = design(for: type, style: style)
        let dur = max(durationSec, 0.001)
        let scale = longBreathGainScale(durationSec: durationSec)

        // The attack is absolute (seconds), capped so it never crowds out the body on
        // short breaths. The peak is clamped just past the attack. Everything after the
        // peak is a single proportional fall-off, so the decay scales with duration.
        let aFrac = min(d.attackSec / dur, 0.40)
        let peakFrac = min(max(d.peakFrac, aFrac + 1e-4), 1 - 1e-4)

        var out = [Float](repeating: 0, count: frames)
        for i in 0..<frames {
            let x = Double(i) / Double(frames - 1)
            let g: Double
            if x < aFrac {
                // Attack: 0 -> attackLevel.
                g = d.attackLevel * raisedCosine(x / max(aFrac, 1e-9))
            } else if x < peakFrac {
                // Rise: attackLevel -> 1.0 (the swell into the peak).
                let p = (x - aFrac) / max(peakFrac - aFrac, 1e-9)
                g = d.attackLevel + (1 - d.attackLevel) * raisedCosine(p)
            } else {
                // Fall-off, proportional to duration. The body eases from the peak down
                // to the sustain floor (front-loaded by `decaySteepness`), then the last
                // `tailFraction` of the breath fades that floor gently to true zero.
                // Inhale uses no floor/tail (a steady decline to a soft landing); exhale
                // deflates to a low airflow it holds, then fades - each from its own
                // recording. Spanning the whole region (not a fixed short release) is
                // what reads as a natural, unhurried decay rather than an abrupt cutoff.
                let bodyEnd = max(peakFrac + 1e-4, 1 - d.tailFraction)
                if x < bodyEnd {
                    let p = (x - peakFrac) / max(bodyEnd - peakFrac, 1e-9)
                    g = d.sustainFloor + (1 - d.sustainFloor) * pow(1 - p, d.decaySteepness)
                } else {
                    let q = (x - bodyEnd) / max(1 - bodyEnd, 1e-9)
                    g = d.sustainFloor * (0.5 + 0.5 * cos(q * Double.pi))
                }
            }
            out[i] = Float(g) * scale
        }
        out[0] = 0
        out[frames - 1] = 0
        return out
    }

    /// Smooth 0 -> 1 raised-cosine (half-cosine) ramp for `p` in 0...1.
    private static func raisedCosine(_ p: Double) -> Double {
        let clamped = min(1, max(0, p))
        return 0.5 - 0.5 * cos(clamped * Double.pi)
    }
}
