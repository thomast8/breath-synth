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
    public enum Phase: Sendable { case idle, waitingForOnset, capturing }

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
    /// Seconds captured in the current take.
    public private(set) var elapsed: Double = 0
    /// 0-based index of the take currently being captured.
    public private(set) var takeIndex = 0
    /// Live count of detected events in the current take (cleanEvents / naturalRhythm).
    public private(set) var eventCount = 0
    /// Takes auto-rejected by the structural guard this session (surfaced as "let's retake that").
    public private(set) var invalidTakes = 0
    /// Why the most recently finalized take was rejected, or `nil` if it was accepted. Cleared when a
    /// new take is armed.
    public private(set) var lastTakeIssue: CaptureAnalyzer.TakeIssue?
    /// `true` when the last counted event fell within the clean-separation gap (UI "leave a gap" hint).
    public private(set) var gapTooClose = false
    /// Mean room-tone level from the most recent `fixedDuration` take — the noise floor for later steps.
    public private(set) var lastNoiseFloorRMS: Float?
    public private(set) var errorMessage: String?

    // MARK: Config (per start)

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private var box: CaptureBox?
    @ObservationIgnored private var sampleRate = AudioConstants.workingSampleRate
    @ObservationIgnored private var detection: CaptureDetection = .fixedDuration(seconds: 5)
    @ObservationIgnored private var noiseFloorRMS: Float?
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
    @ObservationIgnored private var configObserver: NSObjectProtocol?
    /// Consecutive auto-rejected takes (any structurally-invalid cause: `cycle`, `finalPhase`); after
    /// `maxTakeRetries` the next take is force-accepted so a user who can't produce a valid take is
    /// never trapped in an infinite redo.
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
        onFinished: @escaping @MainActor () -> Void
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
        self.noiseFloorRMS = noiseFloorRMS
        self.takes = max(1, takes)
        self.fileURL = fileURL
        self.onSegment = onSegment
        self.onFinished = onFinished
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

        let box = CaptureBox(analyzer: CaptureAnalyzer(sampleRate: sampleRate, detection: detection, noiseFloorRMS: noiseFloorRMS))
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

    /// Manual override: discard the in-progress take and re-listen for the same take index.
    public func cancelTake() {
        guard isRecording else { return }
        arm()
        publishSnapshot()
    }

    /// Stop the whole session immediately without finalizing or calling `onFinished`.
    public func abort() { teardown() }

    // MARK: Take lifecycle (main actor)

    private func finalize(_ request: FinalizeRequest) {
        guard isRecording, let fileURL, let onSegment else { return }
        if isFixed { lastNoiseFloorRMS = request.meanFloor }

        if let issue = takeIssue(request) {
            lastTakeIssue = issue
            invalidTakes += 1
            // Structurally-invalid takes (cycle, finalPhase) auto-redo, but only up to a shared cap —
            // past it, force-accept what was captured (the offline grader filters bad fragments) so the
            // session always makes progress.
            if (isCycle || isFinalPhase), takeRetries < maxTakeRetries {
                takeRetries += 1
                arm()
                publishSnapshot()
                return
            }
        } else {
            lastTakeIssue = nil
        }
        takeRetries = 0

        for segment in request.segments {
            let url = fileURL(takeIndex, segment.label)
            do {
                try BreathRecorder.writeMono(segment.samples, sampleRate: sampleRate, to: url)
            } catch {
                errorMessage = (error as? BreathError)?.description ?? error.localizedDescription
                teardown()
                return
            }
            onSegment(takeIndex, segment.label, url, request.intervals, request.spectralCandidates)
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
            guard request.reason != .incomplete, request.segments.count == 2 else { return .noPauseDetected }
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
        guard let box else { return }
        let detection = detection
        let noiseFloor = noiseFloorRMS
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
        phase = .idle
        level = 0
    }

    private func publishSnapshot() {
        guard isRecording, let box else { return }
        let snapshot = box.lock.withLock {
            (level: box.level, count: box.analyzer.eventCount, frames: box.buffer.count,
             armed: box.armed, onset: box.hasOnset, gap: box.analyzer.lastGapWithinMin,
             livePhase: box.analyzer.livePhase, phaseFrames: box.analyzer.phaseElapsedFrames,
             peaks: box.wavePeaks)
        }
        level = snapshot.level
        eventCount = snapshot.count
        elapsed = Double(snapshot.frames) / sampleRate
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
