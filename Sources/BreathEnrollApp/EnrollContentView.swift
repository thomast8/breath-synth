import SwiftUI

/// Guided breath-enrollment UI: pick a folder → mandatory room tone → per-technique
/// reference-play-then-record-N-takes → done. Drives `EnrollModel`.
struct EnrollContentView: View {
    @State private var model = EnrollModel()

    var body: some View {
        VStack(spacing: 20) {
            header
            Divider()
            content
            Spacer(minLength: 0)
            if let error = model.errorMessage {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.callout)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Breath Enroll").font(.title.weight(.semibold))
                Text("\(model.totalTakesCaptured) takes captured")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let dir = model.outputDir {
                Text(dir.lastPathComponent)
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch model.stage {
        case .needsOutputDir: chooseFolderView
        case .roomTone: roomToneView
        case .technique: techniqueView
        case .finished: finishedView
        }
    }

    private var chooseFolderView: some View {
        VStack(spacing: 16) {
            Text("Choose a folder to save this person's enrollment takes.")
                .multilineTextAlignment(.center)
            Button("Choose Enrollment Folder…") { model.chooseOutputDir() }
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity)
    }

    private var roomToneView: some View {
        VStack(spacing: 16) {
            Text("Step 1 — Room tone").font(.headline)
            Text("Sit still and stay silent for about \(Int(EnrollmentScript.roomToneSeconds)) seconds. "
                 + "This captures your room's background so recording quality can be graded. "
                 + "(Required, and never reused between sessions.)")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            levelMeter
            recordControls
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var techniqueView: some View {
        if let step = model.currentStep {
            VStack(spacing: 16) {
                Text("\(step.style.capitalized) \(step.type.rawValue) — take \(model.currentTakeIndex + 1) of \(step.takes)")
                    .font(.headline)
                Text(step.prompt)
                    .multilineTextAlignment(.center).foregroundStyle(.secondary).padding(.horizontal)
                Text("Target ~\(fmt(step.minSeconds))–\(fmt(step.maxSeconds)) s")
                    .font(.caption).foregroundStyle(.tertiary)
                if step.reference != nil {
                    Button {
                        model.isPlayingReference ? model.stopReference() : model.playReference()
                    } label: {
                        Label(model.isPlayingReference ? "Stop reference" : "Play reference",
                              systemImage: "speaker.wave.2")
                    }
                    .disabled(model.isRecording)
                }
                levelMeter
                recordControls
                Button("Re-record previous take") { model.redoLastTake() }
                    .buttonStyle(.plain).foregroundStyle(.secondary).font(.caption)
                    .disabled(model.isRecording)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var finishedView: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44)).foregroundStyle(.green)
            Text("Enrollment complete").font(.headline)
            Text("\(model.totalTakesCaptured) takes written to \(model.outputDir?.lastPathComponent ?? "the folder"), "
                 + "plus captures.json for the bank builder.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var levelMeter: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4).fill(.quaternary)
                RoundedRectangle(cornerRadius: 4)
                    .fill(model.isRecording ? Color.green : Color.gray)
                    .frame(width: geo.size.width * CGFloat(min(1, model.level * 4)))
            }
        }
        .frame(maxWidth: 360, maxHeight: 10)
    }

    @ViewBuilder private var recordControls: some View {
        if model.isRecording {
            Button(role: .destructive) { model.stopRecording() } label: {
                Label("Stop  ·  \(fmt(model.elapsed)) s", systemImage: "stop.circle.fill")
            }
            .controlSize(.large)
        } else {
            Button { model.startRecording() } label: {
                Label("Record", systemImage: "record.circle")
            }
            .controlSize(.large).tint(.red)
        }
    }

    private func fmt(_ value: Double) -> String { String(format: "%.1f", value) }
}
