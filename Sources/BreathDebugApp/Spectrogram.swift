import Accelerate
import CoreGraphics
import Foundation

/// STFT spectrogram + spectral-flux transient detection for the debug app. A glottal stop / click is
/// an impulsive, broadband event: it shows here as a bright vertical streak and as a spectral-flux
/// peak (`transients`), where in the waveform/envelope it can hide as a tiny bump.
enum Spectrogram {
    struct Result {
        var image: CGImage?
        /// Transient onset positions as fractions 0...1 of the buffer (spectral-flux peaks).
        var transients: [Double]
    }

    /// Analyse `samples` into a heat-mapped spectrogram (low frequency at the bottom) plus the
    /// positions of impulsive onsets. `fftSize` must be a power of two. `hop` is widened for long
    /// buffers so the work and image width stay bounded.
    static func analyze(
        _ samples: [Float],
        sampleRate: Double,
        fftSize: Int = 1024,
        baseHop: Int = 256,
        maxFrequency: Double = 10_000,
        maxColumns: Int = 2000
    ) -> Result {
        guard samples.count >= fftSize, sampleRate > 0 else { return Result(image: nil, transients: []) }
        let hop = max(baseHop, samples.count / maxColumns)
        let log2n = vDSP_Length(log2(Double(fftSize)).rounded())
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            return Result(image: nil, transients: [])
        }
        defer { vDSP_destroy_fftsetup(setup) }

        let half = fftSize / 2
        let frameCount = (samples.count - fftSize) / hop + 1
        guard frameCount > 1 else { return Result(image: nil, transients: []) }

        var window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))

        var mags = [Float](repeating: 0, count: frameCount * half)   // linear magnitude, [frame*half + bin]
        var windowed = [Float](repeating: 0, count: fftSize)
        var realp = [Float](repeating: 0, count: half)
        var imagp = [Float](repeating: 0, count: half)

        samples.withUnsafeBufferPointer { src in
            mags.withUnsafeMutableBufferPointer { magsPtr in
                for f in 0..<frameCount {
                    let start = f * hop
                    vDSP_vmul(src.baseAddress! + start, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))
                    realp.withUnsafeMutableBufferPointer { rp in
                        imagp.withUnsafeMutableBufferPointer { ip in
                            var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                            windowed.withUnsafeBufferPointer { wp in
                                wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { cp in
                                    vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(half))
                                }
                            }
                            vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                            vDSP_zvabs(&split, 1, magsPtr.baseAddress! + f * half, 1, vDSP_Length(half))
                        }
                    }
                }
            }
        }

        let maxBin = max(1, min(half, Int(maxFrequency / sampleRate * Double(fftSize))))
        let maxMag = max(mags.max() ?? 0, 1e-9)
        let image = buildImage(mags: mags, frameCount: frameCount, half: half, maxBin: maxBin, maxMag: maxMag)
        let transients = detectTransients(
            mags: mags, frameCount: frameCount, half: half,
            hop: hop, fftSize: fftSize, sampleRate: sampleRate, totalFrames: samples.count
        )
        return Result(image: image, transients: transients)
    }

    private static func buildImage(mags: [Float], frameCount: Int, half: Int, maxBin: Int, maxMag: Float) -> CGImage? {
        let width = frameCount, height = maxBin
        guard width > 0, height > 0 else { return nil }
        let floorDb: Float = -80
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for f in 0..<frameCount {
            for b in 0..<maxBin {
                let db = 20 * log10(max(mags[f * half + b], 1e-9) / maxMag)    // <= 0
                let t = max(0, min(1, (db - floorDb) / -floorDb))              // 0 at floor, 1 at max
                let (r, g, blue) = heat(t)
                let row = height - 1 - b                                       // low frequency at bottom
                let idx = (row * width + f) * 4
                pixels[idx] = r; pixels[idx + 1] = g; pixels[idx + 2] = blue; pixels[idx + 3] = 255
            }
        }
        return pixels.withUnsafeMutableBytes { raw -> CGImage? in
            guard let ctx = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            return ctx.makeImage()
        }
    }

    /// Black → red → yellow → white heat ramp, so quiet is dark and energy is bright.
    private static func heat(_ t: Float) -> (UInt8, UInt8, UInt8) {
        let r: Float, g: Float, b: Float
        if t < 0.33 { r = t / 0.33; g = 0; b = 0 }
        else if t < 0.66 { r = 1; g = (t - 0.33) / 0.33; b = 0 }
        else { r = 1; g = 1; b = (t - 0.66) / 0.34 }
        func byte(_ x: Float) -> UInt8 { UInt8(max(0, min(1, x)) * 255) }
        return (byte(r), byte(g), byte(b))
    }

    private static func detectTransients(
        mags: [Float], frameCount: Int, half: Int,
        hop: Int, fftSize: Int, sampleRate: Double, totalFrames: Int
    ) -> [Double] {
        guard frameCount > 2 else { return [] }
        var flux = [Float](repeating: 0, count: frameCount)
        for f in 1..<frameCount {
            var sum: Float = 0
            for b in 0..<half {
                let delta = mags[f * half + b] - mags[(f - 1) * half + b]
                if delta > 0 { sum += delta }
            }
            flux[f] = sum
        }
        let maxFlux = flux.max() ?? 0
        guard maxFlux > 0 else { return [] }
        let threshold = maxFlux * 0.35
        let minSpacing = max(1, Int(0.08 * sampleRate / Double(hop)))   // ≥ 80 ms apart, in STFT frames
        var peaks: [Int] = []
        for f in 1..<(frameCount - 1) where flux[f] >= threshold && flux[f] >= flux[f - 1] && flux[f] >= flux[f + 1] {
            if let last = peaks.last, f - last < minSpacing {
                if flux[f] > flux[last] { peaks[peaks.count - 1] = f }
            } else {
                peaks.append(f)
            }
        }
        return peaks.map { Double($0 * hop + fftSize / 2) / Double(totalFrames) }
    }
}
