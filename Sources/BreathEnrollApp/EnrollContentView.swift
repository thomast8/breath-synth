import BreathEngine
import SwiftUI

/// Guided breath-enrollment UI: pick a folder → mandatory room tone → per-technique demo-then-record.
/// Capture is automatic: each take self-terminates and auto-advances, so the UI is pure bindings to
/// `EnrollModel` / its `BreathRecorder` plus Stop/Redo overrides. No DSP here.
struct EnrollContentView: View {
    @State private var model = EnrollModel()

    var body: some View {
        VStack(spacing: 20) {
            header
            Divider()
            content
            Spacer(minLength: 0)
            if let error = model.displayError {
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
                Text("\(model.totalFilesCaptured) segments captured")
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
            Text("Sit still and stay silent. Recording stops itself after "
                 + "\(Int(EnrollmentScript.roomToneSeconds)) seconds. "
                 + "This captures your room's background to grade recording quality (never reused between sessions).")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            levelMeter
            if model.recorder.isRecording {
                let left = max(0, EnrollmentScript.roomToneSeconds - model.recorder.elapsed)
                Text("Recording room tone… \(fmt(left)) s left").font(.callout.monospacedDigit())
            } else {
                Button { model.startRoomTone() } label: {
                    Label("Start room tone", systemImage: "record.circle")
                }
                .controlSize(.large).tint(.red)
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var techniqueView: some View {
        if let step = model.currentStep {
            VStack(spacing: 16) {
                Text("\(step.title) — step \(model.currentStepIndex + 1) of \(model.steps.count)")
                    .font(.headline)
                Text(step.prompt)
                    .multilineTextAlignment(.center).foregroundStyle(.secondary).padding(.horizontal)

                if model.recorder.isRecording {
                    captureStatus(step)
                } else {
                    armControls(step)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder private func armControls(_ step: EnrollmentStep) -> some View {
        Text("\(step.takes) take\(step.takes == 1 ? "" : "s") · ~\(fmt(step.minSeconds))–\(fmt(step.maxSeconds)) s each")
            .font(.caption).foregroundStyle(.tertiary)
        if step.demoReference != nil {
            Button {
                model.isPlayingReference ? model.stopReference() : model.playReference()
            } label: {
                Label(model.isPlayingReference ? "Stop demo" : "Play demo", systemImage: "speaker.wave.2")
            }
        }
        Button { model.startStepCapture() } label: {
            Label("Start - auto-records \(step.takes) takes", systemImage: "record.circle")
        }
        .controlSize(.large).tint(.red)
        .disabled(model.isPlayingReference)
    }

    @ViewBuilder private func captureStatus(_ step: EnrollmentStep) -> some View {
        Text("Take \(min(model.recorder.takeIndex + 1, step.takes)) of \(step.takes)")
            .font(.title3.weight(.medium).monospacedDigit())
        Text(phaseLabel(step))
            .font(.callout).foregroundStyle(.secondary)
        levelMeter
        if step.detection == .cleanEvents || step.detection == .naturalRhythm {
            let target = step.targetEvents.map { " / ~\($0)" } ?? ""
            Text("\(model.recorder.eventCount)\(target) detected")
                .font(.callout.monospacedDigit())
            if model.recorder.gapTooClose {
                Text("Leave a clearer gap between events").font(.caption).foregroundStyle(.orange)
            }
        }
        if model.recorder.invalidTakes > 0 {
            Text("Retaking — last attempt wasn't a clean inhale → pause → exhale")
                .font(.caption).foregroundStyle(.orange)
        }
        HStack(spacing: 16) {
            Button { model.stopCurrentTake() } label: {
                Label("Stop take", systemImage: "stop.circle")
            }
            Button { model.redoCurrentTake() } label: {
                Label("Redo", systemImage: "arrow.counterclockwise")
            }
        }
        .controlSize(.large)
    }

    private func phaseLabel(_ step: EnrollmentStep) -> String {
        switch model.recorder.phase {
        case .idle: return "…"
        case .waitingForOnset:
            return step.detection == .cycle ? "Ready — inhale when you are" : "Ready — begin when you are"
        case .capturing:
            return step.detection == .cycle ? "Capturing… (inhale, pause, exhale)" : "Capturing…"
        }
    }

    private var finishedView: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44)).foregroundStyle(.green)
            Text("Enrollment complete").font(.headline)
            Text("\(model.totalFilesCaptured) segments written to \(model.outputDir?.lastPathComponent ?? "the folder"), "
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
                    .fill(model.recorder.isRecording ? Color.green : Color.gray)
                    .frame(width: geo.size.width * CGFloat(min(1, model.recorder.level * 4)))
            }
        }
        .frame(maxWidth: 360, maxHeight: 10)
    }

    private func fmt(_ value: Double) -> String { String(format: "%.1f", value) }
}
