import Foundation

/// Lightweight post-processing for generated/synthesized clips. Operates on mono
/// Float samples.
enum AudioPostProcess {
    /// Trim leading/trailing samples quieter than `threshold` (linear amplitude).
    static func trimSilence(_ samples: [Float], threshold: Float = 0.005) -> [Float] {
        guard let first = samples.firstIndex(where: { abs($0) > threshold }),
              let last = samples.lastIndex(where: { abs($0) > threshold }) else {
            return samples
        }
        return Array(samples[first...last])
    }

    /// Peak-normalize to `targetDb` dBFS. No-op for silence.
    static func normalize(_ samples: [Float], targetDb: Float = -1) -> [Float] {
        let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
        guard peak > 1e-6 else { return samples }
        let target = pow(10, targetDb / 20)
        let gain = target / peak
        return samples.map { $0 * gain }
    }

    /// Apply a linear fade-in over the first `frames` samples (in place).
    static func fadeIn(_ samples: inout [Float], frames: Int) {
        let n = min(frames, samples.count)
        guard n > 1 else { return }
        for i in 0..<n {
            samples[i] *= Float(i) / Float(n - 1)
        }
    }

    /// Apply a linear fade-out over the last `frames` samples (in place).
    static func fadeOut(_ samples: inout [Float], frames: Int) {
        let n = min(frames, samples.count)
        guard n > 1 else { return }
        let count = samples.count
        for i in 0..<n {
            samples[count - n + i] *= Float(n - 1 - i) / Float(n - 1)
        }
    }
}
