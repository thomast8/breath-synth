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
            if let notice = model.stepInsertedNotice {
                Text(notice)
                    .foregroundStyle(.orange)
                    .font(.callout)
                    .multilineTextAlignment(.center)
            }
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
            if model.outputDir != nil {
                Menu("Jump to step") {
                    ForEach(Array(model.steps.enumerated()), id: \.offset) { index, step in
                        Button(step.title) { model.jumpToStep(index) }
                    }
                }
                .font(.caption)
                .disabled(model.recorder.isRecording)
                .help("Skip straight to any technique step — useful for testing one step at a time.")
            }
            if case .technique = model.stage {
                Button("Finish & save now") { model.finishEarly() }
                    .font(.caption)
                    .help("Stop here and write captures.json with the takes recorded so far.")
            }
            if let dir = model.outputDir {
                Text(dir.lastPathComponent)
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch model.stage {
        case .needsOutputDir: chooseFolderView
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
        if step.detection == .cycle || step.detection == .finalPhase {
            Text("Each phase must last at least \(fmt(step.minSeconds))s to count.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
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
        if model.recorder.phase == .reviewing {
            ProgressView()
            Text("Checking take \(model.recorder.takeIndex + 1)…")
                .font(.callout).foregroundStyle(.secondary)
        } else {
            Text("Take \(min(model.recorder.takeIndex + 1, step.takes)) of \(step.takes)")
                .font(.title3.weight(.medium).monospacedDigit())
            Text(phaseLabel(step))
                .font(.callout).foregroundStyle(.secondary)
            if model.recorder.ambientHold {
                VStack(spacing: 6) {
                    Text("Room is too loud right now — waiting for it to quiet down before this take starts")
                        .font(.caption).foregroundStyle(.orange).multilineTextAlignment(.center)
                    Button("Record anyway") { model.recordAnywayDespiteNoise() }
                        .font(.caption)
                }
            } else if model.roomTooNoisy {
                Text("This room reads loud — gentle breaths may be hard to detect")
                    .font(.caption2).foregroundStyle(.orange)
            }
            phaseFloorHint(step)
            levelMeter
            EnrollWaveformView(peaks: model.recorder.wavePeaks)
                .frame(maxWidth: 480, minHeight: 80, maxHeight: 100)
            if step.detection == .cleanEvents || step.detection == .naturalRhythm {
                let target = step.targetEvents.map { " / ~\($0)" } ?? ""
                Text("\(model.recorder.eventCount)\(target) detected")
                    .font(.callout.monospacedDigit())
                if let target = step.targetEvents, model.recorder.eventCount >= target {
                    Text("Got all \(target) — wrapping up").font(.caption).foregroundStyle(.green)
                } else if model.recorder.gapTooClose {
                    Text("Leave a clearer gap between events").font(.caption).foregroundStyle(.orange)
                }
            }
            if let issue = model.recorder.lastTakeIssue {
                Text("Retaking — \(retakeReason(issue))")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        liveCheckBadge
        HStack(spacing: 16) {
            Button { model.stopCurrentTake() } label: {
                Label("Stop take", systemImage: "stop.circle")
            }
            // Before onset, there's nothing captured yet to finalize — flush() is a no-op in that
            // state, which read as the button silently doing nothing. Only enable it once there's
            // actually something to stop.
            .disabled(model.recorder.phase != .capturing)
            .help("Finalize this take right now with whatever's been captured so far, then move on.")
            Button { model.redoCurrentTake() } label: {
                Label("Redo this take", systemImage: "arrow.counterclockwise")
            }
            .help("Discard this take-in-progress and start listening again for the same take — "
                  + "doesn't touch any earlier take you've already completed.")
        }
        .controlSize(.large)
    }

    /// Live per-take grading verdict, once available — a quick "kept/redoing/unchecked" signal
    /// separate from `lastTakeIssue`'s structural retake messaging above.
    @ViewBuilder private var liveCheckBadge: some View {
        switch model.liveCheck {
        case .idle, .checking:
            EmptyView()
        case .passed:
            Text("Live check passed").font(.caption).foregroundStyle(.green)
        case let .redoing(_, reason):
            Text("That one \(friendlyLiveCheckReason(reason)) — going again")
                .font(.caption).foregroundStyle(.orange)
        case .keptUnchecked:
            Text("Kept as-is — the final build re-checks").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func friendlyLiveCheckReason(_ reason: String) -> String {
        switch reason {
        case "clipped": return "clipped"
        case "length": return "was the wrong length"
        case "dropout": return "had a mid-breath dropout"
        case "low_snr": return "was too quiet against the room"
        case "merged_gulp": return "had gulps too close together"
        default: return "didn't pass the quality check"
        }
    }

    /// Live readout of the current phase's elapsed time against the step's structural floor
    /// (`minSeconds` — each phase of a `cycle`, the kept phase of a `finalPhase`) — the number a
    /// rejected take's "too short" message refers to, shown while it still matters instead of after.
    @ViewBuilder private func phaseFloorHint(_ step: EnrollmentStep) -> some View {
        let phase = model.recorder.livePhase
        let appliesNow = (step.detection == .cycle && (phase == .inhale || phase == .exhale))
            || (step.detection == .finalPhase && phase == .exhale)
        if appliesNow {
            let elapsed = model.recorder.phaseElapsed
            let floor = step.minSeconds
            let met = elapsed >= floor
            Text(met ? "✓ long enough (≥\(fmt(floor))s)" : "\(fmt(elapsed))s so far — needs ≥\(fmt(floor))s")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(met ? .green : .secondary)
        } else if step.detection == .naturalRhythm && (phase == .capturing || phase == .inhale || phase == .exhale) {
            // No fixed target count by design (it's continuous cadence, not discrete events), so the
            // only "are we there yet" signal worth showing is the whole-take length floor/ceiling —
            // the same band the live grader's length check uses (`step.minSeconds`/`maxSeconds`).
            // `.inhale`/`.exhale` here means a *paired* style (recovery) — its sip alternator reports
            // those instead of `.capturing`, but the same length band still applies.
            // `phaseElapsed` (not `elapsed`) — it's relative to the confirmed onset, so it correctly
            // excludes the post-arm blackout window instead of counting that dead time as capture time.
            let elapsed = model.recorder.phaseElapsed
            let floor = step.minSeconds
            let met = elapsed >= floor
            Text(met ? "✓ long enough (≥\(fmt(floor))s) — wrap up whenever"
                     : "\(fmt(elapsed))s so far — needs ≥\(fmt(floor))s")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(met ? .green : .secondary)
        }
    }

    /// Phase-specific status text, including a running per-phase timer — replaces the old static
    /// "Capturing… (inhale, pause, exhale)" that never changed for the whole take.
    private func phaseLabel(_ step: EnrollmentStep) -> String {
        let elapsed = fmt(model.recorder.phaseElapsed)
        switch model.recorder.livePhase {
        case .waiting:
            if model.recorder.blackoutRemaining > 0 {
                // This window suppresses onset AND (Problem 2a) samples the pre-onset ambient floor —
                // "Breathe now" read as an instruction to act, when it's actually settle-and-measure time.
                return "Settling & calibrating… \(fmt(model.recorder.blackoutRemaining))s before it starts listening"
            }
            let isPairedRecovery = step.lanes.first?.style == "recovery"
            return (step.detection == .cycle || isPairedRecovery) ? "Ready — inhale when you are" : "Ready — begin when you are"
        case .inhale:
            // A paired counted style (recovery's hook breath) reports .inhale/.exhale from its sip
            // alternator, not a real timed phase like cycle/finalPhase — no elapsed timer for those.
            if step.detection == .cleanEvents || step.detection == .naturalRhythm { return "Inhale…" }
            return "Inhaling… \(elapsed)s"
        case .midPause:
            return "Pause — now exhale"
        case .exhale:
            if step.detection == .cleanEvents || step.detection == .naturalRhythm { return "Exhale…" }
            return "Exhaling… \(elapsed)s"
        case .capturing:
            return "Capturing… \(elapsed)s"
        }
    }

    /// Names the specific structural defect instead of one generic "wasn't clean" sentence.
    private func retakeReason(_ issue: CaptureAnalyzer.TakeIssue) -> String {
        switch issue {
        case .noPauseDetected: return "no pause detected between inhale and exhale"
        case .inhaleTooShort: return "inhale was too short"
        case .exhaleTooShort: return "exhale was too short"
        case let .phasesImbalanced(ratio): return String(format: "phases too lopsided (%.1fx)", ratio)
        case .noSegment: return "nothing was captured"
        case .noPauseBeforeRelease: return "no pause detected before the release"
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
                    .frame(width: geo.size.width * CGFloat(meterFraction))
            }
        }
        .frame(maxWidth: 360, maxHeight: 10)
    }

    /// Scales the meter to "how close to the take's onset/activity gate" rather than a fixed absolute
    /// amplitude — a fixed multiplier reads as nearly empty for gentle calm breathing and fine for a
    /// loud forced exhale, since the two differ by an order of magnitude in raw level.
    private var meterFraction: Double {
        let threshold = max(Double(model.recorder.activityThreshold), 0.004)
        return min(1, Double(model.recorder.level) / (threshold * 2.5))
    }

    private func fmt(_ value: Double) -> String { String(format: "%.1f", value) }
}
