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

    /// One-shot trimming crops the quiet leading preamble (the head) but keeps the recording's quiet
    /// natural-decay tail. Same low level at both ends, treated asymmetrically: head dropped, tail kept.
    func testOneShotCropsLeadingSilenceAndKeepsDecayTail() {
        let settings = AssemblerSettings(sampleRate: sr, enableSpectralDenoise: false)
        func tone(_ amp: Double, _ i: Int) -> Float { Float(amp * sin(2 * Double.pi * 1_000 * Double(i) / sr)) }
        // preamble + loud body + quiet decay tail (preamble & tail both ~4% of peak: above the 2.5%
        // outer-silence gate, below the 5% main-body threshold).
        let pre = Int(0.4 * sr), body = Int(0.5 * sr), tail = Int(0.3 * sr), silence = Int(0.2 * sr)
        var samples = [Float](repeating: 0, count: pre + body + tail + silence)
        for i in 0..<pre { samples[i] = tone(0.02, i) }
        for i in 0..<body { samples[pre + i] = tone(0.5, i) }
        for i in 0..<tail { samples[pre + body + i] = tone(0.02, i) }

        let out = BreathAssembler.assemble(
            type: .exhale, durationSec: 3,
            clips: BreathSourceClips(oneShot: samples), settings: settings, mode: .oneShot
        )

        // Head cropped: the loud onset sits near the start, not 0.4 s of quiet preamble in.
        let a0 = Int(0.06 * sr), a1 = Int(0.12 * sr)
        XCTAssertLessThan(a1, out.count)
        XCTAssertGreaterThan(rms(Array(out[a0..<a1])), 0.1, "leading preamble should be cropped, loud onset near the start")

        // Decay tail kept: a window just past the loud body is low-but-nonzero (the quiet decay),
        // not the loud body (which would mean the head wasn't cropped) and not silence (tail cut).
        let bodyEnd = Int(0.55 * sr)
        XCTAssertLessThan(bodyEnd, out.count)
        let tailWindow = Array(out[bodyEnd..<min(out.count, bodyEnd + Int(0.25 * sr))])
        let tailRMS = rms(tailWindow)
        XCTAssertGreaterThan(tailRMS, 0.003, "natural decay tail should be retained past the body")
        XCTAssertLessThan(tailRMS, 0.1, "that region is the quiet decay, not the loud body (head was cropped)")
        XCTAssertEqual(out.last, 0, "endpoint stays click-free")
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
