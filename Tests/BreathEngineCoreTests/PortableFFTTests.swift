import Testing
import Foundation
#if canImport(Accelerate)
import Accelerate
#endif

@testable import BreathEngineCore

/// Numeric parity between `PortableFFT` (the Linux fallback) and vDSP (the Apple default) — the
/// prerequisite for trusting that `SpectralDenoise`'s Linux path makes the same calls
/// `CaptureAnalyzer`/`Grader`/`TakeGate` already rely on. The actual decision-level proof (that
/// `CaptureAnalyzerTests`'/`GraderTests`' gold-asset assertions still hold) comes from running
/// this same test suite under Linux in Docker (see the plan's Phase 1.5) — once
/// `SpectralDenoise` silently falls back to `PortableFFT` there, every existing spectral-gate and
/// grading test becomes that decision-level fixture for free, so this file only needs to
/// establish the raw numeric parity those decisions are built on.
struct PortableFFTTests {
    private let n = 1_024
    private let log2n = 10

    // MARK: - Round trip (no Accelerate needed — proves PortableFFT is internally consistent)

    @Test
    func testRoundTripReconstructsOriginalSignal() {
        var real = (0..<n).map { _ in Float.random(in: -1...1) }
        let original = real
        var imag = [Float](repeating: 0, count: n)

        PortableFFT.transform(realp: &real, imagp: &imag, n: n, inverse: false)
        PortableFFT.transform(realp: &real, imagp: &imag, n: n, inverse: true)

        // vDSP's unnormalized convention: forward + inverse scales the signal by N.
        for i in 0..<n {
            let reconstructed = real[i] / Float(n)
            #expect(abs(reconstructed - original[i]) < 1e-4, "sample \(i): \(reconstructed) vs \(original[i])")
        }
        // Round trip must stay (numerically) real — negligible imaginary leakage.
        for v in imag { #expect(abs(v) / Float(n) < 1e-4) }
    }

    @Test
    func testForwardOfImpulseIsFlatMagnitudeSpectrum() {
        var real = [Float](repeating: 0, count: n)
        real[0] = 1
        var imag = [Float](repeating: 0, count: n)
        PortableFFT.transform(realp: &real, imagp: &imag, n: n, inverse: false)
        // A unit impulse at sample 0 has a flat magnitude spectrum of exactly 1 at every bin.
        for k in 0..<n {
            let mag = (real[k] * real[k] + imag[k] * imag[k]).squareRoot()
            #expect(abs(mag - 1) < 1e-5, "bin \(k): magnitude \(mag)")
        }
    }

#if canImport(Accelerate)

    // MARK: - Direct vDSP comparison (Apple-only — the actual portability proof for this file)

    private func accelerateTransform(_ realp: inout [Float], _ imagp: inout [Float], inverse: Bool) {
        guard let setup = vDSP_create_fftsetup(vDSP_Length(log2n), FFTRadix(kFFTRadix2)) else {
            Issue.record("vDSP_create_fftsetup failed")
            return
        }
        defer { vDSP_destroy_fftsetup(setup) }
        realp.withUnsafeMutableBufferPointer { rp in
            imagp.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                let direction = inverse ? FFTDirection(kFFTDirection_Inverse) : FFTDirection(kFFTDirection_Forward)
                vDSP_fft_zip(setup, &split, 1, vDSP_Length(log2n), direction)
            }
        }
    }

    private func maxAbsDiff(_ a: [Float], _ b: [Float]) -> Float {
        zip(a, b).map { abs($0 - $1) }.max() ?? 0
    }

    private func randomSignal(seed: UInt64) -> [Float] {
        var rng = SeededRNG(seed: seed)
        return (0..<n).map { _ in Float(Double.random(in: -1...1, using: &rng)) }
    }

    private func toneSignal(freqHz: Double, sampleRate: Double = 44_100) -> [Float] {
        (0..<n).map { i in Float(sin(2 * Double.pi * freqHz * Double(i) / sampleRate)) }
    }

    @Test(arguments: [0, 1, 2])
    func testForwardMatchesAccelerate(seedOffset: Int) throws {
        let signal = seedOffset == 0 ? toneSignal(freqHz: 1_000) : randomSignal(seed: UInt64(seedOffset))

        var portableReal = signal, portableImag = [Float](repeating: 0, count: n)
        PortableFFT.transform(realp: &portableReal, imagp: &portableImag, n: n, inverse: false)

        var accelReal = signal, accelImag = [Float](repeating: 0, count: n)
        accelerateTransform(&accelReal, &accelImag, inverse: false)

        // Both are unnormalized forward DFTs of the same real signal — magnitudes should agree
        // tightly (Float32 accumulation differences between the two algorithms are the only
        // expected source of drift over a 1024-point transform).
        let realDiff = maxAbsDiff(portableReal, accelReal)
        let imagDiff = maxAbsDiff(portableImag, accelImag)
        #expect(realDiff < 0.05, "real part max abs diff \(realDiff)")
        #expect(imagDiff < 0.05, "imag part max abs diff \(imagDiff)")
    }

    @Test
    func testInverseMatchesAccelerate() {
        // Start from a real spectrum (forward of a tone) so the inverse has genuine energy to
        // reconstruct, then compare the two backends' inverse transforms of the same spectrum.
        var real = toneSignal(freqHz: 2_500)
        var imag = [Float](repeating: 0, count: n)
        PortableFFT.transform(realp: &real, imagp: &imag, n: n, inverse: false)

        var portableReal = real, portableImag = imag
        PortableFFT.transform(realp: &portableReal, imagp: &portableImag, n: n, inverse: true)

        var accelReal = real, accelImag = imag
        accelerateTransform(&accelReal, &accelImag, inverse: true)

        let realDiff = maxAbsDiff(portableReal, accelReal)
        let imagDiff = maxAbsDiff(portableImag, accelImag)
        #expect(realDiff < 0.05, "real part max abs diff \(realDiff)")
        #expect(imagDiff < 0.05, "imag part max abs diff \(imagDiff)")
    }

    // MARK: - SpectralDenoise-level parity (what CaptureAnalyzer/Grader actually call)

    @Test
    func testMagnitudeProfileMatchesAcrossBackends() {
        let sr = 44_100.0
        var rng = SeededRNG(seed: 7)
        let signal = (0..<20_000).map { i in
            Float(0.05 * Double.random(in: -1...1, using: &rng) + 0.3 * sin(2 * Double.pi * 1_200 * Double(i) / sr))
        }

        let portable = SpectralDenoise.magnitudeProfileForTesting(from: signal, sampleRate: sr, forcePortable: true)
        let accelerated = SpectralDenoise.magnitudeProfileForTesting(from: signal, sampleRate: sr, forcePortable: false)

        #expect(portable.count == accelerated.count)
        #expect(!portable.isEmpty)
        let diff = maxAbsDiff(portable, accelerated)
        // A profile is a per-frame average over dozens of frames, so backend rounding differences
        // wash out further than a single-frame transform's tolerance above.
        #expect(diff < 0.01, "magnitude profile max abs diff \(diff)")
    }

    @Test
    func testDenoiseMatchesAcrossBackends() {
        let sr = 44_100.0
        var rng = SeededRNG(seed: 9)
        let signal = (0..<20_000).map { i in
            Float(0.05 * Double.random(in: -1...1, using: &rng) + 0.3 * sin(2 * Double.pi * 800 * Double(i) / sr))
        }

        let portable = SpectralDenoise.denoiseForTesting(
            signal, sampleRate: sr, overSubtraction: 1.5, floorGain: 0.05, forcePortable: true)
        let accelerated = SpectralDenoise.denoiseForTesting(
            signal, sampleRate: sr, overSubtraction: 1.5, floorGain: 0.05, forcePortable: false)

        #expect(portable.count == accelerated.count)
        let diff = maxAbsDiff(portable, accelerated)
        #expect(diff < 0.01, "denoised signal max abs diff \(diff)")
    }

#endif
}
