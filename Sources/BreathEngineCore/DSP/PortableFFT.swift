import Foundation

/// Pure-Swift iterative radix-2 Cooley-Tukey FFT, used as `SpectralDenoise`'s fallback where
/// Accelerate/vDSP isn't available (Linux). Unconditionally compiled (not just inside the Linux
/// branch) so macOS tests can compare it directly against vDSP for numeric parity.
///
/// Matches vDSP's unnormalized convention on both directions: forward computes
/// `X[k] = sum_n x[n] * exp(-2pi i kn/N)`; inverse computes `sum_k X[k] * exp(+2pi i kn/N)`
/// with NO `1/N` scaling — same as `vDSP_fft_zip`, whose round trip scales the signal by `N`
/// (see `SpectralDenoise`'s own `scale = 1.0 / Float(n)` compensation after its inverse call).
public enum PortableFFT {
    /// In-place complex FFT on split-complex arrays. `n` must be a power of two; `realp`/`imagp`
    /// must each have exactly `n` elements.
    public static func transform(realp: inout [Float], imagp: inout [Float], n: Int, inverse: Bool) {
        precondition(n > 0 && n & (n - 1) == 0, "PortableFFT requires a power-of-two length")
        precondition(realp.count == n && imagp.count == n)

        // Bit-reversal permutation.
        var j = 0
        for i in 1..<n {
            var bit = n >> 1
            while bit > 0, j & bit != 0 {
                j ^= bit
                bit >>= 1
            }
            j ^= bit
            if i < j {
                realp.swapAt(i, j)
                imagp.swapAt(i, j)
            }
        }

        // Iterative Cooley-Tukey butterflies, stage by stage (len = 2, 4, 8, ..., n).
        let sign: Float = inverse ? 1 : -1
        var len = 2
        while len <= n {
            let half = len / 2
            let theta = sign * 2 * Float.pi / Float(len)
            let wr = cos(theta), wi = sin(theta)
            var i = 0
            while i < n {
                var curWr: Float = 1, curWi: Float = 0
                for k in 0..<half {
                    let evenIdx = i + k
                    let oddIdx = evenIdx + half
                    let evenR = realp[evenIdx], evenI = imagp[evenIdx]
                    let oddR = realp[oddIdx], oddI = imagp[oddIdx]
                    let tr = oddR * curWr - oddI * curWi
                    let ti = oddR * curWi + oddI * curWr
                    realp[evenIdx] = evenR + tr
                    imagp[evenIdx] = evenI + ti
                    realp[oddIdx] = evenR - tr
                    imagp[oddIdx] = evenI - ti
                    let nextWr = curWr * wr - curWi * wi
                    let nextWi = curWr * wi + curWi * wr
                    curWr = nextWr
                    curWi = nextWi
                }
                i += len
            }
            len <<= 1
        }
    }
}
