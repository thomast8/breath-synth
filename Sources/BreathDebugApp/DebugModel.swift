import AVFoundation
import AppKit
import BreathEngine
import CoreGraphics
import Foundation
import Observation
import UniformTypeIdentifiers

/// Drives a `BreathEngine` for the debug GUI: pick a style + parameters, render one of the engine's
/// four paths (single / counted / cycle / sequence), see the exact rendered waveform + stats, and
/// play / loop / save it. Every action is also fanned out through `SessionLogger` (live SSE stream +
/// JSONL file) so an external observer sees exactly what the GUI does. All state is `@Observable` for
/// SwiftUI and stays on the main actor (the engine and AVFoundation are main-actor-isolated too).
@MainActor
@Observable
final class DebugModel {
    /// Which render path the GUI is exercising.
    enum DebugTask: String, CaseIterable, Identifiable {
        case single, counted, cycle, sequence
        var id: String { rawValue }
        var title: String {
            switch self {
            case .single: return "Single"
            case .counted: return "Counted"
            case .cycle: return "Cycle"
            case .sequence: return "Sequence"
            }
        }
    }

    enum Phase: Equatable {
        case idle
        case rendering
        case playing
        case looping
        case paused
        case error(String)
    }

    /// A style as the UI needs it: its name, render mode, and the directions it actually carries.
    struct StyleInfo: Identifiable, Equatable {
        let name: String
        let mode: RenderMode
        let directions: [BreathType]
        var id: String { name }
    }

    /// Stats for the most recent render, shown next to the waveform. `durationSec` is the rendered
    /// buffer's length, which now equals the full playback length for every task (Cycle mode renders
    /// all its cycles into the buffer rather than replaying one). `totalSec` is vestigial — now nil.
    struct RenderStats: Equatable {
        var taskName: String
        var detail: String
        var frames: Int
        var durationSec: Double
        var totalSec: Double?
        var peakDb: Double
        var rmsDb: Double
        var renderMs: Double
    }

    struct LogLine: Identifiable {
        let id = UUID()
        let wall: Double
        let event: String
        let text: String
    }

    private let logger = SessionLogger()
    private var engine: BreathEngine?
    private var loadedSignature = ""
    private var playTask: Task<Void, Never>?
    /// Drives the single playhead value (~60 fps) while audio runs.
    private var headTask: Task<Void, Never>?
    /// The exact buffer last shown/played; Play resumes from the parked head within it.
    private var currentBuffer: AVAudioPCMBuffer?
    /// Frame offset the current playback started at (0 normally; the parked head's frame for Play).
    private var playbackStartFrame: AVAudioFramePosition = 0
    /// Phase to return to when resuming from pause.
    private var resumePhase: Phase = .playing

    // MARK: Engine config (a change here rebuilds the engine on the next render)

    var assetsPath: String = DebugModel.defaultAssetsPath()
    var denoiseEnabled = true
    var denoiseOversub: Double = 1.75
    var denoiseFloor: Double = 0.05
    var crossfadeSec: Double = 0.2

    // MARK: Discovered palette

    private(set) var styles: [StyleInfo] = []
    private(set) var loadError: String?

    // MARK: Active task + per-task parameters

    var task: DebugTask = .single

    // Single
    var singleStyle = "calm"
    var singleType: BreathType = .inhale
    var singleDuration: Double = 6
    var singleSeedText = ""
    var singleVariationEnabled = true
    var singleVarGainDb: Double = 2.0
    var singleVarRatePct: Double = 2.0
    var singleGain: Double = 1.0

    // Counted
    var countedStyle = "recovery"
    var countedType: BreathType = .inhale
    var countedCountText = ""
    var countedSeedText = ""

    // Cycle
    var cycleInhaleStyle = "calm"
    var cycleInhaleDur: Double = 4
    var cycleHoldIn: Double = 0
    var cycleExhaleStyle = "calm"
    var cycleExhaleDur: Double = 6
    var cycleHoldOut: Double = 0
    var cycleLoop = false
    var cycleCount = 3

    // Sequence
    var seqStyle = "calm"
    var seqTotal: Double = 30
    var seqInhaleDur: Double = 4
    var seqExhaleDur: Double = 6
    var seqHoldIn: Double = 0
    var seqHoldOut: Double = 0
    var seqClosest = false
    var seqLoop = false
    var seqSeedText = ""

    // MARK: Output

    private(set) var phase: Phase = .idle
    private(set) var waveform: [WavePeak] = []
    private(set) var boundaries: [Double] = []
    /// Heat-mapped STFT of the last render (low frequency at the bottom); nil until something renders.
    private(set) var spectrogram: CGImage?
    /// Impulsive-onset positions (fractions 0...1) from spectral flux — flags clicks / glottal stops.
    private(set) var transients: [Double] = []
    /// UI toggle for the spectrogram panel.
    var showSpectrogram = true
    /// Set by the waveform drag gesture while scrubbing; overrides the playhead until released.
    var scrubFraction: Double?
    /// Where the head rests after a click/drag (scrub-to-inspect), so it stays put.
    private(set) var parkedFraction: Double?
    /// The live sweeping position, updated ~60fps by the head timer while audio runs.
    private(set) var livePlayhead: Double?
    private(set) var stats: RenderStats?
    private(set) var planSummary: String?
    private(set) var log: [LogLine] = []
    private let logLimit = 400

    /// Where an external observer can watch this session live.
    var logPath: String { logger.url.path }
    var streamURL: String { "http://127.0.0.1:\(logger.server.port)/" }

    /// The single source of truth for the playhead, read by EVERY view (waveform + spectrogram) so they
    /// can never disagree: the drag position while scrubbing, else the live sweeping position (sampled
    /// into `livePlayhead` by one timer), else a parked position from a click/drag. One value, one
    /// writer — no per-view clocks to drift or freeze.
    var displayProgress: Double? { scrubFraction ?? livePlayhead ?? parkedFraction }

    /// The live playback position as a fraction [0,1] of the displayed buffer, or nil when not playing.
    /// `currentSampleTime` counts frames since playback started; `stats.frames` is one displayed unit,
    /// so `played % frames` sweeps once per unit (once for single/counted/sequence, once per cycle).
    private func computeLivePlayhead() -> Double? {
        switch phase { case .playing, .looping: break; default: return nil }
        guard let frames = stats?.frames, frames > 0 else { return nil }
        let total = AVAudioFramePosition(frames)
        let played = max(0, playbackStartFrame + (engine?.currentSampleTime ?? 0))   // pre-roll → start
        switch task {
        case .single, .counted:
            return min(Double(played) / Double(total), 1)
        case .cycle:
            // The buffer is now the whole cycleCount-cycle block (like sequence): sweep it once —
            // looping wraps at the block, finite clamps at the end.
            if cycleLoop { return Double(played % total) / Double(total) }
            return min(Double(played) / Double(total), 1)
        case .sequence:
            if seqLoop { return Double(played % total) / Double(total) }
            return min(Double(played) / Double(total), 1)
        }
    }

    /// Whether the Pause/Resume control applies (something is playing, looping, or paused).
    var canPause: Bool {
        switch phase { case .playing, .looping, .paused: return true; default: return false }
    }
    var isPaused: Bool { phase == .paused }

    // MARK: Palette subsets for the pickers

    var nonCountedStyles: [StyleInfo] { styles.filter { $0.mode != .counted } }
    var countedStyles: [StyleInfo] { styles.filter { $0.mode == .counted } }
    var singleStyles: [StyleInfo] { nonCountedStyles.filter { !$0.directions.isEmpty } }
    var inhaleStyles: [StyleInfo] { nonCountedStyles.filter { $0.directions.contains(.inhale) } }
    var exhaleStyles: [StyleInfo] { nonCountedStyles.filter { $0.directions.contains(.exhale) } }
    /// Sequence reuses one style for both directions, so it needs styles carrying both.
    var sequenceStyles: [StyleInfo] { nonCountedStyles.filter { $0.directions.contains(.inhale) && $0.directions.contains(.exhale) } }

    func info(for name: String) -> StyleInfo? { styles.first { $0.name == name } }
    func directions(for name: String) -> [BreathType] { info(for: name)?.directions ?? [.inhale, .exhale] }

    // MARK: - Engine lifecycle

    /// Rebuild the engine if the config changed (or it has never been built). Refreshes the discovered
    /// palette and re-validates the style/direction selections. Throws on a bad assets dir / manifest.
    @discardableResult
    private func ensureEngine() throws -> BreathEngine {
        let signature = configSignature()
        if let engine, signature == loadedSignature { return engine }

        let url = URL(fileURLWithPath: assetsPath, isDirectory: true)
        var settings = AssemblerSettings()
        settings.enableSpectralDenoise = denoiseEnabled
        settings.denoiseOverSubtraction = Float(denoiseOversub)
        settings.denoiseFloorGain = Float(denoiseFloor)
        settings.crossfadeSec = crossfadeSec

        let manifest = try BreathManifest.load(from: url.appendingPathComponent("manifest.json"))
        let built = try BreathEngine(config: .init(assetsDirectory: url, manifest: manifest, settings: settings))
        engine = built
        loadedSignature = signature
        styles = built.styleNames().map {
            StyleInfo(name: $0, mode: built.renderMode(for: $0), directions: built.supportedDirections(for: $0))
        }
        normalizeSelections()
        logger.log("config", [
            "assets": assetsPath,
            "styles": styles.map(\.name),
            "denoise": denoiseEnabled,
            "denoiseOversub": denoiseOversub,
            "denoiseFloor": denoiseFloor,
            "crossfadeSec": crossfadeSec,
        ])
        return built
    }

    private func configSignature() -> String {
        "\(assetsPath)|\(denoiseEnabled)|\(denoiseOversub)|\(denoiseFloor)|\(crossfadeSec)"
    }

    /// Force a fresh engine + palette load (assets dir changed, files edited on disk). Surfaces a load
    /// failure into `loadError` instead of throwing, so the UI can show it without a render attempt.
    func reloadEngine() {
        engine = nil
        loadedSignature = ""
        do {
            _ = try ensureEngine()
            loadError = nil
        } catch {
            styles = []
            loadError = describe(error)
            logger.log("error", ["where": "load", "message": loadError ?? ""])
        }
    }

    /// First load on launch.
    func start() { reloadEngine() }

    /// Keep style/direction selections pointing at something the loaded palette actually provides.
    private func normalizeSelections() {
        singleStyle = pick(singleStyle, in: singleStyles)
        clampDirection(&singleType, to: singleStyle)
        countedStyle = pick(countedStyle, in: countedStyles)
        clampDirection(&countedType, to: countedStyle)
        cycleInhaleStyle = pick(cycleInhaleStyle, in: inhaleStyles)
        cycleExhaleStyle = pick(cycleExhaleStyle, in: exhaleStyles)
        seqStyle = pick(seqStyle, in: sequenceStyles)
    }

    private func pick(_ current: String, in list: [StyleInfo]) -> String {
        list.contains { $0.name == current } ? current : (list.first?.name ?? current)
    }

    /// Snap a direction to one the style supports (called when a style picker changes).
    func clampDirection(_ type: inout BreathType, to style: String) {
        let dirs = directions(for: style)
        if !dirs.isEmpty, !dirs.contains(type) { type = dirs[0] }
    }

    func onSingleStyleChanged() { clampDirection(&singleType, to: singleStyle) }
    func onCountedStyleChanged() { clampDirection(&countedType, to: countedStyle) }

    // MARK: - Actions

    func render() {
        run { engine in _ = try self.renderActive(engine) }
    }

    /// Render the active task and play it, starting from the parked head if one is set (else the
    /// start), continuing the task's cycles / loop. All four tasks go through one path
    /// (`play(_:fromFrame:repeats:loop:)`) so playback and the playhead behave identically everywhere.
    func play() {
        let startFraction = parkedFraction
        run { engine in
            let buffer = try self.renderActive(engine)
            let total = AVAudioFramePosition(buffer.frameLength)
            let startFrame = startFraction.map { AVAudioFramePosition(Double(total) * min(max($0, 0), 1)) } ?? 0
            let loop: Bool
            let repeats: Int
            switch self.task {
            case .single, .counted: loop = false; repeats = 0
            case .cycle: loop = self.cycleLoop; repeats = 0   // renderCycle returns all cycleCount cycles
            case .sequence: loop = self.seqLoop; repeats = 0
            }
            self.playbackStartFrame = startFrame
            self.phase = loop ? .looping : .playing
            self.startHeadUpdates()
            self.logger.log(loop ? "loop" : "play", ["task": self.task.rawValue, "fromFrame": startFrame])
            try await engine.play(buffer, fromFrame: startFrame, repeats: repeats, loop: loop)
            self.playbackFinished()
        }
    }

    func stop() {
        playTask?.cancel()
        playTask = nil
        engine?.stop()
        stopHeadUpdates(clear: true)
        phase = .idle
        playbackStartFrame = 0
        scrubFraction = nil
        parkedFraction = nil
        logger.log("stop")
    }

    /// Drag in progress: the head follows the finger live. Committed by `parkHead` on release.
    func scrub(to fraction: Double) {
        scrubFraction = min(max(fraction, 0), 1)
    }

    /// Click or drag-release: move the head there and leave it parked with audio stopped, so you can
    /// read the time / line it up with a spectrogram streak. Press Play to play from here.
    func parkHead(at fraction: Double) {
        playTask?.cancel()
        playTask = nil
        engine?.stop()
        stopHeadUpdates(clear: true)
        phase = .idle
        playbackStartFrame = 0
        scrubFraction = nil
        parkedFraction = min(max(fraction, 0), 1)
        logger.log("scrub", ["fraction": parkedFraction ?? 0])
    }

    /// A non-looping playback finished: go idle and park the head at the end so it stays visible.
    /// Looping playbacks return immediately from `engine.play` with `phase == .looping`, so the guard
    /// keeps the head sweeping for them.
    private func playbackFinished() {
        guard case .playing = phase else { return }
        stopHeadUpdates(clear: true)
        phase = .idle
        parkedFraction = 1
    }

    /// Toggle pause/resume. Pause freezes the head (stops the timer, leaving the last value) and the
    /// player; resume restarts both from where they were.
    func pauseResume() {
        switch phase {
        case .playing, .looping:
            resumePhase = phase
            engine?.pause()
            stopHeadUpdates(clear: false)        // freeze the head at its last position
            phase = .paused
            logger.log("pause")
        case .paused:
            engine?.resume()
            phase = resumePhase
            startHeadUpdates()
            logger.log("resume")
        default:
            break
        }
    }

    // MARK: - Playhead timer (single writer of `livePlayhead`)

    private func startHeadUpdates() {
        headTask?.cancel()
        headTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.livePlayhead = self.computeLivePlayhead()
                try? await Task.sleep(nanoseconds: 16_000_000)   // ~60 fps
            }
        }
    }

    private func stopHeadUpdates(clear: Bool) {
        headTask?.cancel()
        headTask = nil
        if clear { livePlayhead = nil }
    }

    /// Shared task scaffold: cancel any in-flight playback, ensure the engine, run `body`, surface errors.
    private func run(_ body: @escaping (BreathEngine) async throws -> Void) {
        playTask?.cancel()
        engine?.stop()
        stopHeadUpdates(clear: true)
        scrubFraction = nil
        parkedFraction = nil
        playTask = Task { @MainActor in
            do {
                let engine = try ensureEngine()
                loadError = nil
                try await body(engine)
            } catch is CancellationError {
                phase = .idle
            } catch {
                fail(error)
            }
        }
    }

    /// Render the active task into a buffer, update the waveform/stats/log, and return it. The buffer
    /// is what `play()` schedules for single/counted; cycle/sequence re-render identically (same seed)
    /// inside the engine's loop helpers, so the displayed waveform always matches what is heard.
    @discardableResult
    private func renderActive(_ engine: BreathEngine) throws -> AVAudioPCMBuffer {
        phase = .rendering
        let t0 = DispatchTime.now()
        let buffer: AVAudioPCMBuffer
        var detail = ""
        var bounds: [Double] = []

        switch task {
        case .single:
            let spec = singleSpec()
            buffer = try engine.render(spec)
            detail = "\(spec.style) \(spec.type.rawValue) \(fmt(spec.clampedDurationSec))s · seed \(effectiveSeed(spec)) · variation \(singleVariationEnabled ? "on" : "off")"
        case .counted:
            let count = parseCount(countedCountText)
            let seed = parseSeed(countedSeedText)
            buffer = try engine.renderCounted(style: countedStyle, type: countedType, count: count, seed: seed)
            detail = "\(countedStyle) \(countedType.rawValue) · count \(count.map(String.init) ?? "detected") · seed \(seed.map(String.init) ?? "stable")"
        case .cycle:
            let spec = cycleSpec()
            buffer = try engine.renderCycle(spec)               // all cycleCount cycles, each decorrelated
            bounds = cycleBoundaries()
            let count = max(1, cycleCount)
            let cycleLen = cycleInhaleDur + cycleHoldIn + cycleExhaleDur + cycleHoldOut
            detail = "in \(cycleInhaleStyle) \(fmt(cycleInhaleDur))s / hold \(fmt(cycleHoldIn))s / out \(cycleExhaleStyle) \(fmt(cycleExhaleDur))s / hold \(fmt(cycleHoldOut))s"
            let plural = count == 1 ? "" : "s"
            detail += cycleLoop
                ? " · loops \(count) distinct cycle\(plural)"
                : " · \(count) distinct cycle\(plural) → \(fmt(cycleLen * Double(count)))s"
        case .sequence:
            let plan = try makePlanCapturingSummary()
            buffer = try engine.renderSequence(plan)
            detail = planSummary ?? ""
            bounds = sequenceBoundaries(plan)
        }

        let renderMs = Double(DispatchTime.now().uptimeNanoseconds &- t0.uptimeNanoseconds) / 1_000_000
        updateDisplay(buffer: buffer, detail: detail, boundaries: bounds, totalSec: nil, renderMs: renderMs)
        if case .rendering = phase { phase = .idle }
        return buffer
    }

    func saveWAV() {
        let engine: BreathEngine
        do { engine = try ensureEngine() } catch { fail(error); return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.wav]
        panel.nameFieldStringValue = defaultFileName()
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try writeActive(engine, to: url)
            logger.log("save", ["task": task.rawValue, "path": url.path])
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            fail(error)
        }
    }

    private func writeActive(_ engine: BreathEngine, to url: URL) throws {
        switch task {
        case .single:
            try engine.renderToWAV(singleSpec(), url: url)
        case .counted:
            try engine.renderCountedToWAV(style: countedStyle, type: countedType, count: parseCount(countedCountText), seed: parseSeed(countedSeedText), url: url)
        case .cycle:
            try engine.renderCycleToWAV(cycleSpec(), url: url)
        case .sequence:
            try engine.renderSequenceToWAV(makePlanCapturingSummary(), url: url)
        }
    }

    func clearLog() { log = [] }

    func randomizeSeed() {
        let seed = String(UInt64.random(in: 0...UInt64.max))
        switch task {
        case .single: singleSeedText = seed
        case .counted: countedSeedText = seed
        case .sequence: seqSeedText = seed
        case .cycle: break        // cycle derives per-phase seeds; no single field to pin
        }
    }

    // MARK: - Spec builders

    private func singleSpec() -> BreathSpec {
        let variation = singleVariationEnabled
            ? VariationOptions(enabled: true, gainDb: singleVarGainDb, playbackRatePct: singleVarRatePct)
            : .none
        return BreathSpec(
            type: singleType,
            durationSec: singleDuration,
            style: singleStyle,
            seed: parseSeed(singleSeedText),
            variation: variation,
            gain: singleGain
        )
    }

    private func cycleSpec() -> CycleSpec {
        CycleSpec(
            inhale: BreathSpec(type: .inhale, durationSec: cycleInhaleDur, style: cycleInhaleStyle),
            holdAfterInhaleSec: cycleHoldIn,
            exhale: BreathSpec(type: .exhale, durationSec: cycleExhaleDur, style: cycleExhaleStyle),
            holdAfterExhaleSec: cycleHoldOut,
            loop: cycleLoop,
            cycles: max(1, cycleCount)
        )
    }

    private func makePattern() -> BreathPattern {
        BreathPattern(
            inhaleSec: seqInhaleDur,
            holdInSec: seqHoldIn,
            exhaleSec: seqExhaleDur,
            holdOutSec: seqHoldOut,
            style: seqStyle,
            seed: parseSeed(seqSeedText)
        )
    }

    private func makePlan() throws -> SequencePlan {
        try SequencePlanner.plan(total: seqTotal, pattern: makePattern(), mode: seqClosest ? .closest : .strict)
    }

    /// Plan the sequence, recording the human-readable fit/error into `planSummary` either way.
    private func makePlanCapturingSummary() throws -> SequencePlan {
        do {
            let plan = try makePlan()
            planSummary = planFitText(plan)
            return plan
        } catch let error as SequencePlanError {
            planSummary = error.description
            throw error
        }
    }

    /// Live, non-throwing preview of the sequence fit for the Sequence tab. Honors the Closest toggle
    /// so the preview matches what Play/Save would actually render.
    var sequencePreview: String {
        do {
            let plan = try SequencePlanner.plan(total: seqTotal, pattern: makePattern(), mode: seqClosest ? .closest : .strict)
            return planFitText(plan)
        } catch let error as SequencePlanError {
            return error.description
        } catch {
            return describe(error)
        }
    }

    private func planFitText(_ plan: SequencePlan) -> String {
        let fit = plan.isExact ? "exact" : "\(BreathFormat.signedSec(plan.deltaSec))s from request"
        return "\(BreathFormat.sec(plan.actualTotalSec))s · \(plan.cycles) cycles · \(fit)"
    }

    // MARK: - Boundaries (waveform phase/cycle guides, as fractions of total)

    private func cycleBoundaries() -> [Double] {
        // The buffer is `cycleCount` whole cycles, so mark every cycle's phase boundaries plus each
        // cycle seam, as fractions of the full multi-cycle length (not just one cycle's phases).
        let segments = [cycleInhaleDur, cycleHoldIn, cycleExhaleDur, cycleHoldOut]
        let cycleLen = segments.reduce(0, +)
        let count = max(1, cycleCount)
        let total = cycleLen * Double(count)
        guard cycleLen > 0, total > 0 else { return [] }
        var marks: [Double] = []
        for cycle in 0..<count {
            let base = Double(cycle) * cycleLen
            var acc = 0.0
            for segment in segments.dropLast() {
                acc += segment
                marks.append((base + acc) / total)
            }
            if cycle < count - 1 { marks.append((base + cycleLen) / total) } // cycle seam
        }
        return marks
    }

    private func sequenceBoundaries(_ plan: SequencePlan) -> [Double] {
        guard plan.cycles > 1, plan.actualTotalSec > 0 else { return [] }
        return (1..<plan.cycles).map { Double($0) * plan.pattern.cycleSec / plan.actualTotalSec }
    }

    // MARK: - Display + logging

    private func updateDisplay(buffer: AVAudioPCMBuffer, detail: String, boundaries: [Double], totalSec: Double?, renderMs: Double) {
        let frames = Int(buffer.frameLength)
        var peaks: [WavePeak] = []
        var peak: Float = 0
        var sumSquares = 0.0

        if frames > 0, let channel = buffer.floatChannelData?[0] {
            let bucketCount = min(frames, 1600)
            peaks.reserveCapacity(bucketCount)
            for bucket in 0..<bucketCount {
                let lo = bucket * frames / bucketCount
                let hi = max(lo + 1, (bucket + 1) * frames / bucketCount)
                var minValue = channel[lo]
                var maxValue = channel[lo]
                var i = lo
                while i < hi {
                    let value = channel[i]
                    if value < minValue { minValue = value }
                    if value > maxValue { maxValue = value }
                    let magnitude = abs(value)
                    if magnitude > peak { peak = magnitude }
                    sumSquares += Double(value) * Double(value)
                    i += 1
                }
                peaks.append(WavePeak(min: minValue, max: maxValue))
            }
        }

        let rms = frames > 0 ? Float((sumSquares / Double(frames)).squareRoot()) : 0
        let sampleRate = AudioConstants.workingSampleRate
        let peakDb = dbfs(peak)
        let rmsDb = dbfs(rms)

        waveform = peaks
        self.boundaries = boundaries
        currentBuffer = buffer          // kept so the playhead can be dragged to seek within it

        // Spectrogram + impulsive-onset markers from the raw samples (glottal stops show as bright
        // vertical streaks / flux peaks). Computed synchronously — fine for a debug tool at this size.
        var raw = [Float]()
        if frames > 0, let channel = buffer.floatChannelData?[0] {
            raw = Array(UnsafeBufferPointer(start: channel, count: frames))
        }
        let spectro = Spectrogram.analyze(raw, sampleRate: sampleRate)
        spectrogram = spectro.image
        transients = spectro.transients
        stats = RenderStats(
            taskName: task.title,
            detail: detail,
            frames: frames,
            durationSec: Double(frames) / sampleRate,
            totalSec: totalSec,
            peakDb: peakDb,
            rmsDb: rmsDb,
            renderMs: renderMs
        )
        logger.log("render", [
            "task": task.rawValue,
            "detail": detail,
            "frames": frames,
            "durationSec": Double(frames) / sampleRate,
            "totalSec": totalSec ?? NSNull(),
            "peakDb": peakDb.isFinite ? peakDb : NSNull(),
            "rmsDb": rmsDb.isFinite ? rmsDb : NSNull(),
            "renderMs": renderMs,
        ])
        appendLog("render", detail)
    }

    private func fail(_ error: Error) {
        let message = describe(error)
        phase = .error(message)
        logger.log("error", ["message": message])
        appendLog("error", message)
    }

    private func appendLog(_ event: String, _ text: String) {
        log.append(LogLine(wall: Date().timeIntervalSince1970, event: event, text: text))
        if log.count > logLimit { log.removeFirst(log.count - logLimit) }
    }

    // MARK: - Small helpers

    private func parseSeed(_ text: String) -> UInt64? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : UInt64(trimmed)
    }

    private func parseCount(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : Int(trimmed).map { max(1, $0) }
    }

    private func effectiveSeed(_ spec: BreathSpec) -> String {
        String(spec.seed ?? Variation.stableSeed(for: spec))
    }

    private func dbfs(_ amplitude: Float) -> Double {
        amplitude > 0 ? 20 * log10(Double(amplitude)) : -.infinity
    }

    private func fmt(_ value: Double) -> String { BreathFormat.sec(value) }

    private func defaultFileName() -> String {
        switch task {
        case .single: return "\(singleStyle)_\(singleType.rawValue)_\(fmt(singleDuration))s.wav"
        case .counted: return "\(countedStyle)_\(countedType.rawValue)_counted.wav"
        case .cycle: return "cycle_\(cycleInhaleStyle)_\(cycleExhaleStyle).wav"
        case .sequence: return "sequence_\(seqStyle)_\(fmt(seqTotal))s.wav"
        }
    }

    private func describe(_ error: Error) -> String {
        if let breath = error as? BreathError { return breath.description }
        if let plan = error as? SequencePlanError { return plan.description }
        return "\(error)"
    }

    private static func defaultAssetsPath() -> String {
        let fileManager = FileManager.default
        if let resources = Bundle.main.resourceURL {
            let bundled = resources.appendingPathComponent("breaths", isDirectory: true)
            if fileManager.fileExists(atPath: bundled.appendingPathComponent("manifest.json").path) {
                return bundled.path
            }
        }
        return fileManager.currentDirectoryPath + "/Assets/breaths"
    }
}
