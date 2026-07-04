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
}
