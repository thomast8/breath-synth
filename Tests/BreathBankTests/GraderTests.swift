import XCTest
@testable import BreathBank
import BreathEngine

final class GraderTests: XCTestCase {
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

    func testClippingRunDetection() {
        var clean = [Float](repeating: 0.5, count: 100)
        XCTAssertFalse(Grader.clippingRun(clean, peak: 0.999, minRun: 3))
        clean[40] = 1; clean[41] = 1; clean[42] = 1; clean[43] = 1
        XCTAssertTrue(Grader.clippingRun(clean, peak: 0.999, minRun: 3))
    }

    func testGradeRejectsClipped() {
        let v = Grader.grade(features(clipped: true), siblings: normalSiblings(), gold: flatProfile, lengthOK: true)
        XCTAssertFalse(v.accept)
        XCTAssertEqual(v.reason, "clipped")
    }

    func testGradeRejectsBadLength() {
        let v = Grader.grade(features(), siblings: normalSiblings(), gold: flatProfile, lengthOK: false)
        XCTAssertEqual(v.reason, "length")
    }

    func testGradeRejectsLowSNR() {
        let v = Grader.grade(features(snrDb: 4), siblings: normalSiblings(), gold: flatProfile, lengthOK: true)
        XCTAssertEqual(v.reason, "low_snr")
    }

    // MARK: - Stage (b): sibling anomaly

    func testAnomalyFlagsOutlierNotNormal() {
        let siblings = normalSiblings()
        XCTAssertLessThan(Grader.anomalyScore(features(rmsDb: -20), siblings: siblings), 3.5)
        XCTAssertGreaterThan(Grader.anomalyScore(features(rmsDb: -3), siblings: siblings), 3.5)
    }

    func testGradeRejectsOutlier() {
        let v = Grader.grade(features(rmsDb: -3), siblings: normalSiblings(), gold: flatProfile, lengthOK: true)
        XCTAssertEqual(v.reason, "outlier")
    }

    func testTooFewSiblingsSkipsAnomaly() {
        // <3 siblings → anomaly can't be judged → score 0 (don't reject on it).
        XCTAssertEqual(Grader.anomalyScore(features(rmsDb: -3), siblings: [features(), features()]), 0)
    }

    // MARK: - Stage (c): template distance

    func testTemplateDistanceIdenticalIsZeroDifferentIsLarge() {
        XCTAssertEqual(Grader.templateDistance(features(profile: flatProfile), gold: flatProfile), 0, accuracy: 1e-9)
        var lowBand = [Float](repeating: 0, count: 513)
        for k in 0..<50 { lowBand[k] = 1 }
        XCTAssertGreaterThan(Grader.templateDistance(features(profile: flatProfile), gold: lowBand), 0.6)
    }

    func testGradeRejectsOffTechnique() {
        var lowBand = [Float](repeating: 0, count: 513)
        for k in 0..<50 { lowBand[k] = 1 }
        let v = Grader.grade(features(profile: flatProfile), siblings: normalSiblings(), gold: lowBand, lengthOK: true)
        XCTAssertEqual(v.reason, "off_technique")
    }

    // MARK: - Accept

    func testGradeAcceptsCleanFragment() {
        let v = Grader.grade(features(), siblings: normalSiblings(), gold: flatProfile, lengthOK: true)
        XCTAssertTrue(v.accept)
        XCTAssertNil(v.reason)
    }

    // MARK: - Feature extraction end-to-end (real signal)

    func testFeaturesFromNoiseBurstAreSane() {
        var rng = SeededRNG(seed: 42)
        let n = 8_000  // 0.5 s @ 16 kHz, > one 1024 STFT frame
        let raw = (0..<n).map { _ -> Float in Float(Double(rng.next()) / Double(UInt64.max) * 2 - 1) * 0.3 }
        let f = Grader.features(raw: raw, sampleRate: 16_000, roomToneProfile: nil)
        XCTAssertEqual(f.profile.count, 513)
        XCTAssertFalse(f.clipped)
        XCTAssertEqual(f.snrDb, 99, "no room tone ⇒ SNR stage is a pass-through")
        XCTAssertGreaterThan(f.flatness, 0.3, "white-ish noise should read fairly flat")
        XCTAssertEqual(f.durationSec, 0.5, accuracy: 1e-6)
    }
}
