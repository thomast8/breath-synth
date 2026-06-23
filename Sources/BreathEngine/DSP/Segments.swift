import Foundation

/// Pure segment / loop geometry math. All values are in sample-frames to avoid
/// fractional drift. No AVFoundation here so it is fully unit-testable.
public enum Segments {
    /// Convert seconds to whole sample-frames using consistent rounding.
    public static func frames(seconds: Double, sampleRate: Double) -> Int {
        max(0, Int((seconds * sampleRate).rounded()))
    }

    /// Clamp a requested crossfade length so it fits inside the constraining segments.
    /// A crossfade must be shorter than the loop and shorter than the head/tail it
    /// overlaps.
    public static func clampCrossfade(_ requested: Int, loopLen: Int, startLen: Int, endLen: Int) -> Int {
        let upper = min(loopLen - 1, min(startLen - 1, endLen - 1))
        return max(1, min(requested, upper))
    }

    /// Minimal number of loop iterations whose crossfaded span covers `middleLen`.
    ///
    /// With an equal-power crossfade of `crossfadeLen` frames, each iteration after
    /// the first advances by `stride = loopLen - crossfadeLen`, so
    /// `span(n) = loopLen + (n - 1) * stride`.
    public static func loopIterationCount(middleLen: Int, loopLen: Int, crossfadeLen: Int) -> Int {
        guard loopLen > 0 else { return 0 }
        if middleLen <= loopLen { return 1 }
        let x = max(0, min(crossfadeLen, loopLen - 1))
        let stride = max(1, loopLen - x)
        let n = Int(ceil(Double(middleLen - loopLen) / Double(stride))) + 1
        return max(1, n)
    }

    /// The total span (frames) produced by `iterations` crossfaded loop copies.
    public static func spannedFrames(iterations: Int, loopLen: Int, crossfadeLen: Int) -> Int {
        guard iterations > 0, loopLen > 0 else { return 0 }
        let x = max(0, min(crossfadeLen, loopLen - 1))
        let stride = max(1, loopLen - x)
        return loopLen + (iterations - 1) * stride
    }
}
