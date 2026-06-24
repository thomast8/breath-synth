import XCTest
@testable import BreathEngine

final class CountedRenderTests: XCTestCase {
    /// `assembleCounted` cycles through the recording's real units to fill `count`. With two
    /// distinct units (different amplitude) and count 4 it should lay down u0,u1,u0,u1 — length =
    /// 4 units, one audible event per slot, and the alternating units must not all be identical.
    func testCyclesUnitsToFillCount() {
        let sr = 44_100.0
        let settings = AssemblerSettings(sampleRate: sr)
        let unitFrames = Int(0.4 * sr)
        let toneFrames = Int(0.1 * sr)
        func unit(freq: Double, amp: Double) -> [Float] {
            var u = [Float](repeating: 0, count: unitFrames)
            for i in 0..<toneFrames { u[i] = Float(amp * sin(2 * Double.pi * freq * Double(i) / sr)) }
            u[0] = 0
            u[u.count - 1] = 0
            return u
        }
        let units = [unit(freq: 1_000, amp: 0.5), unit(freq: 1_500, amp: 0.25)]
        let count = 4

        let out = BreathAssembler.assembleCounted(units: units, count: count, settings: settings)

        XCTAssertEqual(out.count, unitFrames * count, "cycles units to fill the requested count")

        var peaks = [Float]()
        for k in 0..<count {
            let start = k * unitFrames
            let end = min(out.count, start + toneFrames)
            peaks.append(rms(Array(out[start..<end])))
        }
        XCTAssertEqual(peaks.count, count)
        for (k, p) in peaks.enumerated() {
            XCTAssertGreaterThan(p, 0.001, "event \(k) should be audible")
        }
        let allEqual = peaks.dropFirst().allSatisfy { abs($0 - peaks[0]) < 1e-6 }
        XCTAssertFalse(allEqual, "cycling distinct units should make alternating events differ: \(peaks)")
    }

    private func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sum = samples.reduce(Float(0)) { $0 + $1 * $1 }
        return sqrt(sum / Float(samples.count))
    }
}
