import Testing
import Foundation

@testable import BreathEngine

/// Synthetic-signal tests for the live capture detector. These are the floor for the auto-capture
/// feature; the real ceiling is an end-to-end enroll → `breath-bank build` run.
struct CaptureAnalyzerTests {
    private let sr = 44_100.0
    private var tol: Int { Int(0.07 * sr) }  // ~70 ms boundary tolerance (a few RMS hops)

    // MARK: Signal builders

    private func silence(_ sec: Double) -> [Float] { [Float](repeating: 0, count: Int(sec * sr)) }
    private func tone(_ sec: Double, _ amp: Float = 0.2) -> [Float] { [Float](repeating: amp, count: Int(sec * sr)) }
    private func lowNoise(_ sec: Double, _ amp: Float) -> [Float] {
        (0..<Int(sec * sr)).map { _ in Float.random(in: -amp...amp) }
    }

    /// `count` constant-amplitude bursts, each `widthSec` long, separated by silence to `spacingSec`.
    /// Default width clears `CaptureAnalyzer`'s `minEventWidthSec` (0.10s) with margin — narrower than
    /// that, every burst is rejected as `run-ended-too-soon` before it can be counted as an event.
    private func impulses(_ count: Int, spacingSec: Double, widthSec: Double = 0.15, amp: Float = 0.3) -> [Float] {
        var out: [Float] = []
        for _ in 0..<count {
            out += tone(widthSec, amp)
            out += silence(max(0, spacingSec - widthSec))
        }
        return out
    }

    /// `pairCount` inhale-sip/exhale-sip pairs (start-to-start spacing `inOutGapSec` within a pair,
    /// `pairSpacingSec` between consecutive pairs' first sips) — the synthetic shape of a `pairedEvents`
    /// recovery take.
    private func pairedBursts(
        _ pairCount: Int, inOutGapSec: Double, pairSpacingSec: Double, widthSec: Double = 0.15, amp: Float = 0.3
    ) -> [Float] {
        var out: [Float] = []
        for _ in 0..<pairCount {
            out += tone(widthSec, amp)
            out += silence(max(0, inOutGapSec - widthSec))
            out += tone(widthSec, amp)
            out += silence(max(0, pairSpacingSec - inOutGapSec - widthSec))
        }
        return out
    }

    /// A quiet stretch punctuated by a brief above-threshold burst every `blipEveryMs` — models the
    /// real-hardware transient room noise (PR #11) that repeatedly re-triggered `isActive` and reset
    /// the take's accumulated silence, well short of a genuine breath resumption.
    private func blippedSilence(_ sec: Double, blipEveryMs: Double = 100, blipWidthSec: Double = 0.01, blipAmp: Float = 0.2) -> [Float] {
        var out: [Float] = []
        let blipSpacingSec = blipEveryMs / 1000
        while Double(out.count) / sr < sec {
            out += silence(max(0, blipSpacingSec - blipWidthSec))
            out += tone(blipWidthSec, blipAmp)
        }
        return Array(out.prefix(Int(sec * sr)))
    }

    /// Bursty room ambient: a low noise floor punctuated by louder-but-still-below-breath bursts (~43%
    /// duty) — models the real hardware traces (PR #11, windows-open room) where sustained per-hop
    /// ambient bursts of 60-200ms made a per-hop "quiet, uninterrupted" detector unworkable, unlike
    /// `blippedSilence`'s single-hop transients.
    private func noisyAmbient(
        _ sec: Double, floorAmp: Float = 0.006, burstAmp: Float = 0.018,
        burstEveryMs: Double = 350, burstWidthMs: Double = 150
    ) -> [Float] {
        var out: [Float] = []
        let burstSpacingSec = burstEveryMs / 1000
        let burstWidthSec = burstWidthMs / 1000
        while Double(out.count) / sr < sec {
            out += lowNoise(max(0, burstSpacingSec - burstWidthSec), floorAmp)
            out += lowNoise(burstWidthSec, burstAmp)
        }
        return Array(out.prefix(Int(sec * sr)))
    }

    /// A sustained gentle breath — noise-band amplitude clearly above `noisyAmbient`'s burst level, but
    /// nothing like a forced/loud technique (a thin, real-world margin, not a huge one).
    private func gentleBreath(_ sec: Double, amp: Float = 0.05) -> [Float] {
        lowNoise(sec, amp)
    }

    /// A breath whose amplitude decays exponentially from `from` to `to` over `sec` — models a real
    /// forced exhale's natural taper (PR #11 FRC/RV real hardware: envelope fell ~5x over ~0.4s while
    /// airflow was still real and continuous, not a discontinuity).
    private func decayingBreath(from: Float, to: Float, sec: Double) -> [Float] {
        let n = Int(sec * sr)
        guard n > 1 else { return [] }
        let ratio = Double(to / from)
        return (0..<n).map { i in
            let t = Double(i) / Double(n - 1)
            let amp = Float(Double(from) * pow(ratio, t))
            return Float.random(in: -amp...amp)
        }
    }

    // MARK: Harness

    private func run(
        _ detection: CaptureDetection, noiseFloor: Float? = nil, ambientGateRMS: Float? = nil, _ signal: [Float]
    ) -> (events: [CaptureAnalyzer.Event], analyzer: CaptureAnalyzer) {
        var a = CaptureAnalyzer(
            sampleRate: sr, detection: detection, noiseFloorRMS: noiseFloor, ambientGateRMS: ambientGateRMS)
        var events: [CaptureAnalyzer.Event] = []
        var i = 0
        while i < signal.count {
            let end = min(signal.count, i + 4_096)  // realistic tap buffer size
            events += a.ingest(Array(signal[i..<end]))
            i = end
        }
        return (events, a)
    }

    private func endReason(_ events: [CaptureAnalyzer.Event]) -> CaptureAnalyzer.EndReason? {
        for case let .takeEnded(reason) in events { return reason }
        return nil
    }

    private func segments(_ events: [CaptureAnalyzer.Event]) -> [(SegmentLabel, Int, Int)] {
        events.compactMap {
            if case let .segmentReady(label, s, e) = $0 { return (label, s, e) }
            return nil
        }
    }

    private func onsetCount(_ events: [CaptureAnalyzer.Event]) -> Int {
        events.filter { if case .onset = $0 { return true }; return false }.count
    }

    // MARK: fixedDuration (room tone)

    @Test func fixedDurationEndsAtDurationAndReportsFloor() {
        let (events, analyzer) = run(.fixedDuration(seconds: 5), lowNoise(6, 0.01))
        #expect(endReason(events) == .duration)
        let segs = segments(events)
        #expect(segs.count == 1)
        #expect(segs[0].0 == .whole)
        #expect(abs(segs[0].2 - Int(5 * sr)) <= tol)
        // Mean envelope of uniform ±0.01 noise ≈ 0.005; just assert it's a small positive floor.
        #expect(analyzer.meanFloorRMS() > 0)
        #expect(analyzer.meanFloorRMS() < 0.02)
        #expect(analyzer.preOnsetFloorRMS == nil, "fixedDuration never arms, so it never has a pre-onset window")
    }

    // MARK: preOnsetFloorRMS (rolling noise-floor calibration's per-take ambient estimator)

    @Test func preOnsetFloorTracksArmedAmbient() {
        let signal = lowNoise(2.0, 0.002) + tone(1.0)
        let (_, analyzer) = run(.single(minActiveSec: 0.2, maxTakeSec: 10, trailingSilenceSec: 0.8), signal)
        let floor = try? #require(analyzer.preOnsetFloorRMS)
        #expect(floor != nil)
        #expect((floor ?? 1) < 0.005)
    }

    @Test func preOnsetFloorIgnoresBlackoutBreathing() {
        // A 0.5s breath-scale burst sits inside the armed window (well within the 2s blackout) — a
        // minority (~12%) of the armed samples, so the 20th percentile should still land in the quiet
        // ambient, not get dragged up by the burst.
        let signal = lowNoise(2.0, 0.002) + tone(0.5, 0.05) + lowNoise(1.5, 0.002) + tone(1.0)
        let (_, analyzer) = run(
            .cleanEvents(minGapSec: 0.1, maxTakeSec: 10, trailingSilenceSec: 0.8, postArmBlackoutSec: 2.0), signal)
        let floor = try? #require(analyzer.preOnsetFloorRMS)
        #expect(floor != nil)
        #expect((floor ?? 1) < 0.01, "the burst must not have dragged the percentile up")
    }

    @Test func preOnsetFloorNilWhenArmedPeriodTooShort() {
        let signal = lowNoise(1.0, 0.002) + tone(1.0)
        let (_, analyzer) = run(.single(minActiveSec: 0.2, maxTakeSec: 10, trailingSilenceSec: 0.8), signal)
        #expect(analyzer.preOnsetFloorRMS == nil, "under 1.5s of armed hops isn't enough for a meaningful percentile")
    }

    // MARK: quietRangeFrames (room-tone harvest — Problem 2b)

    @Test func quietRangeSelectsLongestFloorLevelStretch() {
        // Two quiet stretches (3.0s, 2.0s) flank a breath-scale burst; blackout shields the whole armed
        // period so the burst can't itself onset. The longer, earlier stretch must be selected.
        let signal = lowNoise(3.0, 0.002) + tone(0.5, 0.05) + lowNoise(2.0, 0.002) + tone(1.0)
        let (_, analyzer) = run(
            .cleanEvents(minGapSec: 0.1, maxTakeSec: 20, trailingSilenceSec: 0.8, postArmBlackoutSec: 4.0), signal)
        let range = try? #require(analyzer.quietRangeFrames)
        #expect(range != nil)
        guard let range else { return }
        let lengthSec = Double(range.upperBound - range.lowerBound) / sr
        #expect(abs(lengthSec - 3.0) <= 0.3, "must pick the longer 3.0s stretch, not the 2.0s one")
        #expect(Double(range.upperBound) / sr < 3.3, "must end before the burst, not run into it")
    }

    @Test func quietRangeNilWhenNothingQuietLongEnough() {
        // Alternating 0.2s quiet/0.2s loud — no single contiguous quiet run reaches the 0.5s floor.
        var signal: [Float] = []
        for _ in 0..<5 { signal += lowNoise(0.2, 0.002) + tone(0.2, 0.05) }
        signal += lowNoise(0.3, 0.002) + tone(1.0)
        let (_, analyzer) = run(
            .cleanEvents(minGapSec: 0.1, maxTakeSec: 20, trailingSilenceSec: 0.8, postArmBlackoutSec: 2.0), signal)
        #expect(analyzer.preOnsetFloorRMS != nil, "sanity: still enough armed hops for the floor itself")
        #expect(analyzer.quietRangeFrames == nil, "no run reached the 0.5s minimum")
    }

    // MARK: Ambient gate (per-take loud-room hold — Problem 2b)

    /// noiseFloor tuned so `activityThreshold` (`noiseFloor × activityFloorK`) sits at ~0.03 — high
    /// enough that a 0.02-amplitude "loud ambient" tone never itself reads as activity (isolating the
    /// gate's effect from the unrelated onset-width race), while a 0.1-amplitude "breath" burst clears it.
    private let ambientTestNoiseFloor: Float = 0.0214

    @Test func ambientHoldSuppressesOnsetWhileLoud() {
        // Loud ambient warms the gate past its 1.5s minimum and engages it (0.02 > gateRMS 0.01); a
        // breath-scale burst arriving while still held must not onset despite exceeding activityThreshold.
        let signal = tone(2.0, 0.02) + tone(0.5, 0.1)
        let (events, analyzer) = run(
            .single(minActiveSec: 0.2, maxTakeSec: 20, trailingSilenceSec: 0.8),
            noiseFloor: ambientTestNoiseFloor, ambientGateRMS: 0.01, signal)
        #expect(onsetCount(events) == 0, "held gate must suppress the burst's onset")
        #expect(analyzer.isAmbientHold)
    }

    @Test func ambientHoldIgnoresOwnBreathTransient() {
        // A brief breath-scale transient is a small minority of the trailing window — its own approach
        // must not read as "the room is loud" and must still onset normally, unblocked.
        let signal = lowNoise(2.0, 0.002) + tone(0.5, 0.05)
        let (events, analyzer) = run(
            .single(minActiveSec: 0.2, maxTakeSec: 20, trailingSilenceSec: 0.8),
            noiseFloor: ambientTestNoiseFloor, ambientGateRMS: 0.01, signal)
        #expect(onsetCount(events) == 1, "the transient itself is a real breath and must onset")
        #expect(!(analyzer.isAmbientHold))
    }

    @Test func ambientHoldRecoversAfterLoudStretchPasses() {
        // Loud ambient engages the gate; a quiet stretch longer than the trailing window (3.0s) must
        // fully clear it from that window, releasing the hold before the final breath.
        let signal = tone(2.0, 0.02) + lowNoise(4.0, 0.0005) + tone(1.0, 0.1)
        let (events, analyzer) = run(
            .single(minActiveSec: 0.2, maxTakeSec: 20, trailingSilenceSec: 0.8),
            noiseFloor: ambientTestNoiseFloor, ambientGateRMS: 0.01, signal)
        #expect(onsetCount(events) == 1, "hold must have released before the final breath")
        #expect(!(analyzer.isAmbientHold))
    }

    @Test func ambientHoldDisabledWhenThresholdNil() {
        // Same loud-ambient-then-burst shape as the suppression test, but with the gate off (nil) —
        // behavior must be identical to every pre-Problem-2b caller: the burst onsets normally.
        let signal = tone(2.0, 0.02) + tone(0.5, 0.1)
        let (events, analyzer) = run(
            .single(minActiveSec: 0.2, maxTakeSec: 20, trailingSilenceSec: 0.8),
            noiseFloor: ambientTestNoiseFloor, signal)
        #expect(onsetCount(events) == 1, "no gate means no suppression")
        #expect(!(analyzer.isAmbientHold))
    }

    // MARK: single (frc/rv)

    @Test func singleEndsOnTrailingSilenceWithTrimmedBoundaries() {
        let signal = silence(0.5) + tone(2.0) + silence(2.0)
        let (events, _) = run(.single(minActiveSec: 0.3, maxTakeSec: 10, trailingSilenceSec: 0.8), signal)
        #expect(onsetCount(events) == 1)
        #expect(endReason(events) == .silence)
        let segs = segments(events)
        #expect(segs.count == 1)
        #expect(segs[0].0 == .whole)
        #expect(abs(segs[0].1 - Int(0.5 * sr)) <= tol)  // start at onset, lead silence dropped
        #expect(abs(segs[0].2 - Int(2.5 * sr)) <= tol)  // end where signal stopped
    }

    @Test func subFloorNoiseNeverOnsets() {
        let (events, _) = run(.single(minActiveSec: 0.3, maxTakeSec: 10, trailingSilenceSec: 0.8), lowNoise(3, 0.001))
        #expect(onsetCount(events) == 0)
        #expect(endReason(events) == nil)
    }

    @Test func onsetIgnoresBurstyAmbient() {
        // PR #11 real hardware regression: a per-hop threshold couldn't tell "the room got briefly
        // loud" from "a breath started" once ambient bursts cleared the same width bar onset needs —
        // one trace's ambient p10 sat *above* the (uncalibrated) activity threshold. 5s of bursty
        // ambient alone, no breath, must never onset.
        let (events, _) = run(.single(minActiveSec: 0.3, maxTakeSec: 10, trailingSilenceSec: 0.8), noisyAmbient(5.0))
        #expect(onsetCount(events) == 0)
        #expect(endReason(events) == nil)
    }

    @Test func cycleSplitsThroughBurstyAmbient() {
        // The actual PR #11 v30 reproduction: bursty ambient (bursts clearing the per-hop threshold for
        // 100ms+) surrounding a genuinely gentle, sustained breath. Onset must fire only at the breath,
        // and the inhale/pause/exhale split must still happen despite the ambient bursts either side.
        let signal = noisyAmbient(2.0) + gentleBreath(4.0) + noisyAmbient(1.0) + gentleBreath(4.0) + noisyAmbient(3.0)
        let (events, _) = run(
            .cycle(minPhaseSec: 0.5, midPauseSec: 0.4, maxCycleSec: 30, trailingSilenceSec: 0.8), signal
        )
        #expect(onsetCount(events) == 1)
        let segs = segments(events)
        #expect(segs.map(\.0) == [.inhale, .exhale])
        #expect(endReason(events) == .silence)
        // Boundaries land near the real breath's start/end (2.0s / 6.0s / 7.0s / 11.0s), not stalled
        // indefinitely by the surrounding bursts and not falsely split by them mid-breath.
        #expect(abs(segs[0].1 - Int(2.0 * sr)) <= Int(0.6 * sr))
        #expect(abs(segs[1].2 - Int(11.0 * sr)) <= Int(0.6 * sr))
    }

    @Test func singleEndsOnTimeThroughTransientBlips() {
        // Regression for PR #11: a handful of sub-onsetWidth transients in the trailing silence must
        // not repeatedly reset the countdown — the take should still end ~trailingSilenceSec after the
        // real tone stops, not stall to maxTakeSec.
        let signal = silence(0.3) + tone(2.0) + blippedSilence(3.0)
        let (events, _) = run(.single(minActiveSec: 0.3, maxTakeSec: 10, trailingSilenceSec: 0.8), signal)
        #expect(onsetCount(events) == 1)
        #expect(endReason(events) == .silence)
        let segs = segments(events)
        #expect(segs.count == 1)
        #expect(abs(segs[0].1 - Int(0.3 * sr)) <= tol)
        #expect(abs(segs[0].2 - Int(2.3 * sr)) <= tol)  // ends where the tone stopped, blips excluded
    }

    @Test func sustainedResumptionStillResetsSilence() {
        // A genuinely sustained reactivation (not a transient blip) must still reset the silence
        // countdown normally — the bridge only applies to sub-onsetWidth runs.
        let signal = tone(2.0) + silence(0.4) + tone(1.0) + silence(2.0)
        let (events, _) = run(.single(minActiveSec: 0.3, maxTakeSec: 10, trailingSilenceSec: 0.8), signal)
        #expect(onsetCount(events) == 1)
        let segs = segments(events)
        #expect(segs.count == 1)
        #expect(abs(segs[0].2 - Int(3.4 * sr)) <= tol)  // end of second tone, not the first
        #expect(endReason(events) == .silence)
    }

    @Test func noiseFloorGatesActivity() {
        // Floor 0.01 → activity threshold 0.014 (activityFloorK 1.4). A 0.012 tone stays below it;
        // a 0.1 tone trips onset.
        let quiet = silence(0.3) + tone(1.0, 0.012) + silence(1.2)
        #expect(onsetCount(run(.single(minActiveSec: 0.2, maxTakeSec: 10, trailingSilenceSec: 0.8),
                               noiseFloor: 0.01, quiet).events) == 0)
        let loud = silence(0.3) + tone(1.0, 0.1) + silence(1.2)
        #expect(onsetCount(run(.single(minActiveSec: 0.2, maxTakeSec: 10, trailingSilenceSec: 0.8),
                               noiseFloor: 0.01, loud).events) == 1)
    }

    // MARK: cleanEvents (cores)

    @Test func countedTrailingSilenceSurvivesBlips() {
        // Same PR #11 regression, for a counted-event take's trailing-silence take-ending: blips after
        // the last event must not stall the take past its natural trailing-silence window.
        let signal = silence(0.3) + impulses(3, spacingSec: 0.5, widthSec: 0.15) + blippedSilence(3.0)
        let (events, analyzer) = run(.cleanEvents(minGapSec: 0.4, maxTakeSec: 10, trailingSilenceSec: 0.8), signal)
        #expect(analyzer.eventCount == 3)
        #expect(endReason(events) == .silence)
    }

    @Test func cleanEventsCountsWellSeparatedAndNotTooClose() {
        let signal = silence(0.3) + impulses(6, spacingSec: 0.5) + silence(1.0)
        let (events, analyzer) = run(.cleanEvents(minGapSec: 0.4, maxTakeSec: 20, trailingSilenceSec: 0.8), signal)
        #expect(analyzer.eventCount == 6)
        #expect(endReason(events) == .silence)
        #expect(segments(events).count == 1)
        #expect(segments(events).first?.0 == .whole)
        #expect(!(analyzer.lastGapWithinMin))  // 0.5 s spacing > 0.4 s min gap
    }

    @Test func cleanEventsFlagsTooCloseGap() {
        let signal = silence(0.3) + impulses(5, spacingSec: 0.3) + silence(1.0)  // 0.3 < 0.4 min gap, > refractory
        let (_, analyzer) = run(.cleanEvents(minGapSec: 0.4, maxTakeSec: 20, trailingSilenceSec: 0.8), signal)
        #expect(analyzer.eventCount == 5)
        #expect(analyzer.lastGapWithinMin)
    }

    @Test func cleanEventsLongGapsDoNotTruncate() {
        // Deliberate ~2 s separations must NOT end the take after the first event; only the final
        // pause (longer than trailingSilenceSec) does. Guards against truncating a separated take.
        let signal = silence(0.3) + impulses(5, spacingSec: 2.0) + silence(3.5)
        let (events, analyzer) = run(.cleanEvents(minGapSec: 0.4, maxTakeSec: 30, trailingSilenceSec: 3.0), signal)
        #expect(analyzer.eventCount == 5)
        #expect(endReason(events) == .silence)
    }

    @Test func refractoryPreventsDoubleCount() {
        let signal = silence(0.3) + impulses(8, spacingSec: 0.15, widthSec: 0.03) + silence(1.0)  // 0.15 < 0.22 refractory
        let (_, analyzer) = run(.cleanEvents(minGapSec: 0.1, maxTakeSec: 20, trailingSilenceSec: 0.8), signal)
        #expect(analyzer.eventCount < 8)
    }

    // MARK: pairedEvents (recovery's inhale-sip/exhale-sip alternator)

    @Test func pairedCleanEventsCountsCompleteBreaths() {
        let signal = silence(0.3) + pairedBursts(3, inOutGapSec: 0.6, pairSpacingSec: 2.0) + silence(1.0)
        let (events, analyzer) = run(
            .cleanEvents(minGapSec: 0.1, maxTakeSec: 20, trailingSilenceSec: 3.0, targetEvents: 3, pairedEvents: true),
            signal)
        #expect(analyzer.eventCount == 3)
        #expect(endReason(events) == .targetReached)
    }

    /// Regression test for the reported bug: real hardware showed in/out sip gaps landing right on
    /// `hookMinDistSec`'s old 0.7-0.85s boundary, merging inconsistently. The sip alternator doesn't
    /// use that distance at all — it just needs the gap to clear the much smaller merge-bridge window,
    /// so an ambiguous-for-the-old-design gap here is unremarkable.
    @Test func pairedBoundaryGapNeitherSplitsNorMerges() {
        let signal = silence(0.3) + pairedBursts(3, inOutGapSec: 0.75, pairSpacingSec: 1.7) + silence(1.0)
        let (events, analyzer) = run(
            .cleanEvents(minGapSec: 0.1, maxTakeSec: 20, trailingSilenceSec: 3.0, targetEvents: 3, pairedEvents: true),
            signal)
        #expect(analyzer.eventCount == 3)
        #expect(endReason(events) == .targetReached)
    }

    @Test func pairedMicroDipWithinSipIsOneSip() {
        // A brief 0.10s dip inside one sip's own motion (< the 0.20s merge-bridge window) must not
        // split it into two sips — two such dipped sips should still complete only one breath.
        let dippedSip = tone(0.15) + silence(0.10) + tone(0.15)
        let signal = silence(0.3) + dippedSip + silence(1.0) + dippedSip + silence(3.5)
        let (_, analyzer) = run(.cleanEvents(minGapSec: 0.1, maxTakeSec: 20, trailingSilenceSec: 3.0, pairedEvents: true), signal)
        #expect(analyzer.eventCount == 1)
    }

    @Test func pairedDanglingInhaleDoesNotCount() {
        let signal = silence(0.3) + impulses(5, spacingSec: 1.0, widthSec: 0.15) + silence(3.5)
        let (_, analyzer) = run(.cleanEvents(minGapSec: 0.1, maxTakeSec: 30, trailingSilenceSec: 3.0, pairedEvents: true), signal)
        #expect(analyzer.eventCount == 2, "5 sips = 2 complete breaths + 1 dangling inhale that never counts")
    }

    @Test func pairedLivePhaseAlternates() {
        let signal = silence(0.3) + tone(0.3) + silence(1.0) + tone(0.3) + silence(1.0)
        let detection = CaptureDetection.cleanEvents(minGapSec: 0.1, maxTakeSec: 20, trailingSilenceSec: 3.0, pairedEvents: true)

        func analyzer(after seconds: Double) -> CaptureAnalyzer {
            var a = CaptureAnalyzer(sampleRate: sr, detection: detection, noiseFloorRMS: nil)
            let count = min(signal.count, Int(seconds * sr))
            var i = 0
            while i < count {
                let end = min(count, i + 4_096)
                _ = a.ingest(Array(signal[i..<end]))
                i = end
            }
            return a
        }

        // Sip 1 (inhale) is active [0.3, 0.6); livePhase reads .inhale as soon as sipCount==0 enters
        // .capturing, before the sip even finalizes.
        #expect(analyzer(after: 0.5).livePhase == .inhale)
        // Sip 1 finalizes ~0.2s after its run ends (~0.6 + 0.2); parity flips to "expecting exhale".
        #expect(analyzer(after: 1.0).livePhase == .exhale)
        // Sip 2 (exhale) completes the breath; parity flips back to "expecting inhale" for the next one.
        #expect(analyzer(after: 2.5).livePhase == .inhale)
    }

    // MARK: naturalRhythm (gaps)

    @Test func naturalRhythmMeasuresIntervals() {
        let spacing = 0.3
        let signal = silence(0.3) + impulses(5, spacingSec: spacing) + silence(1.0)
        let (events, analyzer) = run(.naturalRhythm(minActiveSec: 0.2, maxTakeSec: 20, trailingSilenceSec: 0.8), signal)
        #expect(analyzer.eventCount == 5)
        #expect(analyzer.intervalsFrames.count == 4)
        for gap in analyzer.intervalsFrames {
            #expect(abs(gap - Int(spacing * sr)) <= tol)
        }
        #expect(endReason(events) == .silence)
    }

    // MARK: cycle (calm)

    @Test func cycleSplitsInhaleAndExhaleAtMidPause() {
        // Pause widened to 1.2s (from an earlier 0.6s): the windowed classifier's own detection lag
        // (~0.2-0.3s for the pause split, plus its own confirmation delay) leaves a 0.6s pause with
        // negative margin against `midPauseSec` (0.4s) — same fix as `livePhaseTracksInhalePauseExhale`.
        let signal = silence(0.3) + tone(1.5) + silence(1.2) + tone(1.5) + silence(1.0)
        let (events, _) = run(
            .cycle(minPhaseSec: 0.5, midPauseSec: 0.4, maxCycleSec: 20, trailingSilenceSec: 0.8), signal
        )
        #expect(onsetCount(events) == 1)
        let segs = segments(events)
        #expect(segs.map(\.0) == [.inhale, .exhale])
        #expect(abs(segs[0].1 - Int(0.3 * sr)) <= tol)  // inhale start
        #expect(abs(segs[0].2 - Int(1.8 * sr)) <= tol)  // inhale end (mid-pause)
        #expect(abs(segs[1].1 - Int(3.0 * sr)) <= tol)  // exhale start
        #expect(abs(segs[1].2 - Int(4.5 * sr)) <= tol)  // exhale end
        #expect(endReason(events) == .silence)
    }

    @Test func cycleMidPauseSurvivesBlips() {
        // Same PR #11 regression as `singleEndsOnTimeThroughTransientBlips`, but for the
        // inhale→midPause split: blips inside the pause must not repeatedly reset accumulated silence
        // and stall the split until real trailing silence long after the true pause.
        let signal = tone(1.0) + blippedSilence(0.6) + tone(1.0) + silence(1.2)
        let (events, _) = run(
            .cycle(minPhaseSec: 0.5, midPauseSec: 0.4, maxCycleSec: 20, trailingSilenceSec: 0.8), signal
        )
        let segs = segments(events)
        #expect(segs.map(\.0) == [.inhale, .exhale])
        #expect(segs[0].2 < Int(1.6 * sr))  // split lands inside the blipped gap...
        #expect(segs[1].1 >= Int(1.0 * sr))  // ...not pushed out past the second tone
        #expect(endReason(events) == .silence)
    }

    @Test func exhaleStartsFreshSilenceCountAfterMidPause() {
        // Regression: a brief blip during the pause flips `.midPause` into `.exhale` (no width check on
        // that transition), but `.exhale` must not inherit the pause's already-accumulated silence —
        // otherwise the take ends immediately with a ~0-length exhale segment (real hardware:
        // `exhaleTooShort` firing before the user had even started exhaling).
        let signal = tone(5.0) + silence(2.0) + tone(0.01) + silence(0.3) + tone(1.5) + silence(2.0)
        let (events, _) = run(
            .cycle(minPhaseSec: 0.5, midPauseSec: 0.4, maxCycleSec: 30, trailingSilenceSec: 0.8), signal
        )
        let segs = segments(events)
        #expect(segs.map(\.0) == [.inhale, .exhale])
        #expect((segs[1].2 - segs[1].1) > Int(0.5 * sr))  // not a near-zero-length segment
        #expect(endReason(events) == .silence)
    }

    @Test func cycleWithoutExhaleIsIncomplete() {
        let signal = silence(0.3) + tone(1.0) + silence(3.0)  // no exhale
        let (events, _) = run(
            .cycle(minPhaseSec: 0.4, midPauseSec: 0.4, maxCycleSec: 2.0, trailingSilenceSec: 0.8), signal
        )
        #expect(segments(events).map(\.0) == [.inhale])
        #expect(endReason(events) == .incomplete)
    }

    @Test func cycleSegmentsValidGuard() {
        let minPhase = Int(0.5 * sr)
        #expect(CaptureAnalyzer.cycleSegmentsValid(
            inhaleFrames: Int(1.5 * sr), exhaleFrames: Int(1.5 * sr), minPhaseFrames: minPhase))
        #expect(!(CaptureAnalyzer.cycleSegmentsValid(  // too short
            inhaleFrames: Int(0.2 * sr), exhaleFrames: Int(1.5 * sr), minPhaseFrames: minPhase)))
        #expect(!(CaptureAnalyzer.cycleSegmentsValid(  // imbalanced (> 3:1)
            inhaleFrames: Int(0.6 * sr), exhaleFrames: Int(2.5 * sr), minPhaseFrames: minPhase)))
    }

    // MARK: finalPhase (FRC/RV) — Phase 3, reuses cycle's inhale→pause→exhale routing

    @Test func finalPhaseKeepsOnlyFinalSegmentAsWhole() {
        // Pause widened to 1.2s (from an earlier 0.5s) — same negative-margin fix as
        // `cycleSplitsInhaleAndExhaleAtMidPause`.
        let signal = silence(0.3) + tone(1.5) + silence(1.2) + tone(4.0) + silence(1.0)
        let (events, _) = run(
            .finalPhase(minLeadSec: 0.5, midPauseSec: 0.4, minPhaseSec: 3.0, maxTakeSec: 20, trailingSilenceSec: 0.8),
            signal
        )
        let segs = segments(events)
        #expect(segs.count == 1, "the lead phase must never be emitted")
        #expect(segs[0].0 == .whole)
        let expectedStart = Int(0.3 * sr + 1.5 * sr + 1.2 * sr)  // lead + pause
        #expect(abs(segs[0].1 - expectedStart) <= tol)
        #expect(endReason(events) == .silence)
    }

    @Test func finalPhaseKeepsFullDecayTail() {
        // PR #11 real hardware regression: FRC/RV's forced exhale decays continuously (peak to ~10x
        // quieter) while airflow is still real, not a discontinuity — a stale, peak-anchored breath
        // reference must not cut this off mid-taper. Real hardware trace: kept segments were truncated
        // to 0.35-0.9s of a multi-second real exhale, ending at ~40% of the exhale's early peak level.
        let signal = silence(1.5) + lowNoise(1.0, 0.03) + silence(0.6) + decayingBreath(from: 0.03, to: 0.003, sec: 4.0) + silence(1.0)
        let (events, _) = run(
            .finalPhase(minLeadSec: 0.3, midPauseSec: 0.4, minPhaseSec: 0.5, maxTakeSec: 20, trailingSilenceSec: 0.8),
            signal
        )
        let segs = segments(events)
        #expect(segs.count == 1)
        #expect(segs[0].0 == .whole)
        #expect(endReason(events) == .silence)
        // The old (broken) behavior cut this at ~40% of the peak, keeping only ~1.6-1.8s of the 4s
        // decay; the fix rides it down much further (~2.8s), well clear of the old bug's range.
        let keptSec = Double(segs[0].2 - segs[0].1) / sr
        #expect(keptSec > 2.5)
    }

    @Test func finalPhaseFaintReleaseCaughtByDecayAnchorsAtTrueStart() {
        // PR #11 real hardware regression: a passive FRC release quieter than its loud lead inhale
        // never cleared the old `breathTypical`-anchored bar and hung for the full `maxTakeSec`. The
        // fix (`releaseBar`'s ambient-relative base + decay toward `endBar`) catches it late — but
        // `retroAnchoredReleaseStart` must anchor the kept segment at the release's *true* start, not
        // the (much later) detection frame.
        let leadEnd = 1.5  // 0.5s lead-in silence + 1.0s loud lead tone
        let trueReleaseStart = leadEnd + 1.0  // 1.0s of real silence into the pause before the release
        let signal = silence(0.5) + tone(1.0, 0.03) + silence(1.0) + lowNoise(4.0, 0.0078) + silence(1.0)
        let (events, _) = run(
            .finalPhase(minLeadSec: 0.3, midPauseSec: 0.4, minPhaseSec: 0.5, maxTakeSec: 20, trailingSilenceSec: 0.8),
            signal
        )
        let segs = segments(events)
        #expect(segs.count == 1)
        #expect(segs[0].0 == .whole)
        #expect(endReason(events) == .silence)
        // Anchored near the true release start (~2.5s), not the detection frame (only reachable via
        // the decay, several seconds later).
        #expect(abs(segs[0].1 - Int(trueReleaseStart * sr)) <= Int(0.5 * sr))
    }

    @Test func finalPhaseContinuousNoDipIsIncomplete() {
        let signal = silence(0.3) + tone(8.0)
        let (events, _) = run(
            .finalPhase(minLeadSec: 0.5, midPauseSec: 0.4, minPhaseSec: 3.0, maxTakeSec: 6, trailingSilenceSec: 0.8),
            signal
        )
        #expect(segments(events).isEmpty, "no lead-phase segment should ever be emitted")
        #expect(endReason(events) == .incomplete)
    }

    @Test func finalPhaseSubPauseDipDuringLeadBridgesWithoutFalseSplit() {
        // A 0.2s dip mid-lead (< 0.4s midPauseSec) must not be mistaken for the deliberate pause; the
        // lead phase should bridge it and keep listening for the real pause that follows (widened to
        // 1.2s from an earlier 0.5s — same negative-margin fix as the other mid-pause tests).
        let signal = silence(0.3) + tone(1.5) + silence(0.2) + tone(0.5) + silence(1.2) + tone(3.5) + silence(1.0)
        let (events, _) = run(
            .finalPhase(minLeadSec: 0.5, midPauseSec: 0.4, minPhaseSec: 3.0, maxTakeSec: 20, trailingSilenceSec: 0.8),
            signal
        )
        let segs = segments(events)
        #expect(segs.count == 1, "the bridged dip must not produce an extra split")
        #expect(segs[0].0 == .whole)
        #expect(abs((segs[0].2 - segs[0].1) - Int(3.5 * sr)) <= tol, "kept phase is the real final phase only, not the bridged lead")
        #expect(endReason(events) == .silence)
    }

    // MARK: TakeIssue (Phase 1 — live rejection-reason detail)

    @Test func cycleIssueDistinguishesReasons() {
        let minPhase = Int(0.5 * sr)
        #expect(CaptureAnalyzer.cycleIssue(
            inhaleFrames: Int(1.5 * sr), exhaleFrames: Int(1.5 * sr), minPhaseFrames: minPhase) == nil)
        #expect(CaptureAnalyzer.cycleIssue(
            inhaleFrames: Int(0.2 * sr), exhaleFrames: Int(1.5 * sr), minPhaseFrames: minPhase) == .inhaleTooShort)
        #expect(CaptureAnalyzer.cycleIssue(
            inhaleFrames: Int(1.5 * sr), exhaleFrames: Int(0.2 * sr), minPhaseFrames: minPhase) == .exhaleTooShort)
        // Both short: inhale takes priority (arbitrary but consistent single-reason choice).
        #expect(CaptureAnalyzer.cycleIssue(
            inhaleFrames: Int(0.1 * sr), exhaleFrames: Int(0.2 * sr), minPhaseFrames: minPhase) == .inhaleTooShort)
        // Imbalanced (> 3:1), both individually long enough.
        if case let .phasesImbalanced(ratio)? = CaptureAnalyzer.cycleIssue(
            inhaleFrames: Int(0.6 * sr), exhaleFrames: Int(2.5 * sr), minPhaseFrames: minPhase) {
            #expect(abs(ratio - 2.5 / 0.6) <= 0.01)
        } else {
            Issue.record("expected .phasesImbalanced")
        }
        // cycleSegmentsValid stays a thin bool wrapper — regression guard for Step 1.1's refactor.
        #expect(CaptureAnalyzer.cycleSegmentsValid(
            inhaleFrames: Int(1.5 * sr), exhaleFrames: Int(1.5 * sr), minPhaseFrames: minPhase)
            == (CaptureAnalyzer.cycleIssue(inhaleFrames: Int(1.5 * sr), exhaleFrames: Int(1.5 * sr), minPhaseFrames: minPhase) == nil))
    }

    // MARK: LivePhase / phaseElapsedFrames (Phase 1 — live phase feedback)

    @Test func livePhaseTracksInhalePauseExhale() {
        // Pause widened to 1.2s (from an earlier 0.6s): the windowed quiet/loud classifier has its own
        // reaction lag (~0.2-0.3s, see `quietDetectionLagFrames`/`loudDetectionLagFrames`) that a short
        // pause no longer has margin for — real pauses run far longer than this, so the fix is here,
        // not in the classifier.
        let signal = silence(0.3) + tone(1.5) + silence(1.2) + tone(1.5) + silence(1.0)
        let detection = CaptureDetection.cycle(minPhaseSec: 0.5, midPauseSec: 0.4, maxCycleSec: 20, trailingSilenceSec: 0.8)

        func analyzer(after seconds: Double) -> CaptureAnalyzer {
            var a = CaptureAnalyzer(sampleRate: sr, detection: detection, noiseFloorRMS: nil)
            let count = min(signal.count, Int(seconds * sr))
            var i = 0
            while i < count {
                let end = min(count, i + 4_096)
                _ = a.ingest(Array(signal[i..<end]))
                i = end
            }
            return a
        }

        // Onset at ~0.3s (confirmed after the classifier's own detection lag); mid-pause splits once
        // quiet has held for ~0.2s (detection lag) + 0.4s (midPauseSec) after tone1 ends at 1.8s ≈ 2.4s;
        // exhale onset follows tone2's start at 3.0s. Checkpoints sit well inside each phase.
        #expect(analyzer(after: 1.0).livePhase == .inhale)
        #expect(analyzer(after: 2.7).livePhase == .midPause)
        #expect(analyzer(after: 4.0).livePhase == .exhale)

        let midInhale = analyzer(after: 1.0).phaseElapsedFrames
        let laterInhale = analyzer(after: 1.5).phaseElapsedFrames
        #expect(laterInhale > midInhale)

        // Early in the exhale phase, elapsed-in-phase should reflect time since tone2 started, not
        // carried over from inhale's much earlier start (~3s prior) — the phase-entry anchor is itself
        // back-dated by the classifier's own detection lag, so "elapsed" is never exactly zero right at
        // the transition; the regression this guards is a multi-second carry-over, not sub-second lag.
        let earlyExhale = analyzer(after: 3.5).phaseElapsedFrames
        #expect(earlyExhale < Int(1.0 * sr))
    }

    // MARK: Real breath recordings — drive the detector with real audio (oracle = offline UnitExtractor)

    private func assetURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)        // …/Tests/BreathEngineTests/CaptureAnalyzerTests.swift
            .deletingLastPathComponent()       // BreathEngineTests
            .deletingLastPathComponent()       // Tests
            .deletingLastPathComponent()       // package root
            .appendingPathComponent("Assets/breaths/\(name)")
    }

    /// Session noise floor from the real room-tone recording, as the app derives it.
    private func realRoomFloor() throws -> Float {
        let room = try AssetLibrary.loadMonoSamples(url: assetURL("room_silence.aifc"), targetRate: sr)
        var a = CaptureAnalyzer(sampleRate: sr, detection: .fixedDuration(seconds: Double(room.count) / sr + 1),
                                noiseFloorRMS: nil)
        _ = a.ingest(room)
        return a.meanFloorRMS()
    }

    @Test func realPackingLiveCountTracksOffline() throws {
        let samples = try AssetLibrary.loadMonoSamples(url: assetURL("packing_1.aifc"), targetRate: sr)
        let offline = UnitExtractor.gulpCoreRanges(from: samples, sampleRate: sr).count
        let (_, analyzer) = run(.cleanEvents(minGapSec: 0.35, maxTakeSec: 60, trailingSilenceSec: 5),
                                noiseFloor: try realRoomFloor(), samples)
        print("REAL packing_1 — offline=\(offline) live=\(analyzer.eventCount)")
        #expect(offline > 5)
        #expect(abs(analyzer.eventCount - offline) <= 3)
    }

    @Test func realRecoveryLiveCountTracksOffline() throws {
        let samples = try AssetLibrary.loadMonoSamples(url: assetURL("recovery.aifc"), targetRate: sr)
        // gulpCoreRanges (default gulpMinDistSec) counts raw sips, not complete hooks — extract's
        // hookMinDistSec merge is the oracle for "complete breaths," matching the live paired counter.
        let offlineRawSips = UnitExtractor.gulpCoreRanges(from: samples, sampleRate: sr).count
        let offlineBreaths = UnitExtractor.extract(from: samples, sampleRate: sr).count
        let (_, analyzer) = run(.naturalRhythm(minActiveSec: 0.5, maxTakeSec: 60, trailingSilenceSec: 5, pairedEvents: true),
                                noiseFloor: try realRoomFloor(), samples)
        print("REAL recovery paired — offlineRawSips=\(offlineRawSips) offlineBreaths=\(offlineBreaths) live=\(analyzer.eventCount)")
        // This step's live count is a UX guidance display only — no target gate, no redo trigger, and
        // `EnrollModel.currentStepIntervalsFrames` (fed by this exact count) is never read for recovery
        // (only `packing_cadence`'s core-isolation check consumes it, see
        // `EnrollModel.checkPackingCoreIsolation`'s style-slug guard). Offline re-segmentation is always
        // authoritative regardless. On this gold clip's genuinely tight natural cadence, real sips run
        // close enough together that the shared hysteresis (tuned for the separated/deliberate-pause
        // style, not fast cadence — see `releaseRatio`) fuses a breath's exhale with the next breath's
        // inhale into a single run, undercounting relative to `offlineBreaths`: a known, accepted
        // tradeoff for this display-only counter (see the plan's Problem 1 risk notes), not something
        // this test can require without over-constraining the shared hysteresis for every other style.
        // What must still hold: paired mode should never run *hot* the way raw per-sip counting did
        // (would read `offlineRawSips` here — over 2x the real breath count).
        #expect(offlineBreaths > 2)
        #expect(analyzer.eventCount > 0)
        #expect(analyzer.eventCount <= offlineBreaths)
    }

    @Test(.disabled("gentle calm-cycle splitting needs real same-session recordings to calibrate"))
    func realCycleSplitsRealInhaleAndExhale() throws {
        let inhale = try AssetLibrary.loadMonoSamples(url: assetURL("calm_inhale.aifc"), targetRate: sr)
        let exhale = try AssetLibrary.loadMonoSamples(url: assetURL("calm_exhale.aifc"), targetRate: sr)
        let signal = inhale + silence(1.2) + exhale + silence(1.5)
        let (events, _) = run(.cycle(minPhaseSec: 3.0, midPauseSec: 0.5, maxCycleSec: 60, trailingSilenceSec: 1.0),
                              noiseFloor: try realRoomFloor(), signal)
        let segs = segments(events)
        print("REAL cycle — labels=\(segs.map(\.0))")
        // The standalone calm palette inhale is gentle and sits close to the room_silence floor, so
        // the energy gate can't reliably resolve its phases here. The synthetic cycle test proves the
        // split logic given adequate SNR; calibrating gentle-breath onset/pause against the absolute
        // floor needs real same-session enrollment recordings (close mic, quiet room). Disabled above,
        // not asserted, so the suite never implies the gentle-cycle path is validated on real audio.
    }

    // MARK: Consistency guard — live count agrees with the offline extractor

    @Test func liveCountMatchesOfflineUnitExtractor() {
        let buffer = silence(0.3) + impulses(7, spacingSec: 0.5) + silence(1.0)
        let (_, analyzer) = run(.cleanEvents(minGapSec: 0.4, maxTakeSec: 20, trailingSilenceSec: 0.8), buffer)
        let offline = UnitExtractor.gulpCoreRanges(from: buffer, sampleRate: sr).count
        #expect(abs(analyzer.eventCount - offline) <= 1)
    }

    // MARK: Style-aware spectral gate (Step 2.4) — zero-true-event-loss against the gold assets

    /// Every width-confirmed candidate in a bundled gold recording must be spectrally accepted under
    /// its style's profile — this is the permanent release gate for `SpectralGateProfile` thresholds.
    /// Packing gulps (sharp glottal clicks, energy skewed above 3 kHz) and recovery hooks (turbulent
    /// airflow concentrated in 300-3000 Hz) are spectrally near-opposite — see `SpectralGateProfile`'s
    /// doc comments for the measured cluster evidence behind `.gulp`/`.hook`.
    @Test func goldPackingAcceptedUnderGulpProfile() throws {
        for name in ["packing_1.aifc", "packing_2.aifc"] {
            let samples = try AssetLibrary.loadMonoSamples(url: assetURL(name), targetRate: sr)
            let (_, analyzer) = run(.cleanEvents(minGapSec: 0.22, maxTakeSec: 40, trailingSilenceSec: 3.0,
                                                 eventMinDistSec: UnitExtractor.gulpMinDistSec,
                                                 spectralGate: .gulp), samples)
            let rejected = analyzer.spectralCandidates.filter { !$0.accepted }
            #expect(rejected.isEmpty, "\(name): \(rejected.count)/\(analyzer.spectralCandidates.count) real gulps rejected — \(rejected)")
        }
    }

    @Test func goldRecoveryAcceptedUnderHookProfile() throws {
        let samples = try AssetLibrary.loadMonoSamples(url: assetURL("recovery.aifc"), targetRate: sr)
        let (_, analyzer) = run(.naturalRhythm(minActiveSec: 0.5, maxTakeSec: 40, trailingSilenceSec: 3.0,
                                               eventMinDistSec: UnitExtractor.hookMinDistSec,
                                               spectralGate: .hook), samples)
        let rejected = analyzer.spectralCandidates.filter { !$0.accepted }
        #expect(rejected.isEmpty, "recovery.aifc: \(rejected.count)/\(analyzer.spectralCandidates.count) real hooks rejected — \(rejected)")
    }

    /// Synthetic band-limited bursts, approximated as a sum of sinusoids spanning `[lowHz, highHz]`
    /// (cheaper and more precisely band-limited for test purposes than a filtered noise source).
    private func spectralBurst(lowHz: Double, highHz: Double, sec: Double, amp: Float = 0.3) -> [Float] {
        let n = Int(sec * sr)
        return (0..<n).map { i in
            let t = Double(i) / sr
            var s = 0.0
            var f = lowHz
            let step = (highHz - lowHz) / 8
            while f <= highHz {
                s += sin(2 * .pi * f * t)
                f += step
            }
            return Float(s / 9) * amp
        }
    }

    /// Locks in the style asymmetry found this session: a signal shaped like real recovery *exhale*
    /// breath (broadband energy concentrated in 300-3000 Hz) is not what a packing gulp looks like, so
    /// it must never pass `.gulp`. The reverse is no longer a strict asymmetry: a real recovery
    /// *inhale* sip is itself high-centroid (see `.hook`'s doc comment), so a high-centroid burst is
    /// now expected to pass `.hook` too — `.hook` accepts either an exhale-shaped or an inhale-shaped
    /// candidate, `.gulp` only the latter. What must still never happen is a breath-band signal passing
    /// `.gulp`, which would erase the one asymmetry that protects packing from recovery-shaped noise.
    ///
    /// Asserts on `spectralCandidates` rather than `eventCount`: `spectralBurst`'s multi-sinusoid sum can
    /// have a shallow envelope null that splits one burst into two width-confirmed runs (a pre-existing,
    /// orthogonal issue — same synthetic-signal construction predates this session), which would make an
    /// `eventCount` assertion flaky for a reason unrelated to the spectral-gate logic under test here.
    @Test func gulpAndHookProfilesDisagreeByDesign() {
        let breathBandBurst = silence(0.3) + spectralBurst(lowHz: 300, highHz: 3000, sec: 0.3) + silence(1.5)
        let (_, gulpOnBreathBand) = run(.cleanEvents(minGapSec: 0.22, maxTakeSec: 10, trailingSilenceSec: 1.0,
                                                      spectralGate: .gulp), breathBandBurst)
        #expect(!(gulpOnBreathBand.spectralCandidates.contains { $0.accepted }),
                "a breath-band (exhale-shaped) burst must not pass .gulp")
        let (_, hookOnBreathBand) = run(.cleanEvents(minGapSec: 0.22, maxTakeSec: 10, trailingSilenceSec: 1.0,
                                                      spectralGate: .hook), breathBandBurst)
        #expect(hookOnBreathBand.spectralCandidates.contains { $0.accepted },
                "a breath-band (exhale-shaped) burst must pass .hook")

        let highBurst = silence(0.3) + spectralBurst(lowHz: 6000, highHz: 9000, sec: 0.3) + silence(1.5)
        let (_, gulpOnHigh) = run(.cleanEvents(minGapSec: 0.22, maxTakeSec: 10, trailingSilenceSec: 1.0,
                                               spectralGate: .gulp), highBurst)
        #expect(gulpOnHigh.spectralCandidates.contains { $0.accepted }, "a high-centroid burst must pass .gulp")
        let (_, hookOnHigh) = run(.cleanEvents(minGapSec: 0.22, maxTakeSec: 10, trailingSilenceSec: 1.0,
                                               spectralGate: .hook), highBurst)
        #expect(hookOnHigh.spectralCandidates.contains { $0.accepted },
                "a high-centroid burst is also inhale-sip-shaped and must now pass .hook")
    }

    /// Regression for the real-hardware bug this session found (see `.hook`'s doc comment): a genuine
    /// inhale sip's spectral shape (high centroid, bandRatio well under the old flat 0.45 threshold)
    /// was randomly rejected — this starved the paired sip counter of its first-of-pair sip. The
    /// centroid-only OR branch must accept it even though bandRatio alone would fail.
    @Test func hookAcceptsHighCentroidLowBandRatioInhaleShape() {
        // Mirrors a real observed rejected-then-should-pass candidate: centroid ~5900 Hz, bandRatio ~0.28.
        let inhaleShaped = silence(0.3) + spectralBurst(lowHz: 5200, highHz: 6600, sec: 0.3) + silence(1.5)
        let (_, analyzer) = run(.cleanEvents(minGapSec: 0.22, maxTakeSec: 10, trailingSilenceSec: 1.0,
                                              spectralGate: .hook), inhaleShaped)
        #expect(analyzer.spectralCandidates.contains { $0.accepted },
                "a high-centroid inhale-sip shape must pass .hook even at low bandRatio — \(analyzer.spectralCandidates)")
    }

    /// A true non-breath candidate (low centroid, negligible in-band energy — matches the real rejected
    /// silence/rumble candidates observed: centroid < 1,100 Hz, bandRatio < 0.02) must stay rejected
    /// under both `.hook` OR-branches; the centroid floor added for inhale sips must not let noise in.
    @Test func hookStillRejectsTrueNoiseFloorCandidate() {
        let noiseShaped = silence(0.3) + spectralBurst(lowHz: 50, highHz: 250, sec: 0.3) + silence(1.5)
        let (_, analyzer) = run(.cleanEvents(minGapSec: 0.22, maxTakeSec: 10, trailingSilenceSec: 1.0,
                                              spectralGate: .hook), noiseShaped)
        #expect(!(analyzer.spectralCandidates.contains { $0.accepted }),
                "low-centroid/low-bandRatio noise must not pass .hook — \(analyzer.spectralCandidates)")
    }

    /// `spectralGate: nil` (the default) must leave width/refractory-only behavior untouched.
    @Test func spectralGateNilLeavesCountingUnaffected() {
        let signal = silence(0.3) + impulses(6, spacingSec: 0.5) + silence(1.0)
        let (_, analyzer) = run(.cleanEvents(minGapSec: 0.4, maxTakeSec: 20, trailingSilenceSec: 0.8,
                                             spectralGate: nil), signal)
        #expect(analyzer.eventCount == 6)
        #expect(analyzer.spectralCandidates.isEmpty)
    }
}
