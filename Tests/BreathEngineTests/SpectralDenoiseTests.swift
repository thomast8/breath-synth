import XCTest
@testable import BreathEngine

/// Coverage for the externally-supplied noise-profile path: a room-tone profile measured
/// from a separate (same-distribution) noise buffer via `SpectralDenoise.magnitudeProfile`,
/// then fed back into `denoise(..., noiseProfile:)`. The existing `SpectralDenoiseTests`
/// class (in BreathEngineTests.swift) covers the internal minimum-statistics estimate.
final class SpectralDenoiseProfileTests: XCTestCase {
    func testSuppliedProfileReducesNoiseRMS() {
        let sr = 16_000.0
        let n = 64_000

        // Two independent draws from the same uniform noise distribution: one is the signal
        // to clean, the other is the "room-tone" recording the profile is measured from.
        let signal = seededNoise(count: n, seed: 11, amplitude: 0.08)
        let profileSource = seededNoise(count: n, seed: 22, amplitude: 0.08)

        let profile = SpectralDenoise.magnitudeProfile(from: profileSource, sampleRate: sr)
        XCTAssertEqual(profile.count, 1024 / 2 + 1, "profile should be one value per analysis bin")
        XCTAssertGreaterThan(profile.reduce(0, +), 0, "profile should capture real noise energy")

        let out = SpectralDenoise.denoise(
            signal, sampleRate: sr, overSubtraction: 1.5, floorGain: 0.05, noiseProfile: profile
        )

        let before = rms(signal)
        let after = rms(out)
        XCTAssertGreaterThan(before, 0)
        XCTAssertLessThan(after / before, 0.8, "supplied profile should materially cut noise RMS (\(after) vs \(before))")
    }

    func testSuppliedProfilePreservesTone() {
        let sr = 16_000.0
        let n = 64_000

        // A strong 1 kHz tone over broadband noise; the profile is measured from a separate
        // noise-only buffer of the same distribution.
        let noiseOnly = seededNoise(count: n, seed: 33, amplitude: 0.06)
        var signal = seededNoise(count: n, seed: 44, amplitude: 0.06)
        for i in 0..<n {
            signal[i] += Float(0.4 * sin(2 * Double.pi * 1_000 * Double(i) / sr))
        }

        let profile = SpectralDenoise.magnitudeProfile(from: noiseOnly, sampleRate: sr)
        let out = SpectralDenoise.denoise(
            signal, sampleRate: sr, overSubtraction: 1.5, floorGain: 0.05, noiseProfile: profile
        )

        // 1.0 s probe window (== sr samples) so the 1 kHz probe lands on a DFT bin centre.
        let win = 16_000..<(16_000 + Int(sr))
        let toneBefore = goertzelMagnitude(Array(signal[win]), sampleRate: sr, frequency: 1_000)
        let toneAfter = goertzelMagnitude(Array(out[win]), sampleRate: sr, frequency: 1_000)
        XCTAssertGreaterThan(toneBefore, 0)
        XCTAssertGreaterThan(toneAfter / toneBefore, 0.6, "tone bin should be largely preserved (\(toneAfter) vs \(toneBefore))")
    }

    // MARK: - Helpers (private to this file)

    private func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sum = samples.reduce(Float(0)) { $0 + $1 * $1 }
        return sqrt(sum / Float(samples.count))
    }

    private func seededNoise(count: Int, seed: UInt64, amplitude: Float) -> [Float] {
        var rng = SeededRNG(seed: seed)
        return (0..<count).map { _ in
            let unit = Double(rng.next()) / Double(UInt64.max)
            return Float(unit * 2 - 1) * amplitude
        }
    }

    private func goertzelMagnitude(_ samples: [Float], sampleRate: Double, frequency: Double) -> Double {
        guard samples.count > 1 else { return 0 }
        let omega = 2 * Double.pi * frequency / sampleRate
        let coeff = 2 * cos(omega)
        var s1 = 0.0
        var s2 = 0.0
        for sample in samples {
            let s0 = Double(sample) + coeff * s1 - s2
            s2 = s1
            s1 = s0
        }
        let power = s1 * s1 + s2 * s2 - coeff * s1 * s2
        return sqrt(max(0, power)) / Double(samples.count)
    }
}
