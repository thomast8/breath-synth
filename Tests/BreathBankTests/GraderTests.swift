import Testing
@testable import BreathBank
import BreathEngine

struct GraderTests {
    private let flatProfile = [Float](repeating: 1, count: 513)

    private func features(
        rmsDb: Double = -20, centroidHz: Double = 1_500, flatness: Double = 0.3,
        snrDb: Double = 25, profile: [Float]? = nil, clipped: Bool = false, durationSec: Double = 4
    ) -> Grader.Features {
        Grader.Features(rmsDb: rmsDb, centroidHz: centroidHz, flatness: flatness, snrDb: snrDb,
                        profile: profile ?? flatProfile, clipped: clipped, durationSec: durationSec)
    }

    private func normalSiblings() -> [Grader.Features] {
        [features(rmsDb: -20), features(rmsDb: -19), features(rmsDb: -21), features(rmsDb: -20)]
    }

    // MARK: - Stage (a): signal QA

    @Test
    func testClippingRunDetection() {
        var clean = [Float](repeating: 0.5, count: 100)
        #expect(!(Grader.clippingRun(clean, peak: 0.999, minRun: 3)))
        clean[40] = 1; clean[41] = 1; clean[42] = 1; clean[43] = 1
        #expect(Grader.clippingRun(clean, peak: 0.999, minRun: 3))
    }

    @Test
    func testGradeRejectsClipped() {
        let v = Grader.grade(features(clipped: true), siblings: normalSiblings(), gold: flatProfile, lengthOK: true)
        #expect(!(v.accept))
        #expect(v.reason == "clipped")
    }

    @Test
    func testGradeRejectsBadLength() {
        let v = Grader.grade(features(), siblings: normalSiblings(), gold: flatProfile, lengthOK: false)
        #expect(v.reason == "length")
    }

    @Test
    func testGradeRejectsLowSNR() {
        let v = Grader.grade(features(snrDb: 4), siblings: normalSiblings(), gold: flatProfile, lengthOK: true)
        #expect(v.reason == "low_snr")
    }

    // MARK: - Stage (b): sibling anomaly

    @Test
    func testAnomalyFlagsOutlierNotNormal() {
        let siblings = normalSiblings()
        #expect(Grader.anomalyScore(features(rmsDb: -20), siblings: siblings) < 3.5)
        #expect(Grader.anomalyScore(features(rmsDb: -3), siblings: siblings) > 3.5)
    }

    @Test
    func testGradeRejectsOutlier() {
        let v = Grader.grade(features(rmsDb: -3), siblings: normalSiblings(), gold: flatProfile, lengthOK: true)
        #expect(v.reason == "outlier")
    }

    @Test
    func testTooFewSiblingsSkipsAnomaly() {
        // <3 siblings → anomaly can't be judged → score 0 (don't reject on it).
        #expect(Grader.anomalyScore(features(rmsDb: -3), siblings: [features(), features()]) == 0)
    }

    // MARK: - Stage (c): template distance

    @Test
    func testTemplateDistanceIdenticalIsZeroDifferentIsLarge() {
        #expect(abs(Grader.templateDistance(features(profile: flatProfile), gold: flatProfile) - 0) <= 1e-9)
        var lowBand = [Float](repeating: 0, count: 513)
        for k in 0..<50 { lowBand[k] = 1 }
        #expect(Grader.templateDistance(features(profile: flatProfile), gold: lowBand) > 0.6)
    }

    @Test
    func testGradeRejectsOffTechnique() {
        var lowBand = [Float](repeating: 0, count: 513)
        for k in 0..<50 { lowBand[k] = 1 }
        let v = Grader.grade(features(profile: flatProfile), siblings: normalSiblings(), gold: lowBand, lengthOK: true)
        #expect(v.reason == "off_technique")
    }

    // MARK: - Accept

    @Test
    func testGradeAcceptsCleanFragment() {
        let v = Grader.grade(features(), siblings: normalSiblings(), gold: flatProfile, lengthOK: true)
        #expect(v.accept)
        #expect(v.reason == nil)
    }

    // MARK: - Feature extraction end-to-end (real signal)

    @Test
    func testFeaturesFromNoiseBurstAreSane() {
        var rng = SeededRNG(seed: 42)
        let n = 8_000  // 0.5 s @ 16 kHz, > one 1024 STFT frame
        let raw = (0..<n).map { _ -> Float in Float(Double(rng.next()) / Double(UInt64.max) * 2 - 1) * 0.3 }
        let f = Grader.features(raw: raw, sampleRate: 16_000, roomToneProfile: nil)
        #expect(f.profile.count == 513)
        #expect(!(f.clipped))
        #expect(f.snrDb == 99, "no room tone ⇒ SNR stage is a pass-through")
        #expect(f.flatness > 0.3, "white-ish noise should read fairly flat")
        #expect(abs(f.durationSec - 0.5) <= 1e-6)
    }

    // MARK: - New gates: dropout, merged-gulp, cadence

    @Test
    func testDropoutRunDetectsInteriorGapOnly() {
        let sr = 1_000.0
        // 0.3 s loud, 0.2 s silence, 0.3 s loud → an interior 0.2 s gap.
        let withGap = [Float](repeating: 1, count: 300) + [Float](repeating: 0, count: 200) + [Float](repeating: 1, count: 300)
        #expect(Grader.dropoutRun(withGap, sampleRate: sr, minGapSec: 0.15))
        #expect(!(Grader.dropoutRun(withGap, sampleRate: sr, minGapSec: 0.30)), "gap shorter than the threshold")
        // Leading/trailing quiet must NOT count as a dropout.
        let edges = [Float](repeating: 0, count: 200) + [Float](repeating: 1, count: 600) + [Float](repeating: 0, count: 200)
        #expect(!(Grader.dropoutRun(edges, sampleRate: sr, minGapSec: 0.15)))
    }

    @Test
    func testRhythmDistanceRelativeToReference() {
        #expect(abs(Grader.rhythmDistance([100, 100, 100], [100, 100, 100]) - 0) <= 1e-9)
        #expect(abs(Grader.rhythmDistance([50, 50, 50], [100, 100, 100]) - 0.5) <= 1e-9, "half the spacing")
        #expect(Grader.rhythmDistance([], [100]) == 0, "empty side ⇒ no cadence rejection")
    }

    @Test
    func testGradeRejectsDropoutMergedGulpAndCadence() {
        let s = normalSiblings()
        #expect(Grader.grade(features(), siblings: s, gold: flatProfile, lengthOK: true, dropoutOK: false).reason == "dropout")
        #expect(Grader.grade(features(), siblings: s, gold: flatProfile, lengthOK: true, spacingOK: false).reason == "merged_gulp")
        #expect(Grader.grade(features(), siblings: s, gold: flatProfile, lengthOK: true, cadenceOK: false).reason == "cadence_drift")
        // All gates passing (defaults) → the clean fragment is still accepted.
        #expect(Grader.grade(features(), siblings: s, gold: flatProfile, lengthOK: true).accept)
    }

    // MARK: - gradeCadenceTake (Step 5.2 — take-level gate for role: "gaps")

    @Test
    func testGradeCadenceTakeOrdersClippedBeforeLengthBeforeCadence() {
        #expect(Grader.gradeCadenceTake(clipped: true, lengthOK: false, cadenceOK: false).reason == "clipped")
        #expect(Grader.gradeCadenceTake(clipped: false, lengthOK: false, cadenceOK: false).reason == "length")
        #expect(Grader.gradeCadenceTake(clipped: false, lengthOK: true, cadenceOK: false).reason == "cadence_drift")
    }

    @Test
    func testGradeCadenceTakeAcceptsWhenAllGatesPass() {
        let v = Grader.gradeCadenceTake(clipped: false, lengthOK: true, cadenceOK: true)
        #expect(v.accept)
        #expect(v.reason == nil)
    }
}
