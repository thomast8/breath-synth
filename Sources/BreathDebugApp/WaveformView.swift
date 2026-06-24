import SwiftUI

/// One downsampled column of a waveform: the min/max sample value over the bucket it covers.
struct WavePeak: Equatable {
    var min: Float
    var max: Float
}

/// Draws a mono waveform from precomputed min/max peaks. Optional `boundaries` (fractions in 0...1)
/// drop faint vertical guides at phase/cycle joins so the breath structure is visible at a glance.
struct WaveformView: View {
    let peaks: [WavePeak]
    var boundaries: [Double] = []

    var body: some View {
        Canvas { context, size in
            let midY = size.height / 2
            // Zero axis.
            var axis = Path()
            axis.move(to: CGPoint(x: 0, y: midY))
            axis.addLine(to: CGPoint(x: size.width, y: midY))
            context.stroke(axis, with: .color(.secondary.opacity(0.35)), lineWidth: 0.5)

            // Segment boundaries.
            for fraction in boundaries where fraction > 0 && fraction < 1 {
                let x = size.width * fraction
                var line = Path()
                line.move(to: CGPoint(x: x, y: 0))
                line.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(line, with: .color(.orange.opacity(0.45)), lineWidth: 0.75)
            }

            guard !peaks.isEmpty else { return }
            let columnWidth = size.width / CGFloat(peaks.count)
            var wave = Path()
            for (index, peak) in peaks.enumerated() {
                let x = CGFloat(index) * columnWidth + columnWidth / 2
                let top = midY - CGFloat(max(peak.max, 0.00001)) * midY
                let bottom = midY - CGFloat(min(peak.min, -0.00001)) * midY
                wave.move(to: CGPoint(x: x, y: top))
                wave.addLine(to: CGPoint(x: x, y: bottom))
            }
            context.stroke(wave, with: .color(.accentColor), lineWidth: max(0.75, columnWidth * 0.9))
        }
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            if peaks.isEmpty {
                Text("Render a breath to see its waveform")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
