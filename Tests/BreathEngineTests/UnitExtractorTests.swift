import XCTest
@testable import BreathEngine

final class UnitExtractorTests: XCTestCase {
    /// Three 1 kHz tone-bursts spaced 1 s apart (well beyond the ~0.7 s event min-distance): the
    /// extractor should split them into exactly three real segments, each carrying energy, so the
    /// counted path can replay the actual events rather than a cloned exemplar.
    func testThreeSpacedBurstsGiveThreeUnits() {
        let sr = 44_100.0
        let toneFrames = Int(0.1 * sr)
        let periodFrames = Int(1.0 * sr) // 0.1 s tone + 0.9 s silence — events 1 s apart
        let burstCount = 3

        var signal = [Float](repeating: 0, count: periodFrames * burstCount)
        for burst in 0..<burstCount {
            let base = burst * periodFrames
            for i in 0..<toneFrames {
                signal[base + i] = Float(0.5 * sin(2 * Double.pi * 1_000 * Double(i) / sr))
            }
        }

        let (units, count) = UnitExtractor.extract(from: signal, sampleRate: sr)

        XCTAssertEqual(count, burstCount, "expected 3 detected events")
        XCTAssertEqual(units.count, burstCount)
        for unit in units {
            XCTAssertGreaterThan(unit.count, 1)
            XCTAssertGreaterThan(unit.reduce(Float(0)) { $0 + $1 * $1 }, 0, "each unit must carry energy")
        }
        // Concatenating the units stays within the source (segments are non-overlapping slices).
        XCTAssertLessThanOrEqual(units.map(\.count).reduce(0, +), signal.count)
    }
}
