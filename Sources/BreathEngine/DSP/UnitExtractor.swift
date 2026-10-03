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
    /// Min-distance between detected events. Recovery hooks are a double sip that must merge into one
    /// event; packing gulps can follow much faster, so the hybrid path uses a small distance to catch
    /// the true cadence. Real-hardware data (PR #11): one user's own in/out sip gap measured 0.73–0.78s
    /// — right on top of the old 0.70s floor, so the merge succeeded or failed depending on which side
    /// of that boundary a given hook happened to land, undercounting inconsistently. 0.85s clears that
    /// with margin while staying well under an observed real between-breath gap (1.77s) — still leaves
    /// no room for someone who does genuinely back-to-back hooks with almost no gap; there's no single
    /// constant that serves both extremes, so this trades toward the failure mode actually observed.
    public static let hookMinDistSec = 0.85
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
    public static func gulpCores(
        from source: [Float], sampleRate: Double, minDistSec: Double = gulpMinDistSec
    ) -> [[Float]] {
        gulpCoreRanges(from: source, sampleRate: sampleRate, minDistSec: minDistSec)
            .map { declicked(Array(source[$0]), sampleRate: sampleRate) }
    }

    /// The source-frame ranges `gulpCores` slices (before declicking) — the offsets a fragment bank
    /// stores so a core can be re-cut from the cached prepared take. The identity is unconditional:
    /// `gulpCores(...)` is exactly `gulpCoreRanges(...).map { declickedCore(prepared[$0], ...) }`.
    /// A take with no detected events yields the whole-source range (or none when too short).
    /// `minDistSec` defaults to the packing gulp spacing; recovery callers pass `hookMinDistSec` so a
    /// double-sip's in/out halves merge into one event here too, matching `extract`'s existing merge.
    public static func gulpCoreRanges(
        from source: [Float], sampleRate: Double, minDistSec: Double = gulpMinDistSec
    ) -> [Range<Int>] {
        let peaks = detectPeaks(source, sampleRate: sampleRate, minDistSec: minDistSec)
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
    /// Returns `[]` when fewer than two events are found. `minDistSec`: see `gulpCoreRanges`.
    public static func rhythmGaps(
        from source: [Float], sampleRate: Double, minDistSec: Double = gulpMinDistSec
    ) -> [Int] {
        let peaks = detectPeaks(source, sampleRate: sampleRate, minDistSec: minDistSec)
        guard peaks.count >= 2 else { return [] }
        var gaps: [Int] = []
        for i in 1..<peaks.count { gaps.append(max(1, peaks[i] - peaks[i - 1])) }
        return gaps
    }

    // MARK: - Hook parts

    /// One recorded hook breath, split into its two sounds: the quick `inSip` and the louder
    /// `outRelease` about half a second later. Both are declicked so either can be placed alone.
    public struct HookPart: Sendable, Equatable {
        public let inSip: [Float]
        public let outRelease: [Float]
    }

    /// The source-frame ranges `hookParts` slices (before declicking), one pair per `extract` unit.
    public struct HookPartRange: Sendable, Equatable {
        /// From the unit's start to the quietest point between the two sounds. Empty when the unit
        /// has no distinct sip before its release.
        public let inSip: Range<Int>
        /// From just before the release's onset to where it has decayed into the room tone.
        public let outRelease: Range<Int>
    }

    /// Split every hook in a recovery take (the prepared source, as `extract` sees it) into its
    /// in-sip and out-release. Same units as `extract` — `hookMinDistSec` peak-picking merges each
    /// sip/release pair into one event, and that event's peak *is* the release, the louder half —
    /// so `hookParts(...)[i]` is the two halves of `extract(...).units[i]`.
    public static func hookParts(from source: [Float], sampleRate: Double) -> [HookPart] {
        hookPartRanges(from: source, sampleRate: sampleRate).map { range in
            HookPart(
                inSip: range.inSip.count > 4 ? declicked(Array(source[range.inSip]), sampleRate: sampleRate) : [],
                outRelease: declicked(Array(source[range.outRelease]), sampleRate: sampleRate)
            )
        }
    }

    /// See `hookParts`. Each range is clipped to its own unit, so pairs never overlap.
    public static func hookPartRanges(from source: [Float], sampleRate: Double) -> [HookPartRange] {
        let peaks = detectPeaks(source, sampleRate: sampleRate, minDistSec: hookMinDistSec)
        guard !peaks.isEmpty else { return [] }
        // Unit bounds exactly as `extract` cuts them; a single event is its own whole-source unit.
        var bounds: [Int]
        if peaks.count >= 2 {
            var gaps: [Int] = []
            for i in 1..<peaks.count { gaps.append(peaks[i] - peaks[i - 1]) }
            let medianGap = max(1, median(gaps))
            bounds = peaks.map { max(0, $0 - medianGap * 55 / 100) }
            bounds.append(min(source.count, peaks[peaks.count - 1] + medianGap * 45 / 100))
        } else {
            bounds = [0, source.count]
        }

        let (env, window, hop) = energyEnvelope(source, sampleRate: sampleRate)
        guard let globalPeak = env.max(), globalPeak > 0 else { return [] }
        let half = window / 2
        func hopIndex(_ frame: Int) -> Int { min(env.count - 1, max(0, (frame - half) / hop)) }
        func frame(_ hopIndex: Int) -> Int { min(source.count, max(0, hopIndex * hop + half)) }
        // The sip leads the release by ~0.5 s in the reference take; anything closer than this to
        // the release peak is the release's own attack, not a sip.
        let minSipLeadHops = max(1, Int(0.15 * sampleRate) / hop)
        let preRoll = Int(0.03 * sampleRate)
        let tailPad = Int(0.03 * sampleRate)

        var ranges: [HookPartRange] = []
        for i in 0..<peaks.count {
            let lo = bounds[i], hi = bounds[i + 1]
            guard hi - lo > 4 else { continue }
            let loHop = hopIndex(lo), hiHop = hopIndex(hi - 1)
            let releaseHop = hopIndex(peaks[i])
            let releaseLevel = env[releaseHop]
            guard releaseLevel > 0 else { continue }

            // The sip: the loudest point well before the release, if it is a real event (above the
            // same 12%-of-peak floor peak-picking uses).
            var split = lo
            let sipEnd = releaseHop - minSipLeadHops
            if sipEnd > loHop {
                var sipHop = loHop
                for k in loHop...sipEnd where env[k] > env[sipHop] { sipHop = k }
                if env[sipHop] >= globalPeak * 0.12 {
                    // Split at the quietest point between the two: the held, silent instant of the hook.
                    var quiet = sipHop
                    for k in sipHop...releaseHop where env[k] < env[quiet] { quiet = k }
                    split = min(max(lo, frame(quiet)), hi)
                }
            }

            // The release: back from its peak to its onset, forward to where it has decayed into
            // the room tone (5% of its own peak, as `trimToMainBody` gates a one-shot's body).
            let gate = releaseLevel * 0.05
            var onset = releaseHop
            while onset > max(loHop, hopIndex(split)), env[onset - 1] >= gate { onset -= 1 }
            var tail = releaseHop
            while tail < hiHop, env[tail + 1] >= gate { tail += 1 }
            let start = min(max(split, onset * hop - preRoll), hi)
            let end = min(hi, tail * hop + window + tailPad)
            guard end - start > 4 else { continue }
            ranges.append(HookPartRange(inSip: lo..<split, outRelease: start..<end))
        }
        return ranges
    }

    // MARK: - Detection

    /// Detect each event as a prominent local energy maximum (peak-picking), returning peak sample
    /// positions in order. Peak-picking (rather than an absolute threshold) handles events of
    /// varying level; a 0.7 s min-distance, chosen greedily by height, absorbs each event's
    /// secondary attack (a hook's release sip, a gulp's double click) into one peak.
    private static func detectPeaks(_ source: [Float], sampleRate: Double, minDistSec: Double) -> [Int] {
        guard source.count > 1 else { return [] }
        let (env, window, hop) = energyEnvelope(source, sampleRate: sampleRate)
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

    /// The 20 ms-window / 10 ms-hop RMS envelope peak-picking runs on, lightly smoothed (3-point).
    /// Hop `k` covers source frames `k * hop ..< k * hop + window`.
    private static func energyEnvelope(_ source: [Float], sampleRate: Double) -> (env: [Float], window: Int, hop: Int) {
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
        return (env, window, hop)
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
