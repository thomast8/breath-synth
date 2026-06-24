import BreathEngine
import SwiftUI

struct ContentView: View {
    @State private var model = DebugModel()

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                controlsPane
                    .frame(width: 380)
                Divider()
                outputPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer
        }
        .toolbar { transport }
        .onAppear { model.start() }
    }

    // MARK: - Transport toolbar

    @ToolbarContentBuilder private var transport: some ToolbarContent {
        ToolbarItemGroup {
            Picker("Mode", selection: $model.task) {
                ForEach(DebugModel.DebugTask.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .help("Which render path to exercise")

            Button("Render", systemImage: "waveform") { model.render() }
                .help("Render the current parameters and show the waveform (no audio)")
            Button("Play", systemImage: "play.fill") { model.play() }
                .help("Render and play. Loops when the Loop toggle is on (cycle / sequence)")
            Button("Stop", systemImage: "stop.fill") { model.stop() }
                .help("Stop playback")
            Button("Save WAV", systemImage: "square.and.arrow.down") { model.saveWAV() }
                .help("Render the current parameters to a 32-bit float WAV file")
        }
    }

    // MARK: - Controls (left)

    private var controlsPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                engineSection
                if let error = model.loadError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                switch model.task {
                case .single: singleControls
                case .counted: countedControls
                case .cycle: cycleControls
                case .sequence: sequenceControls
                }
            }
            .padding()
        }
    }

    private var engineSection: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TextField("Assets directory", text: $model.assetsPath)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.caption, design: .monospaced))
                        .onSubmit { model.reloadEngine() }
                    Button("Reload") { model.reloadEngine() }
                }
                Toggle("Spectral denoise", isOn: $model.denoiseEnabled).toggleStyle(.switch)
                sliderRow("Over-sub", $model.denoiseOversub, 1.0...3.0, step: 0.05, unit: "×")
                    .disabled(!model.denoiseEnabled)
                sliderRow("Floor", $model.denoiseFloor, 0.0...0.2, step: 0.005, unit: "")
                    .disabled(!model.denoiseEnabled)
                sliderRow("Crossfade", $model.crossfadeSec, 0.2...1.5, step: 0.05, unit: "s")
                Text("Crossfade affects textured styles only and the engine floors it at 0.7s, so values below that sound identical.")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Engine config changes apply on the next render.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.top, 6)
        } label: {
            HStack {
                Label("Engine", systemImage: "gearshape").font(.headline)
                Spacer()
                Text("\(model.styles.count) styles").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Single

    private var singleControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Single breath", "One exact-duration breath (textured / one-shot styles)")
            stylePicker("Style", selection: $model.singleStyle, options: model.singleStyles)
                .onChange(of: model.singleStyle) { _, _ in model.onSingleStyleChanged() }
            styleBadge(model.singleStyle)
            directionPicker(selection: $model.singleType, options: model.directions(for: model.singleStyle))
            sliderRow("Duration", $model.singleDuration, 1...30, step: 0.5, unit: "s")
            seedField("Seed", text: $model.singleSeedText)
            Toggle("Variation", isOn: $model.singleVariationEnabled).toggleStyle(.switch)
            sliderRow("Gain wobble", $model.singleVarGainDb, 0...6, step: 0.5, unit: "dB")
                .disabled(!model.singleVariationEnabled)
            sliderRow("Rate wobble", $model.singleVarRatePct, 0...8, step: 0.5, unit: "%")
                .disabled(!model.singleVariationEnabled)
            sliderRow("Master gain", $model.singleGain, 0.1...2.0, step: 0.05, unit: "×")
        }
    }

    // MARK: Counted

    private var countedControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Counted", "Recovery breaths / packing gulps — a count of discrete events")
            if model.countedStyles.isEmpty {
                Text("No counted styles in this palette.").foregroundStyle(.secondary)
            } else {
                stylePicker("Style", selection: $model.countedStyle, options: model.countedStyles)
                    .onChange(of: model.countedStyle) { _, _ in model.onCountedStyleChanged() }
                styleBadge(model.countedStyle)
                directionPicker(selection: $model.countedType, options: model.directions(for: model.countedStyle))
                HStack {
                    Text("Count").frame(width: 90, alignment: .leading)
                    TextField("detected", text: $model.countedCountText)
                        .textFieldStyle(.roundedBorder)
                    Text("blank = auto").font(.caption2).foregroundStyle(.tertiary)
                }
                seedField("Seed", text: $model.countedSeedText)
            }
        }
    }

    // MARK: Cycle

    private var cycleControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Cycle", "Inhale → hold → exhale → hold. Inhale and exhale can use different styles.")
            stylePicker("Inhale style", selection: $model.cycleInhaleStyle, options: model.inhaleStyles)
            sliderRow("Inhale", $model.cycleInhaleDur, 1...30, step: 0.5, unit: "s")
            sliderRow("Hold in", $model.cycleHoldIn, 0...20, step: 0.5, unit: "s")
            stylePicker("Exhale style", selection: $model.cycleExhaleStyle, options: model.exhaleStyles)
            sliderRow("Exhale", $model.cycleExhaleDur, 1...30, step: 0.5, unit: "s")
            sliderRow("Hold out", $model.cycleHoldOut, 0...20, step: 0.5, unit: "s")
            Toggle("Loop forever", isOn: $model.cycleLoop).toggleStyle(.switch)
            HStack {
                Text("Cycles").frame(width: 90, alignment: .leading)
                Stepper("\(model.cycleCount)", value: $model.cycleCount, in: 1...50)
                    .disabled(model.cycleLoop)
            }
        }
    }

    // MARK: Sequence

    private var sequenceControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Sequence", "Fill a total with a whole number of cycles (one style, both directions).")
            stylePicker("Style", selection: $model.seqStyle, options: model.sequenceStyles)
            sliderRow("Total", $model.seqTotal, 4...300, step: 1, unit: "s")
            sliderRow("Inhale", $model.seqInhaleDur, 1...30, step: 0.5, unit: "s")
            sliderRow("Hold in", $model.seqHoldIn, 0...20, step: 0.5, unit: "s")
            sliderRow("Exhale", $model.seqExhaleDur, 1...30, step: 0.5, unit: "s")
            sliderRow("Hold out", $model.seqHoldOut, 0...20, step: 0.5, unit: "s")
            seedField("Seed", text: $model.seqSeedText)
            Toggle("Closest (render nearest fit)", isOn: $model.seqClosest).toggleStyle(.switch)
            Toggle("Loop forever", isOn: $model.seqLoop).toggleStyle(.switch)
            Label(model.sequencePreview, systemImage: "ruler")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Output (right)

    private var outputPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            statusLine
            WaveformView(peaks: model.waveform, boundaries: model.boundaries)
                .frame(height: 200)
            if let stats = model.stats { statsView(stats) }
            Divider()
            logView
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private var statusLine: some View {
        switch model.phase {
        case .idle:
            Text("Idle").foregroundStyle(.secondary)
        case .rendering:
            Label("Rendering…", systemImage: "waveform").foregroundStyle(.secondary)
        case .playing:
            Label("Playing…", systemImage: "speaker.wave.2.fill").foregroundStyle(.green)
        case .looping:
            Label("Looping — press Stop to end", systemImage: "repeat").foregroundStyle(.green)
        case .error(let message):
            Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func statsView(_ stats: DebugModel.RenderStats) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(stats.detail).font(.callout).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 24) {
                metric(stats.totalSec == nil ? "duration" : "per cycle", String(format: "%.2f s", stats.durationSec))
                if let total = stats.totalSec {
                    metric("total", String(format: "%.2f s", total))
                }
                metric("frames", "\(stats.frames)")
                metric("peak", dbLabel(stats.peakDb))
                metric("rms", dbLabel(stats.rmsDb))
                metric("render", String(format: "%.0f ms", stats.renderMs))
            }
        }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.system(.body, design: .monospaced)).monospacedDigit()
        }
    }

    private var logView: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Event log").font(.headline)
                Spacer()
                Button("Clear", action: model.clearLog).font(.caption)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(model.log.suffix(200)) { line in
                        Text("\(line.event)  \(line.text)")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(line.event == "error" ? .red : .primary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 160)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("live stream:  curl -N \(model.streamURL)")
            Text("log file:  \(model.logPath)")
        }
        .font(.system(.caption2, design: .monospaced))
        .foregroundStyle(.tertiary)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    // MARK: - Reusable controls

    private func sectionTitle(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.headline)
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func stylePicker(_ title: String, selection: Binding<String>, options: [DebugModel.StyleInfo]) -> some View {
        HStack {
            Text(title).frame(width: 90, alignment: .leading)
            Picker(title, selection: selection) {
                ForEach(options) { Text($0.name).tag($0.name) }
            }
            .labelsHidden()
        }
    }

    private func styleBadge(_ name: String) -> some View {
        let info = model.info(for: name)
        let dirs = (info?.directions ?? []).map(\.rawValue).joined(separator: " + ")
        return Text("mode: \(info?.mode.rawValue ?? "—")   ·   \(dirs.isEmpty ? "no directions" : dirs)")
            .font(.caption2).foregroundStyle(.tertiary)
    }

    private func directionPicker(selection: Binding<BreathType>, options: [BreathType]) -> some View {
        HStack {
            Text("Direction").frame(width: 90, alignment: .leading)
            Picker("Direction", selection: selection) {
                ForEach(options, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(options.count < 2)
        }
    }

    private func seedField(_ title: String, text: Binding<String>) -> some View {
        HStack {
            Text(title).frame(width: 90, alignment: .leading)
            TextField("stable", text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(.caption, design: .monospaced))
            Button {
                model.randomizeSeed()
            } label: {
                Image(systemName: "die.face.5")
            }
            .help("Randomize seed")
        }
    }

    private func sliderRow(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, step: Double, unit: String) -> some View {
        HStack {
            Text(title).frame(width: 90, alignment: .leading)
            Slider(value: value, in: range, step: step)
            Text(valueLabel(value.wrappedValue, unit))
                .font(.system(.caption, design: .monospaced))
                .frame(width: 58, alignment: .trailing)
        }
    }

    private func valueLabel(_ value: Double, _ unit: String) -> String {
        let formatted = abs(value.rounded() - value) < 1e-9
            ? String(format: "%.0f", value)
            : String(format: "%.2f", value)
        return unit.isEmpty ? formatted : "\(formatted)\(unit)"
    }

    private func dbLabel(_ db: Double) -> String {
        db.isFinite ? String(format: "%.1f dB", db) : "−∞ dB"
    }
}
