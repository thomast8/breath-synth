import AVFoundation
import AppKit
import BreathBank
import BreathEngine
import Foundation
import Observation

/// Drives the guided enrollment: choose a folder, capture the mandatory room tone, then walk the
/// reference-led technique script. Capture is **automatic** — the engine's `BreathRecorder` detects
/// each take, self-terminates, and auto-advances through N takes; this model only picks the per-step
/// `CaptureDetection` (the app-layer catalog), plays the demo, files written segments, and writes
/// `captures.json`. All state is `@Observable` / main-actor (AVFoundation + AppKit).
@MainActor
@Observable
final class EnrollModel {
    enum Stage: Equatable {
        case needsOutputDir
        case roomTone
        case technique(step: Int)
        case finished
    }

    let steps = EnrollmentScript.steps
    /// The engine recorder — the view binds to its published state (phase, level, takeIndex, count).
    let recorder = BreathRecorder()

    @ObservationIgnored private var player: AVAudioPlayer?

    private(set) var stage: Stage = .needsOutputDir
    private(set) var outputDir: URL?
    /// Where reference takes are read from (bundled palette in a built .app, else ./Assets/breaths).
    var assetsDir: URL = EnrollModel.defaultAssetsDir()

    private(set) var isPlayingReference = false
    private(set) var errorMessage: String?

    /// slug → captured filenames (in order).
    private(set) var captured: [String: [String]] = [:]
    private(set) var roomToneFile: String?
    /// Room-tone noise floor for this session, fed to every later step's detection.
    @ObservationIgnored private var roomFloor: Float?

    /// First error to surface — a model-level start error, else a recorder write error.
    var displayError: String? { errorMessage ?? recorder.errorMessage }

    // MARK: - Derived UI state

    var currentStepIndex: Int { if case let .technique(step) = stage { return step }; return 0 }
    var currentStep: EnrollmentStep? {
        guard case let .technique(step) = stage, steps.indices.contains(step) else { return nil }
        return steps[step]
    }
    var totalFilesCaptured: Int { captured.values.reduce(0) { $0 + $1.count } }

    // MARK: - Output folder

    func chooseOutputDir() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use This Folder"
        panel.message = "Choose an empty folder to save this person's enrollment takes."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        outputDir = url
        captured = [:]
        roomToneFile = nil
        roomFloor = nil
        stage = .roomTone
        errorMessage = nil
    }

    // MARK: - Capture

    /// Capture the mandatory room tone (fixed 5 s, auto-stop), then advance to the first technique.
    func startRoomTone() {
        guard let dir = outputDir, !recorder.isRecording else { return }
        do {
            try recorder.start(
                takes: 1,
                detection: .fixedDuration(seconds: EnrollmentScript.roomToneSeconds),
                noiseFloorRMS: nil,
                fileURL: { _, _ in dir.appendingPathComponent("room_tone.caf") },
                onSegment: { [weak self] _, _, url, _ in self?.roomToneFile = url.lastPathComponent },
                onFinished: { [weak self] in
                    guard let self else { return }
                    self.roomFloor = self.recorder.lastNoiseFloorRMS
                    self.stage = .technique(step: 0)
                }
            )
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Begin auto-capturing the current technique's N takes (self-paced; auto-advances + auto-stops).
    func startStepCapture() {
        guard let dir = outputDir, let step = currentStep, !recorder.isRecording else { return }
        stopReference()  // never let demo playback bleed into the mic
        let stepIndex = currentStepIndex
        let slugByLabel = Dictionary(uniqueKeysWithValues: step.lanes.map { ($0.label, $0.slug) })
        do {
            try recorder.start(
                takes: step.takes,
                detection: detection(for: step),
                noiseFloorRMS: roomFloor,
                fileURL: { i, label in
                    dir.appendingPathComponent("\(slugByLabel[label] ?? "take")_\(i + 1).caf")
                },
                onSegment: { [weak self] _, label, url, _ in
                    guard let slug = slugByLabel[label] else { return }
                    self?.captured[slug, default: []].append(url.lastPathComponent)
                },
                onFinished: { [weak self] in self?.advance(fromStep: stepIndex) }
            )
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Manual override: finalize the take in progress now.
    func stopCurrentTake() { recorder.stopCurrentTake() }
    /// Manual override: discard the take in progress and re-listen for it.
    func redoCurrentTake() { recorder.cancelTake() }

    /// Map a step's catalog intent to the engine's detection contract (tuning lives here, app-side).
    private func detection(for step: EnrollmentStep) -> CaptureDetection {
        switch step.detection {
        case .cycle:
            return .cycle(minPhaseSec: step.minSeconds, midPauseSec: 0.45,
                          maxCycleSec: step.maxSeconds * 2 + 6, trailingSilenceSec: 1.0)
        case .single:
            return .single(minActiveSec: max(0.3, step.minSeconds * 0.5),
                           maxTakeSec: step.maxSeconds + 3, trailingSilenceSec: 0.8)
        case .cleanEvents:
            // Trailing silence must exceed the deliberate inter-event gap (events are well-separated),
            // so a slow gap doesn't end the take after the first event — only the real done-pause does.
            return .cleanEvents(minGapSec: 0.35, maxTakeSec: step.maxSeconds + 8, trailingSilenceSec: 3.0)
        case .naturalRhythm:
            return .naturalRhythm(minActiveSec: 1.0, maxTakeSec: step.maxSeconds + 5, trailingSilenceSec: 1.0)
        }
    }

    private func advance(fromStep step: Int) {
        if step + 1 < steps.count {
            stage = .technique(step: step + 1)
        } else {
            stage = .finished
            writeSessionManifest()
        }
    }

    // MARK: - Reference demo playback

    func playReference() {
        guard let ref = currentStep?.demoReference else { return }
        let url = assetsDir.appendingPathComponent(ref)
        guard FileManager.default.fileExists(atPath: url.path) else {
            errorMessage = "Reference \(ref) not found in \(assetsDir.path)."
            return
        }
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            player = p
            p.play()
            isPlayingReference = true
            let duration = p.duration
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(max(0.1, duration) * 1_000_000_000))
                self?.isPlayingReference = false
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stopReference() {
        player?.stop()
        player = nil
        isPlayingReference = false
    }

    // MARK: - Manifest

    private func writeSessionManifest() {
        guard let dir = outputDir else { return }
        let sessionSteps: [CaptureSession.Step] = steps.flatMap { step in
            step.lanes.map { lane in
                CaptureSession.Step(
                    slug: lane.slug, style: lane.style, type: lane.type, renderMode: step.renderMode,
                    role: lane.role, reference: lane.reference, files: captured[lane.slug] ?? [],
                    minSeconds: step.minSeconds, maxSeconds: step.maxSeconds
                )
            }
        }
        let session = CaptureSession(roomTone: roomToneFile, steps: sessionSteps)
        do {
            try session.write(to: dir.appendingPathComponent("captures.json"))
        } catch {
            errorMessage = "Failed to write captures.json: \(error.localizedDescription)"
        }
    }

    // MARK: - Assets dir

    static func defaultAssetsDir() -> URL {
        if let resources = Bundle.main.resourceURL {
            let bundled = resources.appendingPathComponent("breaths", isDirectory: true)
            if FileManager.default.fileExists(atPath: bundled.appendingPathComponent("manifest.json").path) {
                return bundled
            }
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Assets/breaths")
    }
}
