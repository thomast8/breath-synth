import BreathEngine
import Foundation

/// Pure per-take derivation shared by the offline `BankBuilder` and the live `LiveTakeGrader`: segment
/// one take's raw samples and compute every per-fragment fact that doesn't depend on sibling context
/// (features, length/dropout/spacing/cadence gates). Sibling comparison (anomaly, cross-take baselines)
/// stays with the caller, since the live and offline sibling sets differ — a live grade sees only takes
/// captured so far this session, an offline build sees the whole session at once.
public enum TakeGrading {
    /// One cut fragment's derived facts, before the sibling-dependent `Grader.grade` verdict.
    public struct FragmentRecord: Sendable {
        public var raw: Segmenter.Raw
        public var features: Grader.Features?
        public var lengthOK: Bool
        public var dropoutOK: Bool
        public var spacingOK: Bool
        public var cadenceOK: Bool
    }

    /// One take's segmentation result: the cache signal (if this role produces one) plus every
    /// fragment's derived facts, and the take-level clipping/length verdicts every fragment shares.
    public struct TakeResult: Sendable {
        public var cacheSignal: [Float]?
        public var records: [FragmentRecord]
        public var clipped: Bool
        public var lengthOK: Bool
    }

    /// Segment `raw` and derive every fragment's sibling-independent facts. `goldCadence` is the gold
    /// reference's gulp-core spacing (packing cadence gate; pass `[]` when not applicable — the cadence
    /// gate then always passes, matching `BankBuilder`'s original "no gold cadence → no rejection" rule).
    public static func gradeTake(
        raw: [Float], role: String, type: BreathType,
        settings: AssemblerSettings, roomToneProfile: [Float]?,
        goldCadence: [Int], minSeconds: Double?, maxSeconds: Double?,
        thresholds: Grader.Thresholds = .default
    ) -> TakeResult {
        let sr = settings.sampleRate
        let clipped = Grader.clippingRun(raw, peak: thresholds.clipPeak, minRun: thresholds.clipRunSamples)
        let durationSec = Double(raw.count) / sr
        let lengthOK = lengthWithinBounds(durationSec, min: minSeconds, max: maxSeconds)
        let minCoreSpacing = Int(thresholds.minCoreSpacingSec * sr)

        let out = Segmenter.segment(
            rawTake: raw, role: role, type: type, settings: settings, roomToneProfile: roomToneProfile
        )

        // Take-level packing cadence vs the gold reference (applies to all this take's cores).
        let takeCoreGaps = out.fragments.filter { $0.kind == .gulpCore }.compactMap(\.gapToNext)
        let cadenceOK = goldCadence.isEmpty || takeCoreGaps.isEmpty
            ? true
            : Grader.rhythmDistance(takeCoreGaps, goldCadence) <= thresholds.maxRhythmDistance

        var records: [FragmentRecord] = []
        for fragment in out.fragments {
            let features: Grader.Features?
            if fragment.kind == .gap {
                features = nil
            } else {
                var f = Grader.features(raw: fragment.audio, sampleRate: sr,
                                        roomToneProfile: roomToneProfile, thresholds: thresholds)
                f.clipped = clipped   // clipping is a take-level verdict, not a fragment one
                features = f
            }
            // Per-kind quality gates the Grader can't see from features alone.
            let dropoutOK = fragment.kind != .oneShotBody
                || !Grader.dropoutRun(BreathAssembler.rmsEnvelope(fragment.audio, sampleRate: sr),
                                      sampleRate: sr, minGapSec: thresholds.dropoutMinGapSec)
            let spacingOK = fragment.kind != .gulpCore
                || (fragment.gapToNext.map { $0 >= minCoreSpacing } ?? true)
            records.append(FragmentRecord(
                raw: fragment, features: features, lengthOK: lengthOK,
                dropoutOK: dropoutOK, spacingOK: spacingOK,
                cadenceOK: fragment.kind == .gulpCore ? cadenceOK : true
            ))
        }
        return TakeResult(cacheSignal: out.cacheSignal, records: records, clipped: clipped, lengthOK: lengthOK)
    }

    static func lengthWithinBounds(_ seconds: Double, min: Double?, max: Double?) -> Bool {
        if let min, seconds < min { return false }
        if let max, seconds > max { return false }
        return true
    }
}
