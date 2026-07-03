import AVFoundation
import Foundation
import Observation

/// Records breath takes from the default input device with **automatic, self-terminating** capture.
/// The engine-side peer of ``BreathPlayer``: it owns the `AVAudioEngine` input tap, drives a
/// ``CaptureAnalyzer`` per take on the tap's serial queue, writes each detected segment to disk, and
/// publishes observable progress for a thin GUI. The app supplies the per-take ``CaptureDetection``
/// (from its technique catalog) and file URLs; all DSP/stop logic lives here.
///
/// One `start(...)` captures `takes` takes back-to-back, self-paced: it waits for onset, segments the
/// take, auto-advances on the silence between takes, and calls `onFinished` after the last. A `cycle`
/// take is structurally validated (two balanced phases) before it's written; an invalid one is
/// auto-redone rather than saved. macOS has no `AVAudioSession`; the engine taps hardware directly,
/// and the first start triggers the OS microphone prompt (needs `NSMicrophoneUsageDescription`).
@MainActor
@Observable
public final class BreathRecorder {
    public enum Phase: Sendable { case idle, waitingForOnset, capturing, reviewing }

    // MARK: Observable UI state

    public private(set) var isRecording = false
    public private(set) var phase: Phase = .idle
    /// Fine-grained phase within the current take (armed/inhale/pause/exhale/capturing) — richer than
    /// `phase`, which only distinguishes waiting-for-onset from capturing.
    public private(set) var livePhase: CaptureAnalyzer.LivePhase = .waiting
    /// Seconds elapsed since `livePhase` began (e.g. seconds into the current inhale).
    public private(set) var phaseElapsed: Double = 0
    /// Downsampled min/max waveform of the take captured so far, for a live scrolling display.
    public private(set) var wavePeaks: [WavePeak] = []
    /// Smoothed input level in ~[0, 1] for a meter.
    public private(set) var level: Float = 0
    /// The current take's onset/activity gate level — lets a UI meter show "how close to triggering"
    /// rather than assuming a fixed absolute amplitude range. 0 before a take is armed.
    public private(set) var activityThreshold: Float = 0
    /// Seconds left in this take's post-arm onset blackout (see `CaptureAnalyzer.blackoutSec`), or 0 if
    /// none applies / it has elapsed — lets the UI show a "breathe now" countdown instead of a silent gap.
    public private(set) var blackoutRemaining: Double = 0
    /// Seconds captured in the current take.
    public private(set) var elapsed: Double = 0
    /// 0-based index of the take currently being captured.
    public private(set) var takeIndex = 0
    /// Live count of detected events in the current take (cleanEvents / naturalRhythm).
    public private(set) var eventCount = 0
    /// Takes auto-rejected this session — either the structural guard or (once reviewing) a live-grade
    /// `.redo` verdict — surfaced as "let's retake that".
    public private(set) var invalidTakes = 0
    /// Why the most recently finalized take was rejected, or `nil` if it was accepted. Cleared when a
    /// new take is armed.
    public private(set) var lastTakeIssue: CaptureAnalyzer.TakeIssue?
    /// `true` when the last counted event fell within the clean-separation gap (UI "leave a gap" hint).
    public private(set) var gapTooClose = false
    /// Mean room-tone level from the most recent `fixedDuration` take — the noise floor for later steps.
    public private(set) var lastNoiseFloorRMS: Float?
    /// The rolling noise floor's current value (see `RollingNoiseFloor`) — each take's own pre-onset
    /// ambient blends in as it finalizes, so this reflects conditions close to *now*, not a single
    /// session-start reading. `nil` until the first take with a usable pre-onset window finalizes.
    public private(set) var currentNoiseFloorRMS: Float?
    public private(set) var errorMessage: String?

    // MARK: Config (per start)

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private var box: CaptureBox?
    /// The hardware's actual capture rate (not necessarily `AudioConstants.workingSampleRate` — that's
    /// the offline processing rate everything gets resampled to on load). Public so a consumer can
    /// convert a `segmentReady`/`onSegment` interval (in frames) to seconds correctly.
    public private(set) var sampleRate = AudioConstants.workingSampleRate
    @ObservationIgnored private var detection: CaptureDetection = .fixedDuration(seconds: 5)
    /// Seeded from `start(...)`'s `noiseFloorRMS` argument, then updated after every non-fixed take from
    /// that take's own pre-onset ambient (`RollingNoiseFloor` — see its doc comment for why the blend is
    /// asymmetric). A take's own floor can't gate its own onset (the threshold is fixed at analyzer
    /// `init`, before that take's audio exists), so this always feeds the *next* take.
    @ObservationIgnored private var rollingFloor = RollingNoiseFloor()
    @ObservationIgnored private var takes = 1
    @ObservationIgnored private var isCycle = false
    /// `finalPhase` (FRC/RV's deliberate-pause split): structurally validated and auto-redone the same
    /// way a `cycle` is, via the shared `takeRetries` counter below.
    @ObservationIgnored private var isFinalPhase = false
    @ObservationIgnored private var isFixed = false
    @ObservationIgnored private var minPhaseFrames = 0
    @ObservationIgnored private var fileURL: (@MainActor (Int, SegmentLabel) -> URL)?
    @ObservationIgnored private var onSegment: (@MainActor (Int, SegmentLabel, URL, [Int], [CaptureAnalyzer.SpectralCandidate]) -> Void)?
    @ObservationIgnored private var onFinished: (@MainActor () -> Void)?
    /// Async per-take grade the app can hook in; `nil` (the default) skips review entirely — a
    /// structurally-valid take is emitted immediately, exactly as before this existed.
    @ObservationIgnored private var onTakeReview: (@MainActor (_ takeIndex: Int, _ segments: [(label: SegmentLabel, url: URL)]) async -> TakeReview)?
    /// `true` while a written-but-unemitted take awaits its `onTakeReview` verdict. The box stays
    /// disarmed for the whole wait (set false by `CaptureBox.consume` on `takeEnded`), so mic input
    /// during review can't start a take — the between-takes recovery breath can't false-trigger onset.
    @ObservationIgnored private var reviewing = false
    @ObservationIgnored private var configObserver: NSObjectProtocol?
    /// Consecutive auto-rejected takes (any structurally-invalid cause: `cycle`, `finalPhase`, or a
    /// live-grade `.redo`); after `maxTakeRetries` the next take is force-accepted so a user who can't
    /// produce a valid take is never trapped in an infinite redo.
    @ObservationIgnored private var takeRetries = 0
    @ObservationIgnored private let maxTakeRetries = 3

    public init() {}

    // MARK: Public API

    /// Capture `takes` takes with `detection`, writing each segment via `fileURL(takeIndex, label)`.
    /// `onSegment` fires per written file; `onFinished` after the last take. `noiseFloorRMS` (from a
    /// prior room-tone take) gates activity/event detection.
    public func start(
        takes: Int,
        detection: CaptureDetection,
        noiseFloorRMS: Float?,
        fileURL: @escaping @MainActor (_ takeIndex: Int, _ label: SegmentLabel) -> URL,
        onSegment: @escaping @MainActor (
            _ takeIndex: Int, _ label: SegmentLabel, _ url: URL, _ intervalsFrames: [Int],
            _ spectralCandidates: [CaptureAnalyzer.SpectralCandidate]
        ) -> Void,
        onFinished: @escaping @MainActor () -> Void,
        onTakeReview: (@MainActor (_ takeIndex: Int, _ segments: [(label: SegmentLabel, url: URL)]) async -> TakeReview)? = nil
    ) throws {
        guard !isRecording else { return }
        let authorization = AVCaptureDevice.authorizationStatus(for: .audio)
        guard authorization != .denied, authorization != .restricted else {
            throw BreathError.ioFailure(
                "microphone access is off. Enable it in System Settings > Privacy & Security > Microphone.")
        }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw BreathError.ioFailure("no usable microphone input device was found")
        }

        sampleRate = format.sampleRate
        self.detection = detection
        rollingFloor = RollingNoiseFloor(value: noiseFloorRMS)
        currentNoiseFloorRMS = rollingFloor.value
        self.takes = max(1, takes)
        self.fileURL = fileURL
        self.onSegment = onSegment
        self.onFinished = onFinished
        self.onTakeReview = onTakeReview
        reviewing = false
        isFixed = detection.isFixedDuration
        isCycle = detection.isCycle
        isFinalPhase = detection.isFinalPhase
        minPhaseFrames = Int((detection.minPhaseSec ?? 0) * sampleRate)

        takeIndex = 0
        invalidTakes = 0
        takeRetries = 0
        eventCount = 0
        elapsed = 0
        gapTooClose = false
        errorMessage = nil
        lastTakeIssue = nil
        livePhase = .waiting
        phaseElapsed = 0
        wavePeaks = []

        let box = CaptureBox(analyzer: CaptureAnalyzer(sampleRate: sampleRate, detection: detection, noiseFloorRMS: rollingFloor.value))
        box.armed = true
        self.box = box

        // `AVAudioNodeTapBlock` carries no `@Sendable`/`NS_SWIFT_SENDABLE` annotation in the SDK header,
        // so a closure literal written here would otherwise infer this class's MainActor isolation and
        // trap at runtime the instant AVAudioEngine invokes it on its real-time render thread. `@Sendable`
        // forces it non-isolated so it actually runs where AVFoundation calls it.
        input.installTap(onBus: 0, bufferSize: 4_096, format: format) { @Sendable [box, weak self] buffer, _ in
            let mono = BreathRecorder.downmix(buffer)
            let request: FinalizeRequest? = box.lock.withLock {
                // Between takes there's no analyzer envelope worth reading, so fall back to raw
                // per-buffer RMS just to keep the meter alive; while armed, the analyzer's smoothed
                // envelope (20ms window/10ms hop) reads far less jumpy than raw RMS.
                guard box.armed else {
                    box.level = BreathRecorder.rms(mono)
                    return nil
                }
                box.buffer.append(contentsOf: mono)
                box.foldIntoWaveform(mono)
                let events = box.analyzer.ingest(mono)
                box.level = box.analyzer.currentLevel
                return box.consume(events)
            }
            Task { @MainActor in self?.publishSnapshot() }
            if let request { Task { @MainActor in self?.finalize(request) } }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw BreathError.ioFailure("starting audio engine: \(error.localizedDescription)")
        }
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isRecording else { return }
                self.errorMessage = "The audio input device changed; recording stopped. Restart this step."
                self.abort()
            }
        }
        isRecording = true
        phase = isFixed ? .capturing : .waitingForOnset
    }

    /// Manual override: finalize the in-progress take now (writes what's captured so far).
    public func stopCurrentTake() {
        guard isRecording, let box else { return }
        let request: FinalizeRequest? = box.lock.withLock {
            guard box.armed else { return nil }
            return box.consume(box.analyzer.flush())
        }
        if let request { finalize(request) }
    }

    /// Manual override: discard the in-progress take and re-listen for the same take index. Also
    /// invalidates any pending `onTakeReview` wait — its verdict, whenever it arrives, will see
    /// `reviewing == false` and drop (`TakeGate.resolve`'s staleness guard).
    public func cancelTake() {
        guard isRecording else { return }
        reviewing = false
        arm()
        publishSnapshot()
    }

    /// Stop the whole session immediately without finalizing or calling `onFinished`.
    public func abort() { teardown() }

    // MARK: Take lifecycle (main actor)

    private func finalize(_ request: FinalizeRequest) {
        guard isRecording, let fileURL, onSegment != nil else { return }
        if isFixed {
            lastNoiseFloorRMS = request.meanFloor
        } else if let ambient = request.preOnsetFloor {
            // Blended in regardless of what this take's outcome turns out to be below (even a redone
            // take's pre-onset ambient is real, valid data about current conditions).
            rollingFloor.update(with: ambient)
            currentNoiseFloorRMS = rollingFloor.value
        }

        let issue = takeIssue(request)
        lastTakeIssue = issue
        if issue != nil { invalidTakes += 1 }

        // Only `cycle`/`finalPhase` gate on their structural issue; every other kind's `takeIssue` only
        // ever returns `.noSegment`, which is unreachable in practice (every other state's `flush()`
        // always emits a segment before `takeEnded`) — preserved as a defensive non-gating fallback,
        // matching this check's original behavior before the shared retry cap existed.
        let retryEligible = isCycle || isFinalPhase
        let structurallyValid = issue == nil || !retryEligible
        // Nothing to review or write if a flush produced no segments at all — accept it as before.
        let decision: TakeGate.Decision = request.segments.isEmpty
            ? .emit
            : TakeGate.decide(structurallyValid: structurallyValid, retries: takeRetries,
                              maxRetries: maxTakeRetries, hasReviewer: onTakeReview != nil)
        print("[PHASE4] TakeGate.decide: takeIndex=\(takeIndex) structurallyValid=\(structurallyValid) retries=\(takeRetries) hasReviewer=\(onTakeReview != nil) -> \(decision)")

        if decision == .redoNow {
            takeRetries += 1
            arm()
            publishSnapshot()
            return
        }
        takeRetries = 0

        // Write now regardless of `.emit` vs `.review` — only firing `onSegment` (which registers the
        // take with the app / `captures.json`) is conditional. The deterministic `fileURL(takeIndex,
        // label)` means a later `.redo` overwrites these same files in place: no orphan, no duplicate
        // registration, since `onSegment` never fires for a take that gets redone.
        var written: [(label: SegmentLabel, url: URL)] = []
        for segment in request.segments {
            let url = fileURL(takeIndex, segment.label)
            do {
                try BreathRecorder.writeMono(segment.samples, sampleRate: sampleRate, to: url)
            } catch {
                errorMessage = (error as? BreathError)?.description ?? error.localizedDescription
                teardown()
                return
            }
            written.append((segment.label, url))
        }

        if decision == .emit {
            emit(written, request: request)
            return
        }

        // .review — hold for the app's async grade. The box is already disarmed (set by
        // `CaptureBox.consume` on `takeEnded`), so no new take can start while this waits.
        reviewing = true
        phase = .reviewing
        let reviewIndex = takeIndex
        print("[PHASE4] entering .reviewing, takeIndex=\(reviewIndex), waiting for onTakeReview")
        Task { @MainActor [weak self] in
            guard let self, let onTakeReview = self.onTakeReview else { return }
            let verdict = await onTakeReview(reviewIndex, written)
            // `takeIndex` cannot have moved during the wait — the box stays disarmed the whole time,
            // so nothing else can call `finalize`/`emit` to advance it. Safe to reuse `written` as-is.
            let stale = !(self.isRecording && self.reviewing)
            let outcome = TakeGate.resolve(verdict: verdict, isStale: stale)
            print("[PHASE4] TakeGate.resolve: takeIndex=\(reviewIndex) stale=\(stale) -> \(outcome)")
            switch outcome {
            case .drop:
                break
            case .redo:
                self.reviewing = false
                self.invalidTakes += 1
                self.takeRetries += 1
                self.arm()
                self.publishSnapshot()
            case .emit:
                self.reviewing = false
                self.emit(written, request: request)
            }
        }
    }

    /// Fire `onSegment` for already-written segments and advance the session — the shared tail of the
    /// immediate-accept and post-review-accept paths.
    private func emit(_ written: [(label: SegmentLabel, url: URL)], request: FinalizeRequest) {
        guard let onSegment else { return }
        for (label, url) in written {
            onSegment(takeIndex, label, url, request.intervals, request.spectralCandidates)
        }
        takeIndex += 1
        if takeIndex >= takes {
            let finished = onFinished
            teardown()
            finished?()
        } else {
            arm()
            publishSnapshot()
        }
    }

    /// Structural validity guard. A `cycle` take must be exactly two phases, each ≥ `minPhaseFrames`
    /// and balanced — the analyzer/grader can't tell calm inhale from exhale, so this is the backstop
    /// against a missing or false mid-pause. A `finalPhase` take must have reached the deliberate pause
    /// (exactly one kept segment) and that segment must be ≥ `minPhaseFrames`. Every other take just
    /// needs a segment. Returns the reason the take failed, or `nil` if it's valid.
    private func takeIssue(_ request: FinalizeRequest) -> CaptureAnalyzer.TakeIssue? {
        if isCycle {
            guard request.reason != .incomplete, request.segments.count == 2 else {
                print("[PHASE4-CYCLE] noPauseDetected — reason=\(request.reason) segments=\(request.segments.count)")
                return .noPauseDetected
            }
            let inhaleSec = Double(request.segments[0].samples.count) / sampleRate
            let exhaleSec = Double(request.segments[1].samples.count) / sampleRate
            let issue = CaptureAnalyzer.cycleIssue(
                inhaleFrames: request.segments[0].samples.count,
                exhaleFrames: request.segments[1].samples.count,
                minPhaseFrames: minPhaseFrames
            )
            print("[PHASE4-CYCLE] inhale=\(String(format: "%.2f", inhaleSec))s exhale=\(String(format: "%.2f", exhaleSec))s minPhaseSec=\(String(format: "%.2f", Double(minPhaseFrames) / sampleRate)) -> \(issue.map { "\($0)" } ?? "valid")")
            return issue
        }
        if isFinalPhase {
            guard request.reason != .incomplete, request.segments.count == 1 else { return .noPauseBeforeRelease }
            return request.segments[0].samples.count < minPhaseFrames ? .exhaleTooShort : nil
        }
        return request.segments.isEmpty ? .noSegment : nil
    }

    private func arm() {
        guard let box else { return }
        let detection = detection
        let noiseFloor = rollingFloor.value
        let sampleRate = sampleRate
        box.lock.withLock {
            box.analyzer = CaptureAnalyzer(sampleRate: sampleRate, detection: detection, noiseFloorRMS: noiseFloor)
            box.buffer.removeAll(keepingCapacity: true)
            box.segments.removeAll(keepingCapacity: true)
            box.hasOnset = false
            box.armed = true
            box.resetWaveform()
        }
        eventCount = 0
        elapsed = 0
        gapTooClose = false
        livePhase = .waiting
        phaseElapsed = 0
        wavePeaks = []
    }

    private func teardown() {
        guard isRecording else { return }
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        box = nil
        isRecording = false
        reviewing = false
        phase = .idle
        level = 0
    }

    private func publishSnapshot() {
        guard isRecording, let box else { return }
        // Hold-for-review: the box is disarmed for the whole wait, same as between ordinary takes, so
        // the ~11Hz tap snapshot below would otherwise stomp `phase` back to `.waitingForOnset`.
        if reviewing { return }
        let snapshot = box.lock.withLock {
            (level: box.level, count: box.analyzer.eventCount, frames: box.buffer.count,
             armed: box.armed, onset: box.hasOnset, gap: box.analyzer.lastGapWithinMin,
             livePhase: box.analyzer.livePhase, phaseFrames: box.analyzer.phaseElapsedFrames,
             peaks: box.wavePeaks, threshold: box.analyzer.currentActivityThreshold,
             blackoutSec: box.analyzer.blackoutSec)
        }
        // Display-only ballistics: the analyzer's raw envelope updates every ~10ms hop and is exactly
        // right for gating, but redrawing a meter at that resolution reads as flicker to the eye. Faster
        // attack than release (classic VU-meter behavior) keeps the bar responsive to an actual breath
        // starting while settling smoothly rather than chattering between callbacks. Detection itself
        // never reads this — only `level`, the published UI value.
        let rate: Float = snapshot.level > level ? 0.6 : 0.12
        level += (snapshot.level - level) * rate
        activityThreshold = snapshot.threshold
        eventCount = snapshot.count
        elapsed = Double(snapshot.frames) / sampleRate
        blackoutRemaining = snapshot.onset ? 0 : max(0, snapshot.blackoutSec - elapsed)
        gapTooClose = snapshot.gap
        livePhase = snapshot.livePhase
        phaseElapsed = Double(snapshot.phaseFrames) / sampleRate
        wavePeaks = snapshot.peaks
        if isFixed {
            phase = .capturing
        } else {
            phase = snapshot.armed && snapshot.onset ? .capturing : .waitingForOnset
        }
    }

    // MARK: Audio helpers (nonisolated, called from the tap thread)

    private nonisolated static func downmix(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return [] }
        let frames = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        var mono = [Float](repeating: 0, count: frames)
        for c in 0..<channelCount {
            let ptr = channels[c]
            for i in 0..<frames { mono[i] += ptr[i] }
        }
        if channelCount > 1 {
            let scale = 1 / Float(channelCount)
            for i in 0..<frames { mono[i] *= scale }
        }
        return mono
    }

    private nonisolated static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        return (sum / Float(samples.count)).squareRoot()
    }

    /// Write mono Float samples as 32-bit-float CAF at `sampleRate` (lossless; the builder resamples
    /// on load). Mirrors `BreathBank.AudioIO.writeMonoWAV`, which the engine can't depend on.
    private nonisolated static func writeMono(_ samples: [Float], sampleRate: Double, to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false
        ) else {
            throw BreathError.audioFormatUnavailable
        }
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings)
            let frameCount = AVAudioFrameCount(max(1, samples.count))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
                throw BreathError.audioFormatUnavailable
            }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            if let channel = buffer.floatChannelData, !samples.isEmpty {
                samples.withUnsafeBufferPointer { src in
                    channel[0].update(from: src.baseAddress!, count: samples.count)
                }
            }
            try file.write(from: buffer)
        } catch let error as BreathError {
            throw error
        } catch {
            throw BreathError.ioFailure("writing \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }
}

/// A finalized take's data, handed from the tap thread to the main actor. `Sendable`.
private struct FinalizeRequest: Sendable {
    struct Segment: Sendable {
        let label: SegmentLabel
        let samples: [Float]
    }
    let segments: [Segment]
    let reason: CaptureAnalyzer.EndReason
    let intervals: [Int]
    let meanFloor: Float
    /// This take's own pre-onset ambient percentile (see `CaptureAnalyzer.preOnsetFloorRMS`) — `nil` if
    /// the armed wait was too short to estimate one. Feeds the rolling noise floor for the *next* take.
    let preOnsetFloor: Float?
    let spectralCandidates: [CaptureAnalyzer.SpectralCandidate]
}

/// One bucket of a downsampled waveform: the min/max sample over its frame range. Cheap to draw (one
/// vertical segment per bucket) and cheap to build incrementally as audio arrives.
public struct WavePeak: Sendable, Equatable {
    public var min: Float
    public var max: Float

    public init(min: Float, max: Float) {
        self.min = min
        self.max = max
    }
}

/// Mutable capture state, touched on the tap serial queue and (under `lock`) the main actor.
private final class CaptureBox: @unchecked Sendable {
    /// Frames folded into one `WavePeak` bucket (~11.6ms at 44.1kHz — ~86 buckets/s; a 33s max take is
    /// ~2850 buckets, a few KB).
    static let waveBucketFrames = 512

    let lock = NSLock()
    var analyzer: CaptureAnalyzer
    var buffer: [Float] = []
    var segments: [FinalizeRequest.Segment] = []
    var armed = false
    var hasOnset = false
    var level: Float = 0
    var wavePeaks: [WavePeak] = []
    private var bucketMin: Float = .greatestFiniteMagnitude
    private var bucketMax: Float = -.greatestFiniteMagnitude
    private var bucketCount = 0

    init(analyzer: CaptureAnalyzer) { self.analyzer = analyzer }

    /// Fold newly-ingested samples into the waveform's min/max buckets. Must be called holding `lock`.
    func foldIntoWaveform(_ mono: [Float]) {
        for sample in mono {
            bucketMin = min(bucketMin, sample)
            bucketMax = max(bucketMax, sample)
            bucketCount += 1
            if bucketCount >= Self.waveBucketFrames {
                wavePeaks.append(WavePeak(min: bucketMin, max: bucketMax))
                bucketMin = .greatestFiniteMagnitude
                bucketMax = -.greatestFiniteMagnitude
                bucketCount = 0
            }
        }
    }

    /// Clear the waveform for a fresh take. Must be called holding `lock`.
    func resetWaveform() {
        wavePeaks.removeAll(keepingCapacity: true)
        bucketMin = .greatestFiniteMagnitude
        bucketMax = -.greatestFiniteMagnitude
        bucketCount = 0
    }

    /// Process analyzer events: slice finished segments out of `buffer`, and on `takeEnded` disarm and
    /// return the finalize request. Must be called holding `lock`.
    func consume(_ events: [CaptureAnalyzer.Event]) -> FinalizeRequest? {
        for event in events {
            switch event {
            case .onset:
                hasOnset = true
            case .eventDetected:
                break
            case let .segmentReady(label, start, end):
                let lo = max(0, min(start, buffer.count))
                let hi = max(lo, min(end, buffer.count))
                segments.append(FinalizeRequest.Segment(label: label, samples: Array(buffer[lo..<hi])))
            case let .takeEnded(reason):
                armed = false
                return FinalizeRequest(
                    segments: segments, reason: reason,
                    intervals: analyzer.intervalsFrames, meanFloor: analyzer.meanFloorRMS(),
                    preOnsetFloor: analyzer.preOnsetFloorRMS,
                    spectralCandidates: analyzer.spectralCandidates
                )
            }
        }
        return nil
    }
}

private extension CaptureDetection {
    var isFixedDuration: Bool { if case .fixedDuration = self { return true }; return false }
    var isCycle: Bool { if case .cycle = self { return true }; return false }
    var isFinalPhase: Bool { if case .finalPhase = self { return true }; return false }
    /// The minimum kept-phase duration (`cycle`'s per-phase minimum, or `finalPhase`'s final-phase
    /// minimum) used by the structural validity guard.
    var minPhaseSec: Double? {
        switch self {
        case let .cycle(minPhaseSec, _, _, _): return minPhaseSec
        case let .finalPhase(_, _, minPhaseSec, _, _): return minPhaseSec
        default: return nil
        }
    }
}
