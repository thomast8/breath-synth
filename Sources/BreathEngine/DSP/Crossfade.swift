import Foundation

/// Pure equal-power crossfade helpers and buffer placement. No AVFoundation.
public enum Crossfade {
    /// Equal-power fade-in curve of `length` samples: 0 → 1 following sin(t·π/2).
    public static func fadeIn(_ length: Int) -> [Float] {
        guard length > 0 else { return [] }
        if length == 1 { return [1] }
        return (0..<length).map { i in
            let t = Float(i) / Float(length - 1)
            return sin(t * .pi / 2)
        }
    }

    /// Equal-power fade-out curve of `length` samples: 1 → 0 following cos(t·π/2).
    public static func fadeOut(_ length: Int) -> [Float] {
        guard length > 0 else { return [] }
        if length == 1 { return [0] }
        return (0..<length).map { i in
            let t = Float(i) / Float(length - 1)
            return cos(t * .pi / 2)
        }
    }

    /// Place `segment` into `out` starting at `offset`. The first `headCrossfade`
    /// samples of `segment` are equal-power crossfaded with whatever already exists
    /// in `out` (existing content faded out, incoming faded in); the remainder is
    /// summed in. Samples outside `out`'s bounds are ignored.
    ///
    /// Callers arrange offsets so the post-crossfade region lands on silence, which
    /// makes the summation equivalent to assignment there.
    public static func place(into out: inout [Float], segment: [Float], at offset: Int, headCrossfade: Int) {
        guard !segment.isEmpty else { return }
        let head = max(0, min(headCrossfade, segment.count))
        let fIn = head > 0 ? fadeIn(head) : []
        let fOut = head > 0 ? fadeOut(head) : []
        let count = out.count
        for j in 0..<segment.count {
            let idx = offset + j
            guard idx >= 0, idx < count else { continue }
            if j < head {
                out[idx] = out[idx] * fOut[j] + segment[j] * fIn[j]
            } else {
                out[idx] += segment[j]
            }
        }
    }

    /// Build a looped sustain of exactly `targetLen` frames from a seamless `loop`
    /// texture, using equal-power crossfades of `crossfadeLen` frames between copies.
    /// When `targetLen <= loop.count` a single (trimmed) window is returned.
    public static func assembleLoopedMiddle(loop: [Float], targetLen: Int, crossfadeLen: Int) -> [Float] {
        guard !loop.isEmpty, targetLen > 0 else {
            return [Float](repeating: 0, count: max(0, targetLen))
        }
        let loopLen = loop.count
        if targetLen <= loopLen {
            return Array(loop[0..<targetLen])
        }
        let x = max(0, min(crossfadeLen, loopLen - 1))
        let stride = max(1, loopLen - x)
        let n = Segments.loopIterationCount(middleLen: targetLen, loopLen: loopLen, crossfadeLen: x)
        let span = Segments.spannedFrames(iterations: n, loopLen: loopLen, crossfadeLen: x)
        var out = [Float](repeating: 0, count: span)
        for k in 0..<n {
            place(into: &out, segment: loop, at: k * stride, headCrossfade: k == 0 ? 0 : x)
        }
        if out.count > targetLen {
            out = Array(out[0..<targetLen])
        } else if out.count < targetLen {
            out += [Float](repeating: 0, count: targetLen - out.count)
        }
        return out
    }
}
