import Foundation

/// Splits a recording of repeated events (recovery hooks, packing gulps) into its real units.
/// Pure, deterministic `[Float]` math (no RNG) so it stays reproducible and unit-testable.
///
/// Two consumers:
/// - `extract` returns adjacent slices (event + natural gap) for the single-source counted path
///   (recovery): concatenating the first N reproduces the recording, with real sound and spacing.
/// - `gulpCores` + `rhythmGaps` feed the hybrid path (packing): clean event cores sampled from one
///   take (the deliberately-separated packs) are laid out at another take's natural rhythm.
public enum UnitExtractor {
    /// Adjacent event segments + detected count. Tiny input or <2 events returns `([source], 1)`.
    /// Min-distance between detected events. Recovery hooks are a double sip ~0.5 s apart that must
    /// merge into one event (0.7 s); packing gulps can follow much faster, so the hybrid path uses a
    /// small distance to catch the true cadence.
    public static let hookMinDistSec = 0.70
    public static let gulpMinDistSec = 0.22

    public static func extract(
        from source: [Float],
        sampleRate: Double
    ) -> (units: [[Float]], count: Int) {
        let peaks = detectPeaks(source, sampleRate: sampleRate, minDistSec: hookMinDistSec)
        guard peaks.count >= 2 else { return ([source], 1) }

        var gaps: [Int] = []
        for i in 1..<peaks.count { gaps.append(peaks[i] - peaks[i - 1]) }
        let medianGap = max(1, median(gaps))

        // Each unit starts a pre-roll before its peak (capturing a leading sub-attack, e.g. a hook's
        // first sip) and ends before the next peak's pre-roll, so units align to whole events.
        let preRoll = medianGap * 55 / 100
        var bounds: [Int] = peaks.map { max(0, $0 - preRoll) }
        bounds.append(min(source.count, peaks[peaks.count - 1] + medianGap * 45 / 100))

        var units: [[Float]] = []
        for i in 0..<(bounds.count - 1) where bounds[i + 1] > bounds[i] {
            units.append(Array(source[bounds[i]..<bounds[i + 1]]))
        }
        guard !units.isEmpty else { return ([source], 1) }
        return (units, units.count)
    }

    /// One clean, declicked core per detected event (the transient plus a short tail), aligned so the
    /// event begins near the start — for placing standalone at an externally-supplied rhythm.
    /// Delegates to `gulpCoreRanges` so the identity a fragment bank relies on holds *by construction*
    /// on every path (detected events, no events, degenerate windows): a bank that stores the ranges
    /// and re-cuts `declickedCore(prepared[range])` reproduces this exactly.
    public static func gulpCores(from source: [Float], sampleRate: Double) -> [[Float]] {
        gulpCoreRanges(from: source, sampleRate: sampleRate)
            .map { declicked(Array(source[$0]), sampleRate: sampleRate) }
    }

    /// The source-frame ranges `gulpCores` slices (before declicking) — the offsets a fragment bank
    /// stores so a core can be re-cut from the cached prepared take. The identity is unconditional:
    /// `gulpCores(...)` is exactly `gulpCoreRanges(...).map { declickedCore(prepared[$0], ...) }`.
    /// A take with no detected events yields the whole-source range (or none when too short).
    public static func gulpCoreRanges(from source: [Float], sampleRate: Double) -> [Range<Int>] {
        let peaks = detectPeaks(source, sampleRate: sampleRate, minDistSec: gulpMinDistSec)
        guard !peaks.isEmpty else { return source.count > 1 ? [0..<source.count] : [] }
        let ranges = coreRanges(forPeaks: peaks, count: source.count, sampleRate: sampleRate)
        return ranges.isEmpty ? (source.count > 1 ? [0..<source.count] : []) : ranges
    }

    /// Declick a re-cut core (short raised-cosine fade-in/out + zeroed endpoints) so it is click-free
    /// when placed in silence. Public so a fragment bank reproduces the engine's exact core audio.
    public static func declickedCore(_ samples: [Float], sampleRate: Double) -> [Float] {
        declicked(samples, sampleRate: sampleRate)
    }

    /// The `[pre-roll, post-tail]` window around each detected event, clipped to the source bounds.
    private static func coreRanges(forPeaks peaks: [Int], count: Int, sampleRate: Double) -> [Range<Int>] {
        let pre = Int(0.08 * sampleRate)
        let post = Int(0.35 * sampleRate)
        var ranges: [Range<Int>] = []
        for p in peaks {
            let lo = max(0, p - pre)
            let hi = min(count, p + post)
            if hi - lo > 4 { ranges.append(lo..<hi) }
        }
        return ranges
    }

    /// The inter-onset gaps (in samples) between detected events — the recording's natural rhythm.
    /// Returns `[]` when fewer than two events are found.
    public static func rhythmGaps(from source: [Float], sampleRate: Double) -> [Int] {
        let peaks = detectPeaks(source, sampleRate: sampleRate, minDistSec: gulpMinDistSec)
        guard peaks.count >= 2 else { return [] }
        var gaps: [Int] = []
        for i in 1..<peaks.count { gaps.append(max(1, peaks[i] - peaks[i - 1])) }
        return gaps
    }

    // MARK: - Detection

    /// Detect each event as a prominent local energy maximum (peak-picking), returning peak sample
    /// positions in order. Peak-picking (rather than an absolute threshold) handles events of
    /// varying level; a 0.7 s min-distance, chosen greedily by height, absorbs each event's
    /// secondary attack (a hook's release sip, a gulp's double click) into one peak.
    private static func detectPeaks(_ source: [Float], sampleRate: Double, minDistSec: Double) -> [Int] {
        guard source.count > 1 else { return [] }
        let window = max(1, Int(0.020 * sampleRate))
        let hop = max(1, Int(0.010 * sampleRate))
        var env: [Float] = []
        var s = 0
        while s < source.count {
            let end = min(source.count, s + window)
            var sum = 0.0
            for i in s..<end { let v = Double(source[i]); sum += v * v }
            env.append(Float(sqrt(sum / Double(end - s))))
            s += hop
        }
        if env.count > 2 {
            var sm = env
            for i in 1..<(env.count - 1) { sm[i] = (env[i - 1] + env[i] + env[i + 1]) / 3 }
            env = sm
        }
        guard let peak = env.max(), peak > 0, env.count >= 3 else { return [] }

        let floor = peak * 0.12
        let minDistHops = max(1, Int(minDistSec * sampleRate) / hop)
        var candidates: [Int] = []
        for i in 1..<(env.count - 1) where env[i] >= floor && env[i] >= env[i - 1] && env[i] >= env[i + 1] {
            candidates.append(i)
        }
        candidates.sort { env[$0] > env[$1] }
        var chosen: [Int] = []
        for c in candidates where chosen.allSatisfy({ abs($0 - c) >= minDistHops }) {
            chosen.append(c)
        }
        chosen.sort()
        let half = window / 2
        return chosen.map { min(source.count - 1, $0 * hop + half) }
    }

    /// Short fade-in/out + zeroed endpoints so a standalone core is click-free when placed in silence.
    private static func declicked(_ samples: [Float], sampleRate: Double) -> [Float] {
        guard samples.count > 4 else { return samples }
        var out = samples
        let inFade = min(max(1, Int(0.004 * sampleRate)), out.count / 2)
        let outFade = min(max(1, Int(0.015 * sampleRate)), out.count / 2)
        for i in 0..<inFade { out[i] *= 0.5 - 0.5 * cos(Float.pi * Float(i) / Float(inFade)) }
        for i in 0..<outFade { out[out.count - 1 - i] *= 0.5 - 0.5 * cos(Float.pi * Float(i) / Float(outFade)) }
        out[0] = 0
        out[out.count - 1] = 0
        return out
    }

    private static func median(_ values: [Int]) -> Int {
        guard !values.isEmpty else { return 0 }
        let s = values.sorted()
        let m = s.count / 2
        return s.count % 2 == 0 ? (s[m - 1] + s[m]) / 2 : s[m]
    }
}
