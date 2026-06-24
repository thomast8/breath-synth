import XCTest
@testable import BreathEngine

final class OneShotAssemblerTests: XCTestCase {
    private let sr = 44_100.0

    /// A 1 kHz tone-burst source: 0.5 s of tone (above the 260 Hz low-cut) followed by
    /// 0.5 s of silence. Used as the `oneShot` clip for both render modes below.
    private func toneBurstClips() -> BreathSourceClips {
        let toneFrames = Int(0.5 * sr)
        let silenceFrames = Int(0.5 * sr)
        var samples = [Float](repeating: 0, count: toneFrames + silenceFrames)
        for i in 0..<toneFrames {
            samples[i] = Float(0.5 * sin(2 * Double.pi * 1_000 * Double(i) / sr))
        }
        return BreathSourceClips(oneShot: samples)
    }

    func testOneShotReturnsNaturalLengthNotRequestedDuration() {
        // Denoise off: this exercises the mode dispatch + natural-length clamp, not the
        // spectral denoiser (which would perturb the tone).
        let settings = AssemblerSettings(sampleRate: sr, enableSpectralDenoise: false)
        let out = BreathAssembler.assemble(
            type: .exhale, durationSec: 3, clips: toneBurstClips(), settings: settings, mode: .oneShot
        )

        // `prepareSource` trims the trailing silence, so the natural length is ~the 0.5 s tone
        // plus the ~0.1 s trim pad — far short of the 3 s of frames a textured render would loop
        // to fill, and close to a SINGLE copy of the tone (no looped repetition).
        let threeSecFrames = Int((3 * sr).rounded())
        XCTAssertLessThan(out.count, threeSecFrames / 2, "one-shot should ignore the 3 s duration")
        XCTAssertGreaterThan(out.count, Int(0.4 * sr), "one-shot should keep the natural tone length")
        XCTAssertLessThan(out.count, Int(0.8 * sr), "natural length is ~one copy of the tone, not a looped fill")
        XCTAssertGreaterThan(rms(out), 0.01, "the tone should be audible")
    }

    func testTexturedFillsRequestedDuration() {
        let settings = AssemblerSettings(sampleRate: sr, enableSpectralDenoise: false)
        let out = BreathAssembler.assemble(
            type: .exhale, durationSec: 3, clips: toneBurstClips(), settings: settings, mode: .textured
        )
        XCTAssertEqual(out.count, Int((3 * sr).rounded()), "textured render fills the exact duration")
    }

    private func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sum = samples.reduce(Float(0)) { $0 + $1 * $1 }
        return sqrt(sum / Float(samples.count))
    }
}
