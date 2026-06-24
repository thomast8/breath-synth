import Accelerate
import Foundation

/// FFT noise-profile subtraction (spectral gating) for the recorded breath source.
///
/// The recordings carry a steady broadband hiss (~26 dB SNR) that the single 260 Hz
/// high-pass in `cleanRecordedSource` cannot touch above its corner. This stage estimates
/// that hiss from the quietest moments of the recording (per-bin minimum statistics) and
/// subtracts it from every frame, pushing quiet stretches toward true silence while leaving
/// the breath band (~300-3000 Hz) intact.
///
/// Deterministic: fixed STFT geometry, fixed windows, no RNG. The whole pipeline must stay
/// reproducible so a given seed always renders the same breath.
public enum SpectralDenoise {
    private static let frameSize = 1024 // ~23 ms @ 44.1k
    private static let hop = 256 // 75% overlap
    private static let log2n = vDSP_Length(10) // log2(frameSize)

    /// Spectral-subtract the steady noise floor from `samples`.
    ///
    /// - Parameters:
    ///   - sampleRate: the signal's sample rate; sets the width of the temporal averaging window
    ///     used by the noise estimate.
    ///   - overSubtraction: how many times the estimated per-bin noise to remove (~1.5-2.0).
    ///     Above 1 it over-removes to compensate for the minimum-statistics bias, at the cost
    ///     of "musical noise" if pushed too hard. Clamped to `>= 0`.
    ///   - floorGain: per-bin residual floor as a fraction of the original magnitude
    ///     (~0.03-0.1). Keeping a little of the original suppresses the warbly musical noise
    ///     that hard gating produces. Clamped to `[0, 1]`.
    /// - Returns: the denoised signal, same length as the input.
    public static func denoise(
        _ samples: [Float],
        sampleRate: Double,
        overSubtraction: Float,
        floorGain: Float
    ) -> [Float] {
        let n = frameSize
        guard samples.count > n else { return samples }
        // Clamp to a safe range so out-of-range values (e.g. an unvalidated CLI knob) can't
        // produce negative gains (phase flips) or amplification.
        let overSub = max(0, overSubtraction)
        let floor = min(1, max(0, floorGain))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return samples }
        defer { vDSP_destroy_fftsetup(setup) }

        // Periodic Hann, used for both analysis and synthesis (WOLA). The exact shape is not
        // load-bearing: resynthesis divides by the accumulated per-sample window-overlap sum,
        // so reconstruction is unity-gain for any window/hop by construction.
        var window = [Float](repeating: 0, count: n)
        for i in 0..<n {
            window[i] = 0.5 - 0.5 * cos(2.0 * Float.pi * Float(i) / Float(n))
        }

        // Frames hop across the whole signal; the trailing frame is zero-filled past the end.
        let frameCount = (samples.count - 1) / hop + 1
        let half = n / 2

        // Pass 1: forward-FFT every frame, cache the spectra and the per-frame magnitudes.
        var framesReal = [[Float]]()
        var framesImag = [[Float]]()
        var mags = [[Float]]()
        framesReal.reserveCapacity(frameCount)
        framesImag.reserveCapacity(frameCount)
        mags.reserveCapacity(frameCount)

        var windowed = [Float](repeating: 0, count: n)
        for f in 0..<frameCount {
            let start = f * hop
            for i in 0..<n {
                let idx = start + i
                windowed[i] = (idx < samples.count ? samples[idx] : 0) * window[i]
            }
            var realp = windowed
            var imagp = [Float](repeating: 0, count: n)
            transform(setup, &realp, &imagp, direction: FFTDirection(kFFTDirection_Forward))
            var frameMag = [Float](repeating: 0, count: half + 1)
            for k in 0...half {
                frameMag[k] = (realp[k] * realp[k] + imagp[k] * imagp[k]).squareRoot()
            }
            framesReal.append(realp)
            framesImag.append(imagp)
            mags.append(frameMag)
        }

        // Noise profile = per-bin minimum of a short time-average of the magnitude. Averaging
        // over a window before taking the minimum keeps the estimate near the true steady-state
        // floor; a raw minimum would chase the deep frame-to-frame dips of a fluctuating
        // spectrum and badly under-estimate the hiss. The source's genuine quiet stretches still
        // let the minimum land on noise rather than breath. Smoothed across bins so a single
        // quiet bin can't carve a notch into the breath.
        let temporalWindow = max(1, Int(0.15 * sampleRate / Double(hop)))
        var noise = noiseProfile(mags: mags, bins: half + 1, temporalWindow: temporalWindow)
        noise = smoothedAcrossBins(noise)

        // Pass 2: subtract the noise profile per bin (real gain preserves phase and Hermitian
        // symmetry, so the inverse stays real), inverse-FFT, and overlap-add with the synthesis
        // window. `winSum` accumulates the window-overlap so the final divide is exact unity gain.
        let outLen = (frameCount - 1) * hop + n
        var out = [Float](repeating: 0, count: outLen)
        var winSum = [Float](repeating: 0, count: outLen)
        let scale = 1.0 / Float(n) // vDSP complex FFT round-trip scales by N

        for f in 0..<frameCount {
            var realp = framesReal[f]
            var imagp = framesImag[f]
            for k in 0...half {
                let re = realp[k]
                let im = imagp[k]
                let mag = (re * re + im * im).squareRoot()
                let reduced = max(mag - overSub * noise[k], floor * mag)
                let gain = mag > 1e-9 ? reduced / mag : 0
                realp[k] = re * gain
                imagp[k] = im * gain
                // Mirror the gain onto the conjugate bin (untouched original value) to keep the
                // spectrum Hermitian. k == 0 (DC) and k == half (Nyquist) are self-conjugate.
                if k > 0, k < half {
                    let mk = n - k
                    realp[mk] *= gain
                    imagp[mk] *= gain
                }
            }
            transform(setup, &realp, &imagp, direction: FFTDirection(kFFTDirection_Inverse))
            let start = f * hop
            for i in 0..<n {
                out[start + i] += realp[i] * scale * window[i]
                winSum[start + i] += window[i] * window[i]
            }
        }

        var result = [Float](repeating: 0, count: samples.count)
        for i in 0..<samples.count {
            let w = winSum[i]
            result[i] = w > 1e-6 ? out[i] / w : 0
        }
        return result
    }

    /// In-place complex FFT on split-complex arrays backed by `realp`/`imagp`.
    private static func transform(
        _ setup: FFTSetup,
        _ realp: inout [Float],
        _ imagp: inout [Float],
        direction: FFTDirection
    ) {
        realp.withUnsafeMutableBufferPointer { rp in
            imagp.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                vDSP_fft_zip(setup, &split, 1, log2n, direction)
            }
        }
    }

    /// Per-bin noise estimate: the minimum, over all frames, of a `temporalWindow`-frame moving
    /// average of that bin's magnitude (minimum statistics with temporal smoothing).
    private static func noiseProfile(mags: [[Float]], bins: Int, temporalWindow: Int) -> [Float] {
        let frameCount = mags.count
        var noise = [Float](repeating: 0, count: bins)
        let w = max(1, temporalWindow)
        for k in 0..<bins {
            var minAvg = Float.greatestFiniteMagnitude
            var sum: Float = 0
            for f in 0..<frameCount {
                sum += mags[f][k]
                if f >= w { sum -= mags[f - w][k] }
                // Only weigh full windows so a partial leading window can't under-estimate.
                if f >= w - 1 {
                    let avg = sum / Float(w)
                    if avg < minAvg { minAvg = avg }
                }
            }
            // Fewer frames than the window: fall back to the overall mean for that bin.
            if minAvg == .greatestFiniteMagnitude {
                var total: Float = 0
                for f in 0..<frameCount { total += mags[f][k] }
                minAvg = frameCount > 0 ? total / Float(frameCount) : 0
            }
            noise[k] = minAvg
        }
        return noise
    }

    /// 3-tap moving average across frequency bins (clamped at the edges).
    private static func smoothedAcrossBins(_ values: [Float]) -> [Float] {
        guard values.count > 2 else { return values }
        var out = values
        for i in values.indices {
            let lo = max(0, i - 1)
            let hi = min(values.count - 1, i + 1)
            var sum: Float = 0
            for j in lo...hi { sum += values[j] }
            out[i] = sum / Float(hi - lo + 1)
        }
        return out
    }
}
