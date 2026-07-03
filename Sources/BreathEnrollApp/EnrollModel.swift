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

    /// Live per-take grading state for the UI, driven by `reviewTake`. Resets to `.idle` at the start
    /// of every technique step.
    enum LiveCheck: Equatable {
        case idle
        case checking(take: Int)
        case passed(take: Int)
        case redoing(take: Int, reason: String)
        /// Grading didn't finish before `liveGradeDeadlineSec`, or no grader exists yet — the take was
        /// accepted unchecked; the offline build re-checks everything regardless.
        case keptUnchecked(take: Int)
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
    /// Take filename → that take's spectral-gate candidate diagnostics (only takes with a
    /// `spectralGate` profile populate this — see `writeSessionManifest`'s sidecar write). Field data
    /// for future threshold re-tuning; not read by the current build pipeline.
    private(set) var spectralDiagnostics: [String: [CaptureAnalyzer.SpectralCandidate]] = [:]
    private(set) var roomToneFile: String?
    /// Room-tone noise floor for this session, fed to every later step's detection.
    @ObservationIgnored private var roomFloor: Float?
    /// Created once room tone completes (needs its profile + floor); grades every technique take live.
    @ObservationIgnored private var liveGrader: LiveTakeGrader?
    private(set) var liveCheck: LiveCheck = .idle
    /// Measured (this session, real fixture): grading a packing `cores` take costs ~7-11s (denoise STFT
    /// dominates, not fixed overhead — a short frc/rv `oneShotBody` take grades in ~1.5-3s). 15s clears
    /// the worst observed case (10.7s, a 32s take) with real margin; a timeout still falls back to
    /// accept, so a slow grade never blocks the session, only skips this take's live check.
    private let liveGradeDeadlineSec = 15.0
    /// Redo policy is app-catalog data, not engine or grader logic: only signal-defect gates trigger an
    /// auto-redo. Person-dependent gates (off_technique/cadence_drift/outlier) are advisory-only —
    /// auto-redoing a person against the bundled gold's spectrum/cadence would recreate the blind
    /// retry loop that motivated this whole feature.
    private let redoReasons: Set<String> = ["clipped", "length", "dropout", "low_snr", "merged_gulp"]

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
        spectralDiagnostics = [:]
        roomToneFile = nil
        roomFloor = nil
        liveGrader = nil
        liveCheck = .idle
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
                onSegment: { [weak self] _, _, url, _, _ in self?.roomToneFile = url.lastPathComponent },
                onFinished: { [weak self] in
                    guard let self else { return }
                    self.roomFloor = self.recorder.lastNoiseFloorRMS
                    if let dir = self.outputDir, let roomToneFile = self.roomToneFile {
                        self.liveGrader = LiveTakeGrader(
                            roomToneURL: dir.appendingPathComponent(roomToneFile), assetsDir: self.assetsDir
                        )
                    }
                    self.writeSessionManifest()   // captures.json now exists (room tone recorded)
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
        liveCheck = .idle
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
                onSegment: { [weak self] _, label, url, _, spectralCandidates in
                    guard let self, let slug = slugByLabel[label] else { return }
                    self.captured[slug, default: []].append(url.lastPathComponent)
                    if !spectralCandidates.isEmpty {
                        self.spectralDiagnostics[url.lastPathComponent] = spectralCandidates
                    }
                    self.writeSessionManifest()   // persist after every segment so a quit/crash can't lose the run
                },
                onFinished: { [weak self] in self?.advance(fromStep: stepIndex) },
                onTakeReview: { [weak self] takeIndex, segments in
                    await self?.reviewTake(takeIndex: takeIndex, segments: segments, step: step) ?? .accept
                }
            )
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Grade every segment of a just-written take concurrently, racing the deadline. A timeout falls
    /// back to accept — the offline build is authoritative and never skips a check, so a slow live
    /// grade only costs this take its live signal, not correctness. Only signal-defect gates (see
    /// `redoReasons`) trigger `.redo`; person-dependent gates are advisory-only.
    private func reviewTake(
        takeIndex: Int, segments: [(label: SegmentLabel, url: URL)], step: EnrollmentStep
    ) async -> TakeReview {
        guard let grader = liveGrader else {
            liveCheck = .keptUnchecked(take: takeIndex)
            return .accept
        }
        liveCheck = .checking(take: takeIndex)
        let laneByLabel = Dictionary(uniqueKeysWithValues: step.lanes.map { ($0.label, $0) })

        let verdicts: [LiveTakeGrader.TakeVerdict]? = await withTaskGroup(of: [LiveTakeGrader.TakeVerdict]?.self) { group in
            group.addTask {
                await withTaskGroup(of: LiveTakeGrader.TakeVerdict?.self) { laneGroup in
                    for (label, url) in segments {
                        guard let lane = laneByLabel[label] else { continue }
                        laneGroup.addTask {
                            await grader.grade(
                                fileURL: url, style: lane.style, role: lane.role, type: lane.type,
                                reference: lane.reference, minSeconds: step.minSeconds, maxSeconds: step.maxSeconds
                            )
                        }
                    }
                    var results: [LiveTakeGrader.TakeVerdict] = []
                    for await verdict in laneGroup { if let verdict { results.append(verdict) } }
                    return results
                }
            }
            group.addTask { [liveGradeDeadlineSec] in
                try? await Task.sleep(nanoseconds: UInt64(liveGradeDeadlineSec * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }

        guard let verdicts else {
            liveCheck = .keptUnchecked(take: takeIndex)
            return .accept
        }
        if let worst = verdicts.first(where: { !$0.accept && redoReasons.contains($0.reason ?? "") }) {
            liveCheck = .redoing(take: takeIndex, reason: worst.reason ?? "quality")
            return .redo
        }
        liveCheck = .passed(take: takeIndex)
        return .accept
    }

    /// Manual override: finalize the take in progress now.
    func stopCurrentTake() { recorder.stopCurrentTake() }
    /// Manual override: discard the take in progress and re-listen for it.
    func redoCurrentTake() { recorder.cancelTake() }

    /// Finish the session now with whatever's been captured so far (aborting any in-progress take),
    /// writing `captures.json` so a partial enrollment is still usable by the builder.
    func finishEarly() {
        guard case .technique = stage else { return }
        recorder.abort()
        writeSessionManifest()
        stage = .finished
    }

    /// Map a step's catalog intent to the engine's detection contract (tuning lives here, app-side).
    private func detection(for step: EnrollmentStep) -> CaptureDetection {
        switch step.detection {
        case .cycle:
            return .cycle(minPhaseSec: step.minSeconds, midPauseSec: 0.45,
                          maxCycleSec: step.maxSeconds * 2 + 6, trailingSilenceSec: 1.0)
        case .single:
            return .single(minActiveSec: max(0.3, step.minSeconds * 0.5),
                           maxTakeSec: step.maxSeconds + 3, trailingSilenceSec: 0.8)
        case .finalPhase:
            // minLeadSec small — the lead phase (a real inhale before the hold) is discarded regardless
            // of how long it runs; midPauseSec matches calm's deliberate-pause split; maxTakeSec has
            // margin for the lead + pause overhead on top of the final phase's own bound.
            return .finalPhase(minLeadSec: 0.5, midPauseSec: 0.4,
                               minPhaseSec: step.minSeconds, maxTakeSec: step.maxSeconds + 6,
                               trailingSilenceSec: 0.8)
        case .cleanEvents:
            // Trailing silence must exceed the deliberate inter-event gap (events are well-separated),
            // so a slow gap doesn't end the take after the first event — only the real done-pause does.
            return .cleanEvents(minGapSec: 0.35, maxTakeSec: step.maxSeconds + 8, trailingSilenceSec: 3.0,
                                eventMinDistSec: eventMinDistSec(for: step), targetEvents: step.targetEvents,
                                spectralGate: spectralGateProfile(for: step))
        case .naturalRhythm:
            return .naturalRhythm(minActiveSec: 1.0, maxTakeSec: step.maxSeconds + 5, trailingSilenceSec: 1.0,
                                  eventMinDistSec: eventMinDistSec(for: step),
                                  spectralGate: spectralGateProfile(for: step))
        }
    }

    /// Refractory spacing between counted events, by style: recovery's hook breaths need the wider
    /// offline `hookMinDistSec` floor (matches `UnitExtractor.extract`'s double-sip merge) so an
    /// in/out pair isn't split into two events; every other counted style uses the tighter gulp floor.
    private func eventMinDistSec(for step: EnrollmentStep) -> Double {
        step.lanes.first?.style == "recovery" ? UnitExtractor.hookMinDistSec : UnitExtractor.gulpMinDistSec
    }

    /// Spectral event-shape profile, by style: packing's sharp glottal gulps and recovery's turbulent
    /// hook breaths are spectrally near-opposite (see `SpectralGateProfile.gulp`/`.hook`), so there is
    /// no shared default — every counted style picks explicitly.
    private func spectralGateProfile(for step: EnrollmentStep) -> SpectralGateProfile {
        step.lanes.first?.style == "recovery" ? .hook : .gulp
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
        writeSpectralDiagnostics(to: dir)
    }

    /// Sidecar file, not read by `breath-bank build`: per-take spectral-gate candidate diagnostics
    /// (frame, flatness, bandRatio, centroid, accepted), keyed by take filename. Field data for future
    /// `SpectralGateProfile` re-tuning or a learned classifier — see plan Step 2.4.
    private func writeSpectralDiagnostics(to dir: URL) {
        guard !spectralDiagnostics.isEmpty else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(spectralDiagnostics)
            try data.write(to: dir.appendingPathComponent("spectral_diagnostics.json"), options: .atomic)
        } catch {
            errorMessage = "Failed to write spectral_diagnostics.json: \(error.localizedDescription)"
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
