import BreathEngine
import SwiftUI

/// Live waveform for a take in progress. Modeled on `BreathDebugApp/WaveformView.swift`'s drawing
/// approach (apps can't import each other, so the drawing shell is duplicated; the data comes from the
/// engine's `BreathRecorder.wavePeaks`, which grows as the take is captured — this view just redraws
/// from whatever it's handed, min/max-downsampled to a bounded column count so a long counted take
/// never gets more expensive to draw than a short one).
struct EnrollWaveformView: View {
    let peaks: [WavePeak]

    /// Never draw more columns than this — long counted takes (up to `maxTakeSec`) would otherwise
    /// grow the segment count unboundedly; downsampling keeps draw cost flat.
    private static let maxColumns = 1600

    var body: some View {
        Canvas { context, size in
            let midY = size.height / 2
            var axis = Path()
            axis.move(to: CGPoint(x: 0, y: midY))
            axis.addLine(to: CGPoint(x: size.width, y: midY))
            context.stroke(axis, with: .color(.secondary.opacity(0.35)), lineWidth: 0.5)

            let drawn = Self.downsample(peaks, to: Self.maxColumns)
            guard !drawn.isEmpty else { return }
            // Auto-gain to the take's own observed peak: a fixed ±1.0 scale (right for a loud forced
            // exhale) draws a genuinely gentle calm breath as a near-flat line, since its raw amplitude
            // sits an order of magnitude lower. Filling to 85% of half-height keeps a little headroom.
            let peakAmplitude = drawn.reduce(Float(0)) { max($0, max(abs($1.min), abs($1.max))) }
            let gain: Float = peakAmplitude > 0.0005 ? 0.85 / peakAmplitude : 1
            let columnWidth = size.width / CGFloat(drawn.count)
            var wave = Path()
            for (index, peak) in drawn.enumerated() {
                let x = CGFloat(index) * columnWidth + columnWidth / 2
                let top = midY - CGFloat(max(peak.max * gain, 0.00001)) * midY
                let bottom = midY - CGFloat(min(peak.min * gain, -0.00001)) * midY
                wave.move(to: CGPoint(x: x, y: top))
                wave.addLine(to: CGPoint(x: x, y: bottom))
            }
            context.stroke(wave, with: .color(.accentColor), lineWidth: max(0.75, columnWidth * 0.9))
        }
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            if peaks.isEmpty {
                Text("Listening…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Merge adjacent buckets (min of mins, max of maxes) until the column count is at most `limit`.
    /// A no-op below the limit, so short takes draw at full resolution.
    static func downsample(_ peaks: [WavePeak], to limit: Int) -> [WavePeak] {
        guard peaks.count > limit, limit > 0 else { return peaks }
        let groupSize = Int((Double(peaks.count) / Double(limit)).rounded(.up))
        var result: [WavePeak] = []
        result.reserveCapacity((peaks.count + groupSize - 1) / groupSize)
        var i = 0
        while i < peaks.count {
            let end = min(peaks.count, i + groupSize)
            var lo: Float = .greatestFiniteMagnitude
            var hi: Float = -.greatestFiniteMagnitude
            for peak in peaks[i..<end] {
                lo = min(lo, peak.min)
                hi = max(hi, peak.max)
            }
            result.append(WavePeak(min: lo, max: hi))
            i = end
        }
        return result
    }
}
