import Foundation

/// Style-agnostic spectral-shape features computed over a magnitude profile (see
/// `SpectralDenoise.magnitudeProfile`). Shared by the live per-event gate (`CaptureAnalyzer`, which
/// needs to tell a breath from a keyboard click in real time) and the offline `Grader` (which uses the
/// same centroid/flatness/band-energy formulas for its per-fragment QA stages) — one set of formulas,
/// not two independently-tuned copies.
public enum SpectralFeatures {
    public static func centroid(_ profile: [Float], binHz: Double) -> Double {
        var num = 0.0, den = 0.0
        for (k, m) in profile.enumerated() {
            num += Double(k) * binHz * Double(m)
            den += Double(m)
        }
        return den > 0 ? num / den : 0
    }

    /// Spectral flatness (Wiener entropy): geometric mean / arithmetic mean of the magnitudes, in
    /// [0, 1]. 1 ≈ white/noisy (breath turbulence), → 0 ≈ tonal/harmonic (speech, a resonant click).
    /// Computed over bins with non-trivial magnitude.
    public static func flatness(_ profile: [Float]) -> Double {
        let mags = profile.map { Double($0) }.filter { $0 > 1e-9 }
        guard !mags.isEmpty else { return 0 }
        let logMean = mags.reduce(0) { $0 + log($1) } / Double(mags.count)
        let arithMean = mags.reduce(0, +) / Double(mags.count)
        return arithMean > 0 ? exp(logMean) / arithMean : 0
    }

    public static func bandEnergy(_ profile: [Float], binHz: Double, low: Double, high: Double) -> Double {
        var energy = 0.0
        for (k, m) in profile.enumerated() {
            let hz = Double(k) * binHz
            if hz >= low, hz <= high { energy += Double(m) * Double(m) }
        }
        return energy
    }

    /// Fraction of a profile's total energy that falls in `[low, high]` Hz — 1.0 for a signal
    /// concentrated entirely in the breath band, near 0 for one that isn't.
    public static func bandEnergyRatio(_ profile: [Float], binHz: Double, low: Double, high: Double) -> Double {
        var total = 0.0
        for m in profile { total += Double(m) * Double(m) }
        guard total > 1e-12 else { return 0 }
        return bandEnergy(profile, binHz: binHz, low: low, high: high) / total
    }
}
