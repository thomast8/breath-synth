import Testing
import Foundation
@testable import BreathEngine

struct UnitExtractorTests {
    /// Three 1 kHz tone-bursts spaced 1 s apart (well beyond the ~0.7 s event min-distance): the
    /// extractor should split them into exactly three real segments, each carrying energy, so the
    /// counted path can replay the actual events rather than a cloned exemplar.
    @Test
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

        #expect(count == burstCount, "expected 3 detected events")
        #expect(units.count == burstCount)
        for unit in units {
            #expect(unit.count > 1)
            #expect(unit.reduce(Float(0)) { $0 + $1 * $1 } > 0, "each unit must carry energy")
        }
        // Concatenating the units stays within the source (segments are non-overlapping slices).
        #expect(units.map(\.count).reduce(0, +) <= signal.count)
    }

    // MARK: minDistSec (Step 5.1 — style-aware event spacing)

    /// Two bursts 0.5 s apart: at `hookMinDistSec` (0.70) they merge into one event (a double-sip);
    /// at `gulpMinDistSec` (0.22) they resolve as two. Locks in the style-aware spacing this session
    /// added to align `Segmenter`'s bank-side geometry with the engine's own `extract` render path.
    @Test
    func testGulpCoreRangesMinDistSecMergesOrSplitsBySpacing() {
        let sr = 44_100.0
        let toneFrames = Int(0.1 * sr)
        let gapFrames = Int(0.5 * sr)
        var signal = [Float](repeating: 0, count: toneFrames * 2 + gapFrames + Int(0.3 * sr))
        for burst in 0..<2 {
            let base = burst * (toneFrames + gapFrames)
            for i in 0..<toneFrames {
                signal[base + i] = Float(0.5 * sin(2 * Double.pi * 1_000 * Double(i) / sr))
            }
        }

        let merged = UnitExtractor.gulpCoreRanges(from: signal, sampleRate: sr, minDistSec: UnitExtractor.hookMinDistSec)
        #expect(merged.count == 1, "0.5s apart must merge under the 0.70s hook floor")

        let split = UnitExtractor.gulpCoreRanges(from: signal, sampleRate: sr, minDistSec: UnitExtractor.gulpMinDistSec)
        #expect(split.count == 2, "0.5s apart must stay separate under the 0.22s gulp floor")
    }

    @Test
    func testRhythmGapsMinDistSecMergesOrSplitsBySpacing() {
        let sr = 44_100.0
        let toneFrames = Int(0.1 * sr)
        let gapFrames = Int(0.5 * sr)
        var signal = [Float](repeating: 0, count: toneFrames * 3 + gapFrames * 2 + Int(0.3 * sr))
        for burst in 0..<3 {
            let base = burst * (toneFrames + gapFrames)
            for i in 0..<toneFrames {
                signal[base + i] = Float(0.5 * sin(2 * Double.pi * 1_000 * Double(i) / sr))
            }
        }

        // The greedy peak-picker doesn't necessarily collapse every close peak into one survivor (the
        // highest-energy peak wins locally; a peak far enough from *that* one still survives), so this
        // asserts fewer detected gaps under the wider hook floor, not an exact merge-to-one-event count.
        let merged = UnitExtractor.rhythmGaps(from: signal, sampleRate: sr, minDistSec: UnitExtractor.hookMinDistSec)
        let split = UnitExtractor.rhythmGaps(from: signal, sampleRate: sr, minDistSec: UnitExtractor.gulpMinDistSec)
        #expect(split.count == 2, "three 0.5s-apart bursts stay separate under the 0.22s gulp floor — two gaps")
        #expect(merged.count < split.count, "the 0.70s hook floor must merge at least one adjacent pair")
    }
}
