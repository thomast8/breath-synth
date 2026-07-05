import BreathEngineCore
import Foundation

/// Portable port of `BreathEngine`'s `BreathRecorder` — the same self-terminating, auto-advancing
/// multi-take capture and structural-validity/redo policy, minus the AVAudioEngine tap it no longer
/// needs: samples arrive via `feed(_:)` (fed by the web server's WebSocket handler) instead of a
/// real-time render-thread callback. Being an `actor` gives the same serialization `BreathRecorder` got
/// for free from `@MainActor`: `feed` and the async post-review continuation (see `continueReview`)
/// never touch state concurrently.
///
/// One `start(...)` captures `takes` takes back-to-back, self-paced: it waits for onset, segments the
/// take, auto-advances on the silence between takes, and calls `onFinished` after the last. A `cycle`/
/// `finalPhase` take is structurally validated before it's written; an invalid one is auto-redone rather
/// than saved. Waveform-peak tracking is deliberately dropped (the browser renders its own cosmetic
/// waveform from the samples it already has, at zero latency); everything else — including the mic-
/// authorization check, which has no server-side equivalent — mirrors `BreathRecorder` line-for-line.
public actor TakeCaptureEngine {
    public enum Phase: Sendable, Equatable { case idle, waitingForOnset, capturing, reviewing }

    // MARK: Live state (read by the caller after each feed/lifecycle call)

    public private(set) var isRecording = false
    public private(set) var phase: Phase = .idle
    public private(set) var livePhase: CaptureAnalyzer.LivePhase = .waiting
    public private(set) var phaseElapsed: Double = 0
    public private(set) var level: Float = 0
    public private(set) var activityThreshold: Float = 0
    public private(set) var blackoutRemaining: Double = 0
    public private(set) var elapsed: Double = 0
    public private(set) var takeIndex = 0
    public private(set) var eventCount = 0
    public private(set) var invalidTakes = 0
    public private(set) var lastTakeIssue: CaptureAnalyzer.TakeIssue?
    public private(set) var gapTooClose = false
    public private(set) var lastNoiseFloorRMS: Float?
    public private(set) var currentNoiseFloorRMS: Float?
    public private(set) var ambientHold = false
    public private(set) var errorMessage: String?

    // MARK: Config (per start)

    public private(set) var sampleRate: Double
    private var analyzer: CaptureAnalyzer
    private var buffer: [Float] = []
    private var segments: [FinalizeRequest.Segment] = []
    private var armed = false
    private var hasOnset = false

    private var detection: CaptureDetection = .fixedDuration(seconds: 5)
    private var rollingFloor = RollingNoiseFloor()
    private var ambientGateRMS: Float?
    private var onTakeAmbient: (([Float]) async -> Void)?
    private var takes = 1
    private var isCycle = false
    private var isFinalPhase = false
    private var isFixed = false
    private var minPhaseFrames = 0
    private var fileURL: ((Int, SegmentLabel) -> URL)?
    private var onSegment: ((Int, SegmentLabel, URL, [Int], [CaptureAnalyzer.SpectralCandidate]) async -> Void)?
    private var onFinished: (() async -> Void)?
    private var onTakeReview: ((_ takeIndex: Int, _ segments: [(label: SegmentLabel, url: URL)]) async -> TakeReview)?
    /// Fires on every silent structural redo (never on the force-accepted final attempt, and never for
    /// a grader-triggered redo — that one is `onTakeReview`'s job) so a live UI can tell the participant
    /// why a take just got thrown away instead of showing nothing (native's `retakeReason(_:)`/
    /// `lastTakeIssue` equivalent, made push-based for a remote client that can't poll every `feed`).
    private var onTakeRetake: ((_ takeIndex: Int, _ issue: CaptureAnalyzer.TakeIssue, _ retries: Int) async -> Void)?
    /// `true` while a written-but-unemitted take awaits its `onTakeReview` verdict — `armed` is already
    /// false for the whole wait (set by `consume` on `takeEnded`), so `feed` can't start a new take, but
    /// this additionally guards `continueReview`'s staleness check against `cancelTake`/`abort`.
    private var reviewing = false
    private var takeRetries = 0
    private let maxTakeRetries: Int

    public init(maxTakeRetries: Int = EnrollmentDetection.maxTakeRetries) {
        self.maxTakeRetries = maxTakeRetries
        sampleRate = AudioConstants.workingSampleRate
        analyzer = CaptureAnalyzer(sampleRate: sampleRate, detection: .fixedDuration(seconds: 0), noiseFloorRMS: nil)
    }

    // MARK: Public API

    /// Arm for `takes` takes with `detection`, writing each segment via `fileURL(takeIndex, label)`.
    /// `onSegment` fires per written file; `onFinished` after the last take. `noiseFloorRMS` (from a
    /// prior room-tone reading) seeds the rolling floor that gates activity/event detection.
    public func start(
        sampleRate: Double,
        takes: Int,
        detection: CaptureDetection,
        noiseFloorRMS: Float?,
        fileURL: @escaping (_ takeIndex: Int, _ label: SegmentLabel) -> URL,
        onSegment: @escaping (
            _ takeIndex: Int, _ label: SegmentLabel, _ url: URL, _ intervalsFrames: [Int],
            _ spectralCandidates: [CaptureAnalyzer.SpectralCandidate]
        ) async -> Void,
        onFinished: @escaping () async -> Void,
        onTakeReview: ((_ takeIndex: Int, _ segments: [(label: SegmentLabel, url: URL)]) async -> TakeReview)? = nil,
        ambientGateRMS: Float? = nil,
        onTakeAmbient: (([Float]) async -> Void)? = nil,
        onTakeRetake: ((_ takeIndex: Int, _ issue: CaptureAnalyzer.TakeIssue, _ retries: Int) async -> Void)? = nil
    ) {
        guard !isRecording else { return }
        self.sampleRate = sampleRate
        self.detection = detection
        rollingFloor = RollingNoiseFloor(value: noiseFloorRMS)
        currentNoiseFloorRMS = rollingFloor.value
        self.takes = max(1, takes)
        self.fileURL = fileURL
        self.onSegment = onSegment
        self.onFinished = onFinished
        self.onTakeReview = onTakeReview
        self.ambientGateRMS = ambientGateRMS
        self.onTakeAmbient = onTakeAmbient
        self.onTakeRetake = onTakeRetake
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

        analyzer = CaptureAnalyzer(
            sampleRate: sampleRate, detection: detection, noiseFloorRMS: rollingFloor.value,
            ambientGateRMS: ambientGateRMS)
        buffer = []
        segments = []
        hasOnset = false
        armed = true

        isRecording = true
        phase = isFixed ? .capturing : .waitingForOnset
    }

    /// Sub-chunk size `feed` re-slices an external chunk into internally. A caller's chunk (a WebSocket
    /// frame) has no reason to align with a take boundary — if `takeEnded` fires partway through one,
    /// the rest of that same chunk is real audio for whatever comes next (the between-takes gap, or a
    /// fast next onset) and must still reach the freshly re-armed analyzer, not be silently dropped.
    /// Bounding the sub-chunk to roughly one `CaptureAnalyzer` hop (~10ms) caps the worst case (audio
    /// wasted in the old analyzer's now-`.done` state before a boundary is noticed) at a fraction of a
    /// hop — far below any real onset/event width gate.
    private static let feedSubChunkFrames = 512

    /// Feed the next chunk of mono samples at `sampleRate`. Cheap when not armed (between takes / during
    /// review): only the raw-RMS level fallback updates, same as `BreathRecorder`'s tap when `box.armed`
    /// is false.
    public func feed(_ mono: [Float]) async {
        guard isRecording else { return }
        var offset = 0
        while offset < mono.count {
            guard isRecording else { return }
            guard armed else {
                level = Self.rms(Array(mono[offset...]))
                return
            }
            let end = min(mono.count, offset + Self.feedSubChunkFrames)
            let sub = Array(mono[offset..<end])
            offset = end
            buffer.append(contentsOf: sub)
            let events = analyzer.ingest(sub)
            let request = consume(events)
            refreshLiveState()
            if let request { await finalize(request) }
        }
    }

    /// Manual override: finalize the in-progress take now (writes what's captured so far).
    public func stopCurrentTake() async {
        guard isRecording, armed else { return }
        if let request = consume(analyzer.flush()) {
            await finalize(request)
        }
    }

    /// Manual override: discard the in-progress take and re-listen for the same take index. Also
    /// invalidates any pending `onTakeReview` wait — its verdict, whenever it arrives, will see
    /// `reviewing == false` and drop (`TakeGate.resolve`'s staleness guard).
    public func cancelTake() {
        guard isRecording else { return }
        reviewing = false
        arm()
    }

    /// Escape hatch: a genuinely loud room must never trap the session behind the ambient gate. Turns
    /// the gate off for the rest of this `start(...)` session and re-arms immediately (same fresh-
    /// analyzer pattern as `arm()` — the buffer reset is harmless since nothing has onset yet by
    /// construction, the gate only ever holds pre-onset).
    public func overrideAmbientGate() {
        guard isRecording else { return }
        ambientGateRMS = nil
        arm()
    }

    /// Stop the whole session immediately without finalizing or calling `onFinished`.
    public func abort() {
        teardown()
    }

    // MARK: Take lifecycle

    private func finalize(_ request: FinalizeRequest) async {
        guard isRecording, let fileURL, onSegment != nil else { return }
        if isFixed {
            lastNoiseFloorRMS = request.meanFloor
        } else {
            if let ambient = request.preOnsetFloor {
                // Blended in regardless of what this take's outcome turns out to be below (even a
                // redone take's pre-onset ambient is real, valid data about current conditions).
                rollingFloor.update(with: ambient)
                currentNoiseFloorRMS = rollingFloor.value
            }
            // Same "still valid data even if redone" reasoning as the rolling floor above.
            await onTakeAmbient?(request.ambientSamples)
        }

        let issue = takeIssue(request)
        lastTakeIssue = issue
        if issue != nil { invalidTakes += 1 }

        // Only `cycle`/`finalPhase` gate on their structural issue; every other kind's `takeIssue` only
        // ever returns `.noSegment`, which is unreachable in practice (every other state's `flush()`
        // always emits a segment before `takeEnded`).
        let retryEligible = isCycle || isFinalPhase
        let structurallyValid = issue == nil || !retryEligible
        let decision: TakeGate.Decision = request.segments.isEmpty
            ? .emit
            : TakeGate.decide(structurallyValid: structurallyValid, retries: takeRetries,
                              maxRetries: maxTakeRetries, hasReviewer: onTakeReview != nil)

        if decision == .redoNow {
            takeRetries += 1
            if let issue {
                await onTakeRetake?(takeIndex, issue, takeRetries)
            }
            arm()
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
                try AudioIO.writeMonoWAV(segment.samples, sampleRate: sampleRate, to: url)
            } catch {
                errorMessage = (error as? BreathError)?.description ?? error.localizedDescription
                teardown()
                return
            }
            written.append((segment.label, url))
        }

        if decision == .emit {
            await emit(written, request: request)
            return
        }

        // .review — hold for the caller's async grade. `armed` is already false (set by `consume` on
        // `takeEnded`), so `feed` can't start a new take while this waits.
        reviewing = true
        phase = .reviewing
        let reviewIndex = takeIndex
        Task { [weak self] in
            await self?.continueReview(reviewIndex: reviewIndex, written: written, request: request)
        }
    }

    /// The async tail of a `.review` decision, run as an unstructured `Task` from `finalize` so a slow
    /// grade never blocks `feed` from continuing to accept audio (mirrors `BreathRecorder`'s tap thread
    /// staying live for the same wait). Re-entering the actor here is what makes this safe against a
    /// concurrent `feed`/`cancelTake`/`abort` — the same guarantee `@MainActor` gave `BreathRecorder`.
    private func continueReview(
        reviewIndex: Int, written: [(label: SegmentLabel, url: URL)], request: FinalizeRequest
    ) async {
        guard let onTakeReview else { return }
        let verdict = await onTakeReview(reviewIndex, written)
        // `takeIndex` cannot have moved during the wait — `armed` stayed false the whole time, so
        // nothing else could call `finalize`/`emit` to advance it. Safe to reuse `written` as-is.
        let stale = !(isRecording && reviewing)
        let outcome = TakeGate.resolve(verdict: verdict, isStale: stale)
        switch outcome {
        case .drop:
            break
        case .redo:
            reviewing = false
            invalidTakes += 1
            takeRetries += 1
            arm()
        case .emit:
            reviewing = false
            await emit(written, request: request)
        }
    }

    /// Fire `onSegment` for already-written segments and advance the session — the shared tail of the
    /// immediate-accept and post-review-accept paths. `onSegment`/`onFinished` are awaited (not fired via
    /// a detached `Task`) so ordering across a multi-segment take (e.g. cycle's inhale-then-exhale) is
    /// guaranteed, exactly as calling them synchronously in sequence would be.
    private func emit(_ written: [(label: SegmentLabel, url: URL)], request: FinalizeRequest) async {
        guard let onSegment else { return }
        for (label, url) in written {
            await onSegment(takeIndex, label, url, request.intervals, request.spectralCandidates)
        }
        takeIndex += 1
        if takeIndex >= takes {
            let finished = onFinished
            teardown()
            await finished?()
        } else {
            arm()
        }
    }

    /// Structural validity guard. A `cycle` take must be exactly two phases, each ≥ `minPhaseFrames` and
    /// balanced — the analyzer/grader can't tell calm inhale from exhale, so this is the backstop against
    /// a missing or false mid-pause. A `finalPhase` take must have reached the deliberate pause (exactly
    /// one kept segment) and that segment must be ≥ `minPhaseFrames`. Every other take just needs a
    /// segment. Returns the reason the take failed, or `nil` if it's valid.
    private func takeIssue(_ request: FinalizeRequest) -> CaptureAnalyzer.TakeIssue? {
        if isCycle {
            guard request.reason != .incomplete, request.segments.count == 2 else {
                return .noPauseDetected
            }
            return CaptureAnalyzer.cycleIssue(
                inhaleFrames: request.segments[0].samples.count,
                exhaleFrames: request.segments[1].samples.count,
                minPhaseFrames: minPhaseFrames
            )
        }
        if isFinalPhase {
            guard request.reason != .incomplete, request.segments.count == 1 else { return .noPauseBeforeRelease }
            return request.segments[0].samples.count < minPhaseFrames ? .exhaleTooShort : nil
        }
        return request.segments.isEmpty ? .noSegment : nil
    }

    private func arm() {
        analyzer = CaptureAnalyzer(
            sampleRate: sampleRate, detection: detection, noiseFloorRMS: rollingFloor.value,
            ambientGateRMS: ambientGateRMS)
        buffer.removeAll(keepingCapacity: true)
        segments.removeAll(keepingCapacity: true)
        hasOnset = false
        armed = true
        eventCount = 0
        elapsed = 0
        gapTooClose = false
        livePhase = .waiting
        phaseElapsed = 0
    }

    private func teardown() {
        guard isRecording else { return }
        isRecording = false
        reviewing = false
        armed = false
        phase = .idle
        level = 0
    }

    /// Process analyzer events: slice finished segments out of `buffer`, and on `takeEnded` disarm and
    /// return the finalize request.
    private func consume(_ events: [CaptureAnalyzer.Event]) -> FinalizeRequest? {
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
                let ambient: [Float]
                if let range = analyzer.quietRangeFrames {
                    let lo = max(0, min(range.lowerBound, buffer.count))
                    let hi = max(lo, min(range.upperBound, buffer.count))
                    ambient = Array(buffer[lo..<hi])
                } else {
                    ambient = []
                }
                return FinalizeRequest(
                    segments: segments, reason: reason,
                    intervals: analyzer.intervalsFrames, meanFloor: analyzer.meanFloorRMS(),
                    preOnsetFloor: analyzer.preOnsetFloorRMS,
                    spectralCandidates: analyzer.spectralCandidates,
                    ambientSamples: ambient
                )
            }
        }
        return nil
    }

    /// Refreshes every UI-facing field from the analyzer/armed state, mirroring `BreathRecorder`'s
    /// `publishSnapshot` — called once per `feed`, after `consume` (so it reflects state *after* a
    /// `takeEnded` this call may have just produced, exactly matching that ordering).
    private func refreshLiveState() {
        // Display-only ballistics: the analyzer's raw envelope updates every ~10ms hop and is exactly
        // right for gating, but redrawing a meter at that resolution reads as flicker. Faster attack than
        // release (classic VU-meter behavior) keeps the bar responsive to an actual breath starting while
        // settling smoothly rather than chattering between callbacks.
        let rawLevel = analyzer.currentLevel
        let rate: Float = rawLevel > level ? 0.6 : 0.12
        level += (rawLevel - level) * rate
        activityThreshold = analyzer.currentActivityThreshold
        eventCount = analyzer.eventCount
        elapsed = Double(buffer.count) / sampleRate
        blackoutRemaining = hasOnset ? 0 : max(0, analyzer.blackoutSec - elapsed)
        ambientHold = analyzer.isAmbientHold
        gapTooClose = analyzer.lastGapWithinMin
        livePhase = analyzer.livePhase
        phaseElapsed = Double(analyzer.phaseElapsedFrames) / sampleRate
        if isFixed {
            phase = .capturing
        } else {
            phase = armed && hasOnset ? .capturing : .waitingForOnset
        }
    }

    private static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        return (sum / Float(samples.count)).squareRoot()
    }
}

/// A finalized take's data, passed from `consume` to `finalize`/`continueReview`. `Sendable` so it can
/// cross into the unstructured review `Task`.
struct FinalizeRequest: Sendable {
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
    /// This take's own harvested quiet stretch (see `CaptureAnalyzer.quietRangeFrames`), sliced from the
    /// take's buffer — empty if nothing quiet enough ran long enough. Room-tone harvest pool material.
    let ambientSamples: [Float]
}

private extension CaptureDetection {
    var isFixedDuration: Bool { if case .fixedDuration = self { return true }; return false }
    var isCycle: Bool { if case .cycle = self { return true }; return false }
    var isFinalPhase: Bool { if case .finalPhase = self { return true }; return false }
    /// The minimum kept-phase duration (`cycle`'s per-phase minimum, or `finalPhase`'s final-phase
    /// minimum) used by the structural validity guard.
    var minPhaseSec: Double? {
        switch self {
        case let .cycle(minPhaseSec, _, _, _, _): return minPhaseSec
        case let .finalPhase(_, _, minPhaseSec, _, _, _): return minPhaseSec
        default: return nil
        }
    }
}
