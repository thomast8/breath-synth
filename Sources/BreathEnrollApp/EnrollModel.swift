import AVFoundation
import AppKit
import BreathBank
import BreathEngine
import Foundation
import Observation

/// Drives the guided enrollment: choose a folder, capture the mandatory room tone, then walk the
/// reference-led technique script recording N takes each, and finally write `captures.json` for the
/// `breath-bank` builder. All state is `@Observable` and main-actor isolated (AVFoundation + AppKit).
@MainActor
@Observable
final class EnrollModel {
    enum Stage: Equatable {
        case needsOutputDir
        case roomTone
        case technique(step: Int, take: Int)
        case finished
    }

    let steps = EnrollmentScript.steps

    private let recorder = AudioRecorder()
    private var player: AVAudioPlayer?
    private var elapsedTask: Task<Void, Never>?
    private var recordingStart: Date?

    private(set) var stage: Stage = .needsOutputDir
    private(set) var outputDir: URL?
    /// Where reference takes are read from (bundled palette in a built .app, else ./Assets/breaths).
    var assetsDir: URL = EnrollModel.defaultAssetsDir()

    private(set) var isRecording = false
    private(set) var isPlayingReference = false
    private(set) var level: Float = 0
    private(set) var elapsed: Double = 0
    private(set) var errorMessage: String?

    /// slug → captured filenames (in order).
    private(set) var captured: [String: [String]] = [:]
    private(set) var roomToneFile: String?

    // MARK: - Derived UI state

    var currentStep: EnrollmentStep? {
        guard case let .technique(step, _) = stage, steps.indices.contains(step) else { return nil }
        return steps[step]
    }
    var currentTakeIndex: Int {
        if case let .technique(_, take) = stage { return take }
        return 0
    }
    var totalTakesCaptured: Int { captured.values.reduce(0) { $0 + $1.count } }

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
        stage = .roomTone
        errorMessage = nil
    }

    // MARK: - Recording

    /// Begin recording the current phase (room tone or a technique take).
    func startRecording() {
        guard let dir = outputDir, !isRecording else { return }
        let url = dir.appendingPathComponent(currentFilename())
        do {
            try recorder.start(writingTo: url) { [weak self] level in
                self?.level = level
            }
            isRecording = true
            elapsed = 0
            recordingStart = Date()
            startElapsedTimer()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Stop the current recording, file it, and advance.
    func stopRecording() {
        guard isRecording else { return }
        recorder.stop()
        isRecording = false
        level = 0
        stopElapsedTimer()
        commitCurrentFile()
    }

    /// Drop the most recent take and step back so it can be recorded again.
    func redoLastTake() {
        guard !isRecording else { return }
        switch stage {
        case .roomTone:
            roomToneFile = nil
        case let .technique(step, take):
            if take > 0 {
                removeLastCapture(ofStep: step)
                stage = .technique(step: step, take: take - 1)
            } else if step > 0 {
                removeLastCapture(ofStep: step - 1)
                stage = .technique(step: step - 1, take: steps[step - 1].takes - 1)
            }
        default:
            break
        }
    }

    private func removeLastCapture(ofStep step: Int) {
        let slug = steps[step].slug
        if captured[slug]?.isEmpty == false { captured[slug]?.removeLast() }
    }

    // MARK: - Reference playback

    func playReference() {
        guard let step = currentStep, let ref = step.reference else { return }
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

    // MARK: - Advancement

    private func commitCurrentFile() {
        switch stage {
        case .roomTone:
            roomToneFile = currentFilename()
            stage = .technique(step: 0, take: 0)
        case let .technique(step, take):
            let s = steps[step]
            captured[s.slug, default: []].append(currentFilename())
            let nextTake = take + 1
            if nextTake < s.takes {
                stage = .technique(step: step, take: nextTake)
            } else if step + 1 < steps.count {
                stage = .technique(step: step + 1, take: 0)
            } else {
                stage = .finished
                writeSessionManifest()
            }
        default:
            break
        }
    }

    private func writeSessionManifest() {
        guard let dir = outputDir else { return }
        let sessionSteps = steps.map { step in
            CaptureSession.Step(
                slug: step.slug, style: step.style, type: step.type, renderMode: step.renderMode,
                role: step.role, reference: step.reference, files: captured[step.slug] ?? [],
                minSeconds: step.minSeconds, maxSeconds: step.maxSeconds
            )
        }
        let session = CaptureSession(roomTone: roomToneFile, steps: sessionSteps)
        do {
            try session.write(to: dir.appendingPathComponent("captures.json"))
        } catch {
            errorMessage = "Failed to write captures.json: \(error.localizedDescription)"
        }
    }

    // MARK: - Filenames

    private func currentFilename() -> String {
        switch stage {
        case .roomTone: return "room_tone.caf"
        case let .technique(step, take): return "\(steps[step].slug)_\(take + 1).caf"
        default: return "unused.caf"
        }
    }

    // MARK: - Elapsed timer

    private func startElapsedTimer() {
        elapsedTask?.cancel()
        elapsedTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, let start = self.recordingStart else { return }
                self.elapsed = Date().timeIntervalSince(start)
                try? await Task.sleep(nanoseconds: 50_000_000)  // ~20 fps
            }
        }
    }

    private func stopElapsedTimer() {
        elapsedTask?.cancel()
        elapsedTask = nil
        recordingStart = nil
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
