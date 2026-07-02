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

    /// Build a sustain of exactly `targetLen` frames from a `texture` slice.
    ///
    /// When `targetLen <= texture.count` a single (trimmed) window is returned - no
    /// looping, so short breaths are seam-free. Otherwise the body is filled with
    /// overlapping grains of `grainLen` frames pulled from *random* offsets across the
    /// texture (drawn from `rng`) and equal-power crossfaded. Random offsets mean the
    /// output never settles into the fixed-period repeat that looping the whole texture
    /// produces - the audible "wobble" on long breaths - while still drawing only on
    /// the real recorded timbre. Seeded `rng` keeps renders reproducible.
    public static func assembleTexturedLoop(
        texture: [Float],
        targetLen: Int,
        grainLen: Int,
        crossfadeLen: Int,
        rng: inout SeededRNG
    ) -> [Float] {
        guard !texture.isEmpty, targetLen > 0 else {
            return [Float](repeating: 0, count: max(0, targetLen))
        }
        if targetLen <= texture.count {
            return Array(texture[0..<targetLen])
        }
        let grain = max(2, min(grainLen, texture.count))
        let x = max(0, min(crossfadeLen, grain - 1))
        let stride = max(1, grain - x)
        let maxOffset = texture.count - grain

        var out = [Float](repeating: 0, count: targetLen)
        var pos = 0
        var k = 0
        while pos < targetLen {
            let offset = maxOffset > 0 ? Int.random(in: 0...maxOffset, using: &rng) : 0
            let grainSamples = Array(texture[offset..<offset + grain])
            place(into: &out, segment: grainSamples, at: pos, headCrossfade: k == 0 ? 0 : x)
            pos += stride
            k += 1
        }
        return out
    }

    /// Build a sustain of exactly `targetLen` frames by drawing grains from a *pool* of pre-cut
    /// texture windows (one per slot, seeded), instead of random offsets into a single texture.
    /// This is the cross-take variant of `assembleTexturedLoop`: the pool spans grains from every
    /// accepted take, so even one long breath mixes genuinely different material — and a given seed
    /// always draws the same grain succession, so cycles re-seed to decorrelate reproducibly.
    /// Grains are expected to be ~`grainLen` long; an over-long grain is trimmed. An empty pool
    /// yields silence.
    public static func assembleTexturedFromPool(
        grains: [[Float]],
        targetLen: Int,
        grainLen: Int,
        crossfadeLen: Int,
        rng: inout SeededRNG
    ) -> [Float] {
        let pool = grains.filter { !$0.isEmpty }
        guard !pool.isEmpty, targetLen > 0 else {
            return [Float](repeating: 0, count: max(0, targetLen))
        }
        let grain = max(2, grainLen)
        let x = max(0, min(crossfadeLen, grain - 1))

        var out = [Float](repeating: 0, count: targetLen)
        var pos = 0
        var k = 0
        while pos < targetLen {
            var pick = pool[Int.random(in: 0..<pool.count, using: &rng)]
            if pick.count > grain { pick = Array(pick[0..<grain]) }
            place(into: &out, segment: pick, at: pos, headCrossfade: k == 0 ? 0 : x)
            // Advance by the *actually placed* length minus the overlap, not a fixed nominal stride, so
            // a pooled grain shorter than the nominal grain can't leave a silent gap before the next one
            // (mirrors `assembleTexturedLoop`'s contiguity for its single, exactly-sized texture).
            pos += max(1, pick.count - x)
            k += 1
        }
        return out
    }
}
