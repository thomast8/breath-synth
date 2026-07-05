import BreathEngineCore
import Foundation

/// Portable port of `BreathEnrollApp`'s `EnrollModel` — the same guided-session orchestration on top of
/// a `TakeCaptureEngine` instead of `BreathRecorder`: walk the shared `EnrollmentScript` catalog step by
/// step, harvest room tone incrementally from each take's own pre-onset ambient (no dedicated upfront
/// room-tone step), grade every take live once enough ambient has pooled, and persist `captures.json`
/// after every written segment. AppKit's folder picker and the reference-demo `AVAudioPlayer` have no
/// server-side equivalent — `outputDir`/`assetsDir` are supplied at `init`, and demo playback is the
/// client's job (it already has the demo reference filename from the session's step catalog).
public actor EnrollmentEngine {
    public enum Stage: Sendable, Equatable {
        case idle
        case technique(step: Int)
        case finished
    }

    /// Live per-take grading state, driven by `reviewTake`. Resets to `.idle` at the start of every
    /// technique step.
    public enum LiveCheck: Sendable, Equatable {
        case idle
        case checking(take: Int)
        case passed(take: Int)
        case redoing(take: Int, reason: String)
        /// Grading didn't finish before `liveGradeDeadlineSec`, or no grader exists yet — the take was
        /// accepted unchecked; the offline build re-checks everything regardless.
        case keptUnchecked(take: Int)
    }

    /// Session transitions the WebSocket handler (Phase 4) needs to push to the client as they happen.
    /// `takeVerdict`/`stepComplete`/`sessionFinished` all originate from `TakeCaptureEngine`'s detached
    /// post-review continuation — outside any `feed()` call — so a handler can't reconstruct them by
    /// polling engine state the way it can for `detectionState`/`ambientHold` (which live on
    /// `TakeCaptureEngine`, refreshed inside `feed()`, and are fine to poll at a fixed rate instead).
    public enum Event: Sendable, Equatable {
        case roomToneReady(filename: String)
        /// One written segment (a `CaptureLane`'s file for this take) — `laneSlug` resolves against
        /// `currentStep`'s lanes for style/type/role/reference/renderMode. Fires once per lane sharing a
        /// take (a hybrid step like packing shares one physical file across two lanes/roles).
        case segmentWritten(takeIndex: Int, laneSlug: String, filename: String)
        case takeVerdict(takeIndex: Int, check: LiveCheck)
        case stepComplete(nextStepIndex: Int, insertedFallbackNotice: String?)
        case sessionFinished
    }

    /// Mutable (not `let`): the packing-core-isolation check can insert `packingSeparatedFallback`
    /// mid-session — `advance(fromStep:)`'s `step + 1 < steps.count` already tolerates a growing array.
    public private(set) var steps: [EnrollmentStep]
    /// The engine recorder — the caller polls its published state (phase, level, takeIndex, count) the
    /// same way the native UI bound to `BreathRecorder`'s `@Observable` state.
    public let engine = TakeCaptureEngine()

    private let outputDir: URL
    private let assetsDir: URL
    /// The session's fixed capture rate (the browser's mic, from its `hello` message) — `BreathRecorder`
    /// queried hardware for this; there's no hardware here, so it's supplied once at `init`.
    private let sampleRate: Double

    public private(set) var stage: Stage = .idle
    public private(set) var errorMessage: String?

    /// slug → captured filenames (in order).
    public private(set) var captured: [String: [String]] = [:]
    /// Step titles the participant explicitly declined via `skipCurrentStep()` — written into
    /// `captures.json` so an empty step reads as a deliberate skip, not a capture failure.
    public private(set) var skippedSteps: [String] = []
    /// Inter-event gaps (frames) accumulated across the current step's takes so far — reset per step in
    /// `startStepCapture()`. Used only by `checkPackingCoreIsolation` right now.
    private var currentStepIntervalsFrames: [Int] = []
    /// Set once, right after `packingSeparatedFallback` gets inserted — the caller shows it and clears it.
    public private(set) var stepInsertedNotice: String?
    /// Take filename → that take's spectral-gate candidate diagnostics (only takes with a
    /// `spectralGate` profile populate this — see `writeSessionManifest`'s sidecar write). Field data
    /// for future threshold re-tuning; not read by the current build pipeline.
    public private(set) var spectralDiagnostics: [String: [CaptureAnalyzer.SpectralCandidate]] = [:]
    public private(set) var roomToneFile: String?
    /// Seeded from the first take's own pre-onset ambient (via `engine.currentNoiseFloorRMS`), refreshed
    /// after every step — each take's own reading blends in over the session instead of a single upfront
    /// reading (there is no standalone room-tone step, see `ambientPool`).
    private var rollingFloor: Float?
    /// Pooled quiet-stretch samples harvested from each take's own pre-onset audio (see
    /// `CaptureAnalyzer.quietRangeFrames`), until there's enough to write `room_tone.wav` — see
    /// `poolAmbient`.
    private var ambientPool: [Float] = []
    /// Created once the harvested room-tone pool is written (needs its file + `assetsDir`); grades every
    /// technique take live from then on. `nil` until then — takes before that are `.keptUnchecked`.
    private var liveGrader: LiveTakeGrader?
    public private(set) var liveCheck: LiveCheck = .idle
    /// How long `reviewTake` waits for a live grade before falling back to `.keptUnchecked` — defaults to
    /// the calibrated `EnrollmentDetection.liveGradeDeadlineSec`; injectable so a test can exercise the
    /// timeout branch against a deliberately slow grade without waiting out the real 15s deadline.
    private let gradeDeadlineSec: Double
    private var eventContinuation: AsyncStream<Event>.Continuation?

    public init(
        outputDir: URL, assetsDir: URL, sampleRate: Double, steps: [EnrollmentStep] = EnrollmentScript.steps,
        gradeDeadlineSec: Double = EnrollmentDetection.liveGradeDeadlineSec
    ) {
        self.outputDir = outputDir
        self.assetsDir = assetsDir
        self.sampleRate = sampleRate
        self.steps = steps
        self.gradeDeadlineSec = gradeDeadlineSec
    }

    /// First error to surface — a session-level start error, else a capture-engine write error.
    public func displayError() async -> String? {
        if let errorMessage { return errorMessage }
        return await engine.errorMessage
    }

    // MARK: - Derived state

    public var currentStepIndex: Int { if case let .technique(step) = stage { return step }; return 0 }
    public var currentStep: EnrollmentStep? {
        guard case let .technique(step) = stage, steps.indices.contains(step) else { return nil }
        return steps[step]
    }
    public var totalFilesCaptured: Int { captured.values.reduce(0) { $0 + $1.count } }
    /// Mid-capture warning (rolling-floor based, not a single upfront reading) — see
    /// `CaptureAnalyzer.isRoomTooNoisy`.
    public func roomTooNoisy() async -> Bool {
        (await engine.currentNoiseFloorRMS).map(CaptureAnalyzer.isRoomTooNoisy) ?? false
    }

    /// Begin the session at the first technique step. The caller has already prepared `outputDir`.
    public func start() {
        stage = .technique(step: 0)
    }

    /// Subscribe to this session's transition events — call once (a second call replaces the first
    /// continuation, dropping the earlier subscriber). Finishes when the session ends, normally or via
    /// `finishEarly()`.
    public func makeEventStream() -> AsyncStream<Event> {
        AsyncStream { continuation in
            self.eventContinuation = continuation
        }
    }

    // MARK: - Capture

    /// Begin auto-capturing the current technique's N takes (self-paced; auto-advances + auto-stops).
    public func startStepCapture() async {
        guard let step = currentStep, await !engine.isRecording else { return }
        liveCheck = .idle
        stepInsertedNotice = nil
        currentStepIntervalsFrames = []
        let stepIndex = currentStepIndex
        // A hybrid step (packing) has multiple lanes sharing one `label` — the same captured file
        // serving both a "cores" and a "gaps" role — so this can't be `uniqueKeysWithValues`; every
        // lane sharing a label points at the same physical file, so the first slug is as good as any.
        let slugByLabel = Dictionary(step.lanes.map { ($0.label, $0.slug) }, uniquingKeysWith: { first, _ in first })
        let dir = outputDir
        await engine.start(
            sampleRate: sampleRate, takes: step.takes, detection: EnrollmentDetection.detection(for: step),
            noiseFloorRMS: rollingFloor,
            fileURL: { i, label in
                dir.appendingPathComponent("\(slugByLabel[label] ?? "take")_\(i + 1).wav")
            },
            onSegment: { [weak self] takeIndex, label, url, intervalsFrames, spectralCandidates in
                guard let self, let slug = slugByLabel[label] else { return }
                await self.recordSegment(
                    takeIndex: takeIndex, slug: slug, filename: url.lastPathComponent,
                    intervalsFrames: intervalsFrames, spectralCandidates: spectralCandidates)
            },
            onFinished: { [weak self] in await self?.advance(fromStep: stepIndex) },
            onTakeReview: { [weak self] takeIndex, segments in
                await self?.reviewTake(takeIndex: takeIndex, segments: segments, step: step) ?? .accept
            },
            ambientGateRMS: CaptureAnalyzer.noisyRoomFloorRMS,
            onTakeAmbient: { [weak self] samples in await self?.poolAmbient(samples) }
        )
        errorMessage = nil
    }

    /// `onSegment`'s persistence tail — files a captured segment and writes `captures.json` after every
    /// one so a quit/crash can't lose the run, exactly as `EnrollModel` did synchronously.
    private func recordSegment(
        takeIndex: Int, slug: String, filename: String, intervalsFrames: [Int],
        spectralCandidates: [CaptureAnalyzer.SpectralCandidate]
    ) async {
        captured[slug, default: []].append(filename)
        currentStepIntervalsFrames.append(contentsOf: intervalsFrames)
        if !spectralCandidates.isEmpty {
            spectralDiagnostics[filename] = spectralCandidates
        }
        writeSessionManifest()
        eventContinuation?.yield(.segmentWritten(takeIndex: takeIndex, laneSlug: slug, filename: filename))
    }

    /// Pool a take's harvested quiet stretch toward the session's room-tone file, writing it once the
    /// pool reaches `ambientPoolTargetSec` — see `ambientPool`'s doc comment for why only once.
    private func poolAmbient(_ samples: [Float]) async {
        guard roomToneFile == nil else { return }
        ambientPool.append(contentsOf: samples)
        let poolSec = Double(ambientPool.count) / sampleRate
        guard poolSec >= EnrollmentDetection.ambientPoolTargetSec else { return }
        let url = outputDir.appendingPathComponent("room_tone.wav")
        do {
            try AudioIO.writeMonoWAV(ambientPool, sampleRate: sampleRate, to: url)
            roomToneFile = url.lastPathComponent
            liveGrader = LiveTakeGrader(roomToneURL: url, assetsDir: assetsDir)
            writeSessionManifest()
            eventContinuation?.yield(.roomToneReady(filename: url.lastPathComponent))
        } catch {
            errorMessage = "Failed to write room_tone.wav: \(error.localizedDescription)"
        }
    }

    /// Escape hatch for the ambient gate: a genuinely loud room must never trap the session waiting for
    /// quiet that isn't coming.
    public func recordAnywayDespiteNoise() async {
        await engine.overrideAmbientGate()
    }

    /// Grade every segment of a just-written take concurrently, racing the deadline. A timeout falls
    /// back to accept — the offline build is authoritative and never skips a check, so a slow live
    /// grade only costs this take its live signal, not correctness. Only signal-defect gates (see
    /// `EnrollmentDetection.redoReasons`) trigger `.redo`; person-dependent gates are advisory-only.
    private func reviewTake(
        takeIndex: Int, segments: [(label: SegmentLabel, url: URL)], step: EnrollmentStep
    ) async -> TakeReview {
        guard let grader = liveGrader else {
            setLiveCheck(.keptUnchecked(take: takeIndex))
            return .accept
        }
        liveCheck = .checking(take: takeIndex)
        // A hybrid step (packing) has multiple lanes sharing one `label` — the same captured file
        // graded once per role ("cores" and "gaps") — so this groups rather than assumes uniqueness.
        let lanesByLabel = Dictionary(grouping: step.lanes, by: \.label)

        let verdicts: [LiveTakeGrader.TakeVerdict]? = await withTaskGroup(of: [LiveTakeGrader.TakeVerdict]?.self) { group in
            group.addTask {
                await withTaskGroup(of: LiveTakeGrader.TakeVerdict?.self) { laneGroup in
                    for (label, url) in segments {
                        for lane in lanesByLabel[label] ?? [] {
                            laneGroup.addTask {
                                await grader.grade(
                                    fileURL: url, style: lane.style, role: lane.role, type: lane.type,
                                    reference: lane.reference, minSeconds: step.minSeconds, maxSeconds: step.maxSeconds
                                )
                            }
                        }
                    }
                    var results: [LiveTakeGrader.TakeVerdict] = []
                    for await verdict in laneGroup { if let verdict { results.append(verdict) } }
                    return results
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(self.gradeDeadlineSec * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }

        guard let verdicts else {
            setLiveCheck(.keptUnchecked(take: takeIndex))
            return .accept
        }
        if let worst = verdicts.first(where: { !$0.accept && EnrollmentDetection.redoReasons.contains($0.reason ?? "") }) {
            setLiveCheck(.redoing(take: takeIndex, reason: worst.reason ?? "quality"))
            return .redo
        }
        setLiveCheck(.passed(take: takeIndex))
        return .accept
    }

    /// Sets `liveCheck` and emits the matching `takeVerdict` event together, so the two can never drift.
    /// Not used for `.checking` (an in-progress status, not a verdict) or `.idle` (reset, not a result).
    private func setLiveCheck(_ check: LiveCheck) {
        liveCheck = check
        let takeIndex: Int
        switch check {
        case let .passed(take), let .redoing(take, _), let .keptUnchecked(take): takeIndex = take
        case .idle, .checking: return
        }
        eventContinuation?.yield(.takeVerdict(takeIndex: takeIndex, check: check))
    }

    /// Manual override: finalize the take in progress now.
    public func stopCurrentTake() async { await engine.stopCurrentTake() }
    /// Manual override: discard the take in progress and re-listen for it.
    public func redoCurrentTake() async { await engine.cancelTake() }

    /// Manual override: the participant doesn't know this technique. Abandons whatever's in progress
    /// for the current step (no partial takes are kept — same `abort()` `finishEarly()` uses) and
    /// advances exactly as a normal completion would, so the corpus simply has zero files for this
    /// step's lanes, with the step's title recorded (`skippedSteps`) so that reads in `captures.json`
    /// as a deliberate decision rather than a stalled or broken capture.
    public func skipCurrentStep() async {
        guard case let .technique(step) = stage, steps.indices.contains(step) else { return }
        await engine.abort()
        skippedSteps.append(steps[step].title)
        await advance(fromStep: step)
    }

    /// Finish the session now with whatever's been captured so far (aborting any in-progress take),
    /// writing `captures.json` so a partial enrollment is still usable by the builder.
    public func finishEarly() async {
        guard case .technique = stage else { return }
        await engine.abort()
        writeSessionManifest()
        stage = .finished
        eventContinuation?.yield(.sessionFinished)
        eventContinuation?.finish()
    }

    /// Dev/testing shortcut: jump straight to any technique step instead of walking the whole script.
    /// The room-tone pool need not have filled yet — the analyzer just falls back to `absActivityFloor`
    /// — but if it has, `rollingFloor`/`liveGrader` (both already session-scoped, not step-scoped) carry
    /// over untouched.
    public func jumpToStep(_ index: Int) async {
        guard steps.indices.contains(index), await !engine.isRecording else { return }
        liveCheck = .idle
        stage = .technique(step: index)
    }

    /// After "Packing" (natural rhythm) finishes, checks whether its own gulps were spaced widely enough
    /// to double as clean cores (see PR #11's real-data finding: natural packing cadence usually clears
    /// this, unlike recovery's reliably-tighter hook cadence). If not, inserts `packingSeparatedFallback`
    /// right after this step instead of assuming every session needs it up front.
    private func checkPackingCoreIsolation(justCompletedStepIndex index: Int) {
        guard steps.indices.contains(index),
              steps[index].lanes.contains(where: { $0.slug == "packing_cadence" }) else { return }
        defer { currentStepIntervalsFrames = [] }
        guard let minGapFrames = currentStepIntervalsFrames.min() else { return }
        let minGapSec = Double(minGapFrames) / sampleRate
        guard minGapSec < EnrollmentDetection.packingCoreIsolationSec else { return }
        steps.insert(EnrollmentScript.packingSeparatedFallback, at: index + 1)
        stepInsertedNotice = "Your natural packing rhythm ran a bit tight (\(String(format: "%.2f", minGapSec))s "
            + "between some gulps) for clean isolated samples, so a quick separated round got added next."
    }

    private func advance(fromStep step: Int) async {
        rollingFloor = await engine.currentNoiseFloorRMS ?? rollingFloor
        checkPackingCoreIsolation(justCompletedStepIndex: step)
        if step + 1 < steps.count {
            stage = .technique(step: step + 1)
            eventContinuation?.yield(.stepComplete(nextStepIndex: step + 1, insertedFallbackNotice: stepInsertedNotice))
        } else {
            stage = .finished
            writeSessionManifest()
            eventContinuation?.yield(.sessionFinished)
            eventContinuation?.finish()
        }
    }

    // MARK: - Manifest

    private func writeSessionManifest() {
        let sessionSteps: [CaptureSession.Step] = steps.flatMap { step in
            step.lanes.map { lane in
                CaptureSession.Step(
                    slug: lane.slug, style: lane.style, type: lane.type, renderMode: step.renderMode,
                    role: lane.role, reference: lane.reference, files: captured[lane.slug] ?? [],
                    minSeconds: step.minSeconds, maxSeconds: step.maxSeconds
                )
            }
        }
        let session = CaptureSession(
            roomTone: roomToneFile, steps: sessionSteps,
            skippedSteps: skippedSteps.isEmpty ? nil : skippedSteps)
        do {
            try session.write(to: outputDir.appendingPathComponent("captures.json"))
        } catch {
            errorMessage = "Failed to write captures.json: \(error.localizedDescription)"
        }
        writeSpectralDiagnostics()
    }

    /// Sidecar file, not read by `breath-bank build`: per-take spectral-gate candidate diagnostics
    /// (frame, flatness, bandRatio, centroid, accepted), keyed by take filename. Field data for future
    /// `SpectralGateProfile` re-tuning or a learned classifier.
    private func writeSpectralDiagnostics() {
        guard !spectralDiagnostics.isEmpty else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(spectralDiagnostics)
            try data.write(to: outputDir.appendingPathComponent("spectral_diagnostics.json"), options: .atomic)
        } catch {
            errorMessage = "Failed to write spectral_diagnostics.json: \(error.localizedDescription)"
        }
    }
}
