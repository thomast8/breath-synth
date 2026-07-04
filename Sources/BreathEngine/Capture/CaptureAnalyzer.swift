import Foundation

/// Pure, streaming breath/event detector — the live counterpart to the offline `UnitExtractor`.
///
/// Fed mono frames as they arrive (it runs on the recorder's tap serial queue, **off the main
/// actor**), it maintains a sliding RMS envelope and a small state machine that decides when a take's
/// segment(s) start and end, counts discrete events, and measures their inter-onset timing. It returns
/// only ``Event`` values — the recorder owns the audio buffer and slices it by the reported frame
/// ranges. Deterministic and offline-testable with synthetic signals.
///
/// Boundaries are reported in **frames since this analyzer was created** (i.e. since the take's first
/// ingested sample), so the recorder — which buffers the same samples from the same point — can slice
/// `segmentReady` ranges directly.
///
/// Authority note: live detection drives the capture UX and auto-stop only; the offline bank builder
/// re-segments the written audio and remains the source of truth.
public struct CaptureAnalyzer {
    public enum EndReason: Sendable, Equatable {
        /// Hit the fixed duration / `maxSec` cap.
        case duration
        /// Trailing silence ended the take.
        case silence
        /// A `cycle` never produced a full inhale→pause→exhale within `maxCycleSec` (inhale-only).
        case incomplete
        /// `targetEvents` was reached and the shorter post-target trailing silence elapsed.
        case targetReached
    }

    public enum Event: Sendable, Equatable {
        /// Signal first rose above the activity floor — the take/segment has begun.
        case onset
        /// A discrete event (gulp/hook) was detected; `index` is its 0-based ordinal in the take.
        case eventDetected(index: Int)
        /// A finished segment to write, as `[startFrame, endFrame)` since take start.
        case segmentReady(label: SegmentLabel, startFrame: Int, endFrame: Int)
        /// The take is over; the recorder finalizes (validate → write → advance).
        case takeEnded(reason: EndReason)
    }

    /// Why a take was rejected by the structural validity guard — surfaced to the UI so a retake
    /// prompt can name the actual defect instead of one generic sentence.
    public enum TakeIssue: Sendable, Equatable {
        /// A `cycle` take never completed a full inhale→pause→exhale split (missing exhale, or a
        /// manual stop mid-take).
        case noPauseDetected
        case inhaleTooShort
        case exhaleTooShort
        /// The two phases' duration ratio exceeded ``cycleBalanceRatio``.
        case phasesImbalanced(ratio: Double)
        /// A non-`cycle` take produced no segment at all.
        case noSegment
        /// A `finalPhase` take never reached the deliberate pause before `maxTakeSec` — no hold-then-
        /// release detected (a too-short *kept* final phase instead reuses `exhaleTooShort`, since
        /// `finalPhase`'s one real-world consumer, FRC/RV, always keeps an exhale).
        case noPauseBeforeRelease
    }

    // MARK: Tuning

    private static let windowSec = 0.020
    private static let hopSec = 0.010
    /// Active when the envelope exceeds `activityFloorK × noiseFloor` (room-tone-relative gate).
    /// Calibrated against real quiet-room hardware captures (see PR #11): a genuinely gentle/calm
    /// breath's envelope sustains 50ms+ above ~1.3-1.5× a typical room floor, while the room floor
    /// itself never sustains even 30ms at that level — 3.0 sat well above every observed calm-breath
    /// peak, silently requiring near-hyperventilation effort to trigger onset at all.
    private static let activityFloorK: Float = 1.4
    /// Fallback activity floor when no room-tone level is known (~ -48 dBFS).
    private static let absActivityFloor: Float = 0.004
    /// A room-tone reading above this level scales `activityFloorK × noiseFloor` up enough to likely
    /// swallow a genuinely gentle breath (a calm inhale/exhale) — worth a "find a quieter room" prompt
    /// rather than silently degrading onset/event detection. ~4× `absActivityFloor`'s assumed-quiet
    /// fallback (~-36 dBFS vs. the fallback's ~-48 dBFS).
    public static let noisyRoomFloorRMS: Float = 0.015
    /// Hysteresis: once active, stay active until the envelope drops below `threshold × releaseRatio`.
    /// Raised alongside `activityFloorK`'s drop: at a lower `activityFloorK`, the release floor must
    /// stay close to (not far below) the onset threshold so it clears the room floor's typical level —
    /// otherwise a stray room-tone blip that crosses onset threshold gets "stuck" active until the
    /// envelope dips all the way to a release floor sitting below normal room noise, silently resetting
    /// any accumulated pause/trailing-silence progress each time it happens.
    private static let releaseRatio: Float = 0.85
    /// An event peak must exceed this fraction of the take's running peak (matches `UnitExtractor`).
    private static let eventPeakFrac: Float = 0.12
    /// A cycle's two phases must be within this duration ratio to be accepted.
    public static let cycleBalanceRatio = 3.0
    /// An onset is only confirmed once its containing activity run has lasted this long — shorter runs
    /// (a keyboard click, a knock) are discarded and the take stays armed, listening for a real one.
    private static let onsetWidthSec = 0.05
    /// A counted event is only confirmed once its containing activity run has lasted this long. Clicks
    /// (tens of ms) never qualify; gulps/hooks (hundreds of ms) always do.
    private static let minEventWidthSec = 0.10
    /// Once `targetEvents` (where set) is reached, the take ends on this much shorter trailing silence
    /// instead of the full `trailingSilenceSec` — above intra-event dips, far below a typical done-pause.
    private static let postTargetTrailingSec = 0.7
    /// A `pairedEvents` style's brief dip *within* one sip's own motion bridges into the same sip rather
    /// than starting a new one. Sits ~4x below the observed real in/out sip gap (0.73-0.78s, PR #11),
    /// unlike the old distance-based merge which sat right on top of that gap and merged inconsistently.
    private static let sipMergeGapSec = 0.20
    /// Raw-audio history to retain for the spectral event gate — covers the width gate's confirmation
    /// delay (`minEventWidthSec`) plus half the spectral analysis window, with margin.
    private static let rawRetentionSec = 0.4
    /// Spectral analysis window around a confirmed candidate, capped (peak-centered where enough
    /// history is retained on both sides, otherwise whatever's available).
    private static let spectralWindowSec = 0.25
    /// Breath band (Hz) — matches `Grader.Thresholds`' defaults; used for the diagnostic `bandRatio`
    /// feature (see `SpectralCandidate`), not a per-call knob.
    private static let breathBandLowHz = 300.0
    private static let breathBandHighHz = 3000.0
    /// Minimum harvestable quiet stretch — below this it's not worth pooling toward room tone.
    private static let minQuietRangeSec = 0.5
    /// Trailing window the live ambient gate reads from, in seconds — recent enough to react to a
    /// newly-loud room, long enough that the person's own approaching breath (a transient within the
    /// window) doesn't dominate its percentile.
    private static let ambientGateWindowSec = 3.0
    /// Release hysteresis: once held, the trailing window's level must drop this fraction below the
    /// gate bar before the hold releases — avoids flapping right at the boundary.
    private static let ambientGateReleaseRatio: Float = 0.9
    /// The ambient gate can't engage until at least this many armed hops exist — a fresh arm must never
    /// instantly read as "too loud" off a single noisy hop.
    private static let minAmbientGateHops = 150  // 1.5s at the 10ms hop rate

    // MARK: Windowed quiet/loud classifier tuning (see `updateQuietLoudClassifier`)

    /// Trailing window the classifier reads from — long enough that a real ambient burst (measured on
    /// real hardware: 60-200ms, PR #11) is a minority of it, short enough to react promptly to a real
    /// phase change.
    private static let quietWindowSec = 0.4
    /// A classifier verdict (quiet / loud / neither) must persist this many consecutive hops before
    /// it's trusted — the windowed-statistic counterpart to the onset/event width gates.
    private static let quietLoudPersistHops = 5  // ~50ms
    private static let quietBarAmbientFactor: Float = 1.25
    private static let quietBarBreathFactor: Float = 0.40
    private static let loudBarQuietFactor: Float = 1.4
    private static let loudBarBreathFactor: Float = 0.55
    /// Pre-onset, there's no `breathTypical` yet — "loud enough to be onset" is judged against ambient
    /// alone.
    private static let preOnsetLoudAmbientFactor: Float = 1.8
    private static let preOnsetLoudThresholdFactor: Float = 1.2
    /// `.midPause → .exhale`'s release is a *new* phase's onset — same principle as `preOnsetLoud*`
    /// (both encode the same quantity: "sustained loudness distinguishable from bursty ambient"), so it
    /// reuses `preOnsetLoudAmbientFactor` rather than a separately-tuned constant. An initial attempt at
    /// a lower, deliberately-permissive factor (1.4, reasoning that a false release-start is cheap and a
    /// missed one costs the full `maxTakeSec` wait) broke real-hardware-modeled bursty-ambient robustness
    /// — a burst during the pause could clear it — because that same bursty ambient is exactly what
    /// `preOnsetLoudAmbientFactor` is already calibrated to reject at 1.8. The decay toward `endBar`
    /// (below) now covers the "missed release" side (caps worst-case detection at ~5s, not a hang), and
    /// retroactive anchoring (`retroAnchoredReleaseStart`) means a late, decay-caught detection doesn't
    /// truncate the segment's start either — so the cost asymmetry that justified 1.4 no longer applies.
    /// Below this many seconds into the pause, the release bar sits at its base level; from here it
    /// decays linearly to `endBar`'s formula by `releaseBarMinDecayStartSec + releaseBarDecaySpanSec` —
    /// a pause that's run this long is more likely a genuinely gentle release than a still-deliberate
    /// hold, and `endBar` is by definition "distinguishable from quiet," so anything sustained above it
    /// this late is the release, not ambient.
    private static let releaseBarMinDecayStartSec = 2.0
    private static let releaseBarDecaySpanSec = 3.0
    private static let breathTypicalCap = 1000
    /// Hops of confirmed `isLoud` before `breathTypical` is trusted — enough for one percentile
    /// computation to mean something, not so much that a short RV-style exhale never gets one.
    private static let minBreathTypicalHops = 20  // ~0.2s

    // MARK: Config

    public let sampleRate: Double
    public let detection: CaptureDetection
    private let activityThreshold: Float

    private let windowSamples: Int
    private let hopSamples: Int

    // Per-detection frame parameters
    private let trailingFrames: Int
    private let midPauseFrames: Int
    private let maxFrames: Int
    private let minActiveFrames: Int
    private let minGapFrames: Int
    private let refractoryFrames: Int
    private let countsEvents: Bool
    private let isCycle: Bool
    /// `finalPhase` reuses `cycle`'s inhale→pause→exhale routing (`isCycle || finalPhaseOnly` gates
    /// onset → `.inhale`) but suppresses the lead segment and relabels the kept phase `.whole`.
    private let finalPhaseOnly: Bool
    /// `.exhale` for `cycle`, `.whole` for `finalPhase`; unused (never reached) otherwise.
    private let finalSegmentLabel: SegmentLabel
    private let isFixed: Bool
    private let targetEventsCount: Int?
    private let spectralGateProfile: SpectralGateProfile?
    private let onsetWidthFrames: Int
    private let minEventWidthFrames: Int
    private let postTargetTrailingFrames: Int
    private let rawRetentionFrames: Int
    private let spectralWindowFrames: Int
    /// Onset detection is suppressed until `totalFrames` reaches this — see `CaptureDetection.cleanEvents`'s
    /// `postArmBlackoutSec` doc. `0` (every non-counted detection) is a no-op.
    private let blackoutFrames: Int
    /// See `CaptureDetection.cleanEvents`'s `pairedEvents` doc. `false` for every non-counted detection.
    private let pairedEvents: Bool
    private let sipMergeGapFrames: Int

    // MARK: Sliding-RMS ring (squared samples)

    private var ring: [Float]
    private var ringIndex = 0
    private var ringFilled = 0
    private var sumSq: Double = 0
    private var hopCounter = 0
    private var totalFrames = 0

    // MARK: Envelope / activity state

    private var prevEnv: Float = 0
    private var prevPrevEnv: Float = 0
    private var runningPeak: Float = 0
    private var envSum: Double = 0
    private var envCount = 0

    private var isActive = false
    private var silenceFrames = 0
    private var silenceStartFrame = 0
    private var totalActiveFrames = 0
    /// Start of the *current continuous activity run* (resets every `becameActive`) — the basis for
    /// both the onset and event-peak width gates. Distinct from `segmentStartFrame`/`phaseStartFrame`,
    /// which mark segment/phase boundaries and don't reset per intra-take run.
    private var currentRunStartFrame = 0
    /// An onset candidate awaiting width confirmation (armed state only).
    private var pendingOnsetFrame: Int?
    /// An event-peak candidate awaiting width confirmation, at most one per activity run.
    private var pendingPeakFrame: Int?

    // MARK: Pre-onset ambient (rolling noise floor + room-tone harvest — see `preOnsetFloorRMS`)

    /// Envelope hops seen while `.armed` (waiting for onset), oldest-dropped past `armedEnvCap` — this
    /// take's own pre-breath ambient, sampled continuously so it's available the moment onset confirms
    /// (rather than needing a separate measurement pass). ~30s cap is far past any realistic wait.
    private var armedEnvSamples: [Float] = []
    private static let armedEnvCap = 3000
    /// Hops dropped off the front of `armedEnvSamples` past `armedEnvCap` — lets `quietRangeFrames`
    /// map a surviving sample's array index back to its true hop position for a frame-range result.
    private var armedEnvDroppedCount = 0
    /// Frozen once onset confirms: the 20th percentile of `armedEnvSamples` — deliberately a low
    /// percentile, not a mean, because the armed window can genuinely contain a between-takes breath
    /// (the blackout window exists for exactly that) and a mean would count that breath as "ambient,"
    /// inflating the floor. A short wait (under `minPreOnsetFloorHops`) isn't enough hops for a
    /// percentile to mean anything, so it stays `nil` rather than report a noisy estimate.
    public private(set) var preOnsetFloorRMS: Float?
    private static let minPreOnsetFloorHops = 150  // 1.5s at the 10ms hop rate
    /// Frozen alongside `preOnsetFloorRMS`: the longest contiguous armed-period stretch below
    /// `activityThreshold` (i.e. "not yet a confirmed breath," the same boundary `isActive` uses), in
    /// frames since this analyzer's creation — the harvestable room-tone slice of silence this take's
    /// own pre-onset audio already produced. `nil` if nothing that quiet ran long enough (`minQuietRangeSec`).
    public private(set) var quietRangeFrames: Range<Int>?
    /// Session/room property, not a per-style `CaptureDetection` contract — `nil` disables the gate
    /// entirely, preserving prior behavior for every other caller.
    private let ambientGateRMS: Float?
    /// While armed, true when the trailing `ambientGateWindowSec` window's ambient level exceeds
    /// `ambientGateRMS` — onset stays suppressed (see the `.armed` case) until it releases.
    public private(set) var isAmbientHold = false

    // MARK: Windowed quiet/loud classifier (see `updateQuietLoudClassifier`)

    /// This take's own pre-breath ambient reference — the *median* (not the low percentile
    /// `preOnsetFloorRMS` uses) of armed-period hops, refreshed while armed and frozen once onset
    /// confirms. Deliberately a measure of "what ambient typically sounds like," not "the quietest
    /// instant" — see `updateQuietLoudClassifier`'s doc for why that distinction is the whole fix.
    private var ambientTypical: Float?
    /// Seeds `ambientTypical` before this take's own armed hops are sufficient (falls back to the
    /// cross-take rolling floor, then an absolute default) — needed because the classifier is also
    /// consulted for onset itself, before any of this take's own armed data exists.
    private let ambientTypicalFallback: Float
    /// This take's own "how loud is a real breath" reference — the 80th percentile of hops seen while
    /// `isLoud`. `nil` pre-onset and briefly after; `preOnsetLoud*` covers that gap.
    private var breathTypical: Float?
    private var breathLoudSamples: [Float] = []
    /// Ring of the most recent `quietWindowHops` raw envelope hops — the classifier's input.
    private var recentEnv: [Float] = []
    private let quietWindowHops: Int
    private var loudPendingHops = 0
    private var isLoud = false
    /// Two different questions, two different bars, both against the same `windowStat` — see
    /// `updateQuietLoudClassifier`'s doc. `pauseQuiet*` (bar includes a `breathTypical` term) answers
    /// "did airflow just abruptly halt" — a deliberate pause is a discontinuity from a sustained level,
    /// so "well below the breath" is the right, fast discriminator. `endQuiet*` (bar is ambient-relative
    /// only) answers "has this returned to ambient" — the right question for a take's actual end, where
    /// a real exhale's natural decay must be allowed to ride all the way down without a stale
    /// peak-anchored breath reference cutting it off mid-taper (PR #11: FRC/RV real hardware).
    private var pauseQuietPendingHops = 0
    private var isPauseQuiet = false
    private var pauseQuietFrames = 0
    private var pauseQuietStartFrame = 0
    private var endQuietPendingHops = 0
    private var isEndQuiet = false
    private var endQuietFrames = 0
    private var endQuietStartFrame = 0
    /// `.midPause → .exhale`'s release detector — a *new* phase's onset, so (like armed-onset) it's
    /// judged against ambient, never against the pause's preceding phase's `breathTypical`. Decays from
    /// a base bar toward `endBar`'s formula the longer the pause runs — see `releaseBarAmbientFactor`'s
    /// doc and `releaseBarDecayStartFrames`/`releaseBarDecayEndFrames`.
    private var releasePendingHops = 0
    private var isRelease = false
    private let releaseBarDecayStartFrames: Int
    private let releaseBarDecayEndFrames: Int
    /// This pause's `windowStat` per hop, oldest-dropped past `midPauseHistoryCap` — lets a late (decay-
    /// caught) release detection still anchor at the release's true start rather than the detection
    /// frame. See `retroAnchoredReleaseStart`. Cleared on leaving `.midPause`.
    private var midPauseWindowStatHistory: [Float] = []
    private static let midPauseHistoryCap = 800  // ~8s at the 10ms hop rate — past the decay's ~5s cap
    /// The real (non-back-dated) frame `.midPause` was entered — history index 0 corresponds to this
    /// frame, *not* `phaseStartFrame` (which is back-dated to the pause's true start and can sit well
    /// before history collection actually began, since confirming the pause itself takes `midPauseFrames`
    /// + the classifier's own lag). Mapping history indices off `phaseStartFrame` instead produced a
    /// release anchor consistently too early by exactly that gap.
    private var midPauseEntryFrame = 0
    /// The classifier's inherent reaction lag when a *quiet* verdict flips true, in frames — a
    /// `quietWindowSec`-long p40 window only needs `0.4 × quietWindowSec` of it to be quiet before the
    /// 40th-percentile point falls in the quiet region, plus `quietLoudPersistHops`' persistence.
    /// Segment/phase boundaries anchored off `isQuiet` are back-dated by this so audio placement isn't
    /// shifted by the detection delay.
    private let quietDetectionLagFrames: Int
    /// The same lag for a *loud* verdict, asymmetric with the above: at the 40th percentile, the loud
    /// side of the window must dominate ~60% of it (`1 - 0.4`) before the same index reads loud — a
    /// meaningfully longer reaction than the quiet direction, since index 15-of-40 sits closer to the
    /// quiet end. Getting this backwards (treating both directions as symmetric) understates onset
    /// latency and shifts every downstream boundary later by the difference.
    private let loudDetectionLagFrames: Int
    /// The window-domination portion of `loudDetectionLagFrames`, without the persistence term —
    /// `retroAnchoredReleaseStart`'s scan finds the raw frame `windowStat` first crosses `endBar` from
    /// below, which (being a rising crossing on the same p40 statistic) itself lags the true moment by
    /// this much, the same mechanism that motivates `loudDetectionLagFrames` — but the scan isn't
    /// confirming a persisted threshold, just locating a single crossing, so only the window portion
    /// applies.
    private let windowDominationLagFrames: Int

    // MARK: Sip alternator (pairedEvents styles only — see `detectSip`)

    /// Parity of the sip currently in progress or most recently completed: even = inhale, odd = exhale.
    private var sipCount = 0
    /// Frame the in-progress sip's activity run first started, or `nil` between sips.
    private var sipStartFrame: Int?
    private var sipPeakFrame = 0
    private var sipPeakEnv: Float = 0
    private var sipEvaluated = false
    private var sipConfirmed = false
    /// Frame the in-progress sip's activity run ended, pending confirmation it's a real gap (not a
    /// brief bridgeable dip) — `nil` while the sip is still active or no sip is pending finalize.
    private var sipEndFrame: Int?
    /// The current pair's inhale-sip start frame, recorded so the exhale-sip can compute the pair's
    /// anchor-to-anchor interval for `intervalsFrames`.
    private var breathAnchorFrame: Int?

    // MARK: Raw-sample retention (spectral event gate; populated only when `spectralGateProfile != nil`)

    private var rawBuffer: [Float] = []
    /// Absolute frame (`totalFrames`) of `rawBuffer[0]`.
    private var rawBufferStartFrame = 0

    /// One width-confirmed candidate's spectral features and the gate's verdict — populated only when
    /// `spectralGateProfile != nil`. Diagnostic surface for tuning `SpectralGateProfile` presets
    /// against real recordings and for the fixture-replay test harness; not consumed by the state
    /// machine itself (the verdict is applied inline in `detectEventPeak`).
    public struct SpectralCandidate: Sendable, Equatable, Codable {
        public let frame: Int
        public let flatness: Double
        public let bandRatio: Double
        public let centroidHz: Double
        public let windowFrameCount: Int
        public let windowRMS: Double
        public let accepted: Bool
    }
    public private(set) var spectralCandidates: [SpectralCandidate] = []

    // MARK: Capture state machine

    private enum State { case armed, capturing, inhale, midPause, exhale, done }
    private var state: State = .armed
    private var segmentStartFrame = 0
    /// Frame the *current* state was entered — the basis for ``phaseElapsedFrames``.
    private var phaseStartFrame = 0

    /// Coarse live phase for the UI — collapses ``State`` to what's worth showing (`.done` reads as
    /// `.waiting` since a take-ended take is about to be re-armed for the next one).
    public enum LivePhase: Sendable, Equatable {
        case waiting
        case capturing
        case inhale
        case midPause
        case exhale
    }

    public var livePhase: LivePhase {
        switch state {
        case .armed, .done: return .waiting
        case .capturing:
            // A `pairedEvents` style has a real alternating inhale/exhale motion even though the state
            // machine itself has no inhale/exhale sub-state for counted styles — sip parity stands in.
            guard pairedEvents else { return .capturing }
            return sipCount % 2 == 0 ? .inhale : .exhale
        case .inhale: return .inhale
        case .midPause: return .midPause
        case .exhale: return .exhale
        }
    }

    /// Frames elapsed since the current phase (state) began.
    public var phaseElapsedFrames: Int { max(0, totalFrames - phaseStartFrame) }

    // MARK: Public detection results (read by the recorder for live UI)

    public private(set) var eventCount = 0
    public private(set) var intervalsFrames: [Int] = []
    public private(set) var lastGapWithinMin = false
    private var lastPeakFrame: Int?

    /// The most recent envelope value — a smoothed level for the UI meter.
    public var currentLevel: Float { prevEnv }

    /// The envelope level this take's onset/activity gate is set to — lets a UI meter scale itself
    /// relative to "how close to triggering" instead of assuming a fixed absolute amplitude range,
    /// which reads as nearly empty for a genuinely gentle breath and reasonable for a loud one.
    public var currentActivityThreshold: Float { activityThreshold }

    /// This take's post-arm onset blackout window, in seconds (`0` for every non-counted detection) —
    /// lets a UI show a "breathe now" countdown instead of a silently-ignored waiting period.
    public var blackoutSec: Double { Double(blackoutFrames) / sampleRate }

    /// Mean envelope over everything ingested — used on a `fixedDuration` (room-tone) take as the
    /// session noise floor for later steps' activity/event gating.
    public func meanFloorRMS() -> Float { envCount > 0 ? Float(envSum / Double(envCount)) : 0 }

    // MARK: Init

    public init(
        sampleRate: Double, detection: CaptureDetection, noiseFloorRMS: Float?, ambientGateRMS: Float? = nil
    ) {
        self.sampleRate = sampleRate
        self.detection = detection
        self.ambientGateRMS = ambientGateRMS
        windowSamples = max(1, Int(Self.windowSec * sampleRate))
        hopSamples = max(1, Int(Self.hopSec * sampleRate))
        ring = [Float](repeating: 0, count: windowSamples)

        let floorBase = (noiseFloorRMS ?? 0) * Self.activityFloorK
        activityThreshold = max(floorBase, Self.absActivityFloor)
        let sr = sampleRate
        let toFrames: (Double) -> Int = { max(1, Int($0 * sr)) }
        onsetWidthFrames = toFrames(Self.onsetWidthSec)
        minEventWidthFrames = toFrames(Self.minEventWidthSec)
        postTargetTrailingFrames = toFrames(Self.postTargetTrailingSec)
        rawRetentionFrames = toFrames(Self.rawRetentionSec)
        spectralWindowFrames = toFrames(Self.spectralWindowSec)
        sipMergeGapFrames = toFrames(Self.sipMergeGapSec)
        quietWindowHops = max(1, Int(Self.quietWindowSec / Self.hopSec))
        ambientTypicalFallback = noiseFloorRMS ?? (Self.absActivityFloor / Self.activityFloorK)
        let persistSec = Double(Self.quietLoudPersistHops) * Self.hopSec
        quietDetectionLagFrames = toFrames(Self.quietWindowSec * 0.4 + persistSec)
        loudDetectionLagFrames = toFrames(Self.quietWindowSec * 0.6 + persistSec)
        windowDominationLagFrames = toFrames(Self.quietWindowSec * 0.6)

        switch detection {
        case let .fixedDuration(seconds):
            isFixed = true; isCycle = false; finalPhaseOnly = false; finalSegmentLabel = .whole; countsEvents = false
            maxFrames = toFrames(seconds)
            trailingFrames = 0; midPauseFrames = 0; minActiveFrames = 0; minGapFrames = 0
            refractoryFrames = 0; targetEventsCount = nil; spectralGateProfile = nil; blackoutFrames = 0
            pairedEvents = false
            state = .capturing
        case let .cycle(minPhaseSec, midPauseSec, maxCycleSec, trailingSilenceSec, postArmBlackoutSec):
            isFixed = false; isCycle = true; finalPhaseOnly = false; finalSegmentLabel = .exhale; countsEvents = false
            trailingFrames = toFrames(trailingSilenceSec)
            midPauseFrames = toFrames(midPauseSec)
            maxFrames = toFrames(maxCycleSec)
            minActiveFrames = toFrames(minPhaseSec)
            minGapFrames = 0; refractoryFrames = 0; targetEventsCount = nil; spectralGateProfile = nil
            self.blackoutFrames = postArmBlackoutSec > 0 ? toFrames(postArmBlackoutSec) : 0
            pairedEvents = false
        case let .single(minActiveSec, maxTakeSec, trailingSilenceSec, postArmBlackoutSec):
            isFixed = false; isCycle = false; finalPhaseOnly = false; finalSegmentLabel = .whole; countsEvents = false
            trailingFrames = toFrames(trailingSilenceSec)
            maxFrames = toFrames(maxTakeSec)
            minActiveFrames = toFrames(minActiveSec)
            midPauseFrames = 0; minGapFrames = 0; refractoryFrames = 0
            targetEventsCount = nil; spectralGateProfile = nil
            self.blackoutFrames = postArmBlackoutSec > 0 ? toFrames(postArmBlackoutSec) : 0
            pairedEvents = false
        case let .finalPhase(minLeadSec, midPauseSec, _, maxTakeSec, trailingSilenceSec, postArmBlackoutSec):
            // `minPhaseSec` (the kept final phase's minimum) isn't used inside the state machine — it's
            // a post-hoc structural check the recorder makes from `CaptureDetection.minPhaseSec`.
            isFixed = false; isCycle = false; finalPhaseOnly = true; finalSegmentLabel = .whole; countsEvents = false
            trailingFrames = toFrames(trailingSilenceSec)
            midPauseFrames = toFrames(midPauseSec)
            maxFrames = toFrames(maxTakeSec)
            minActiveFrames = toFrames(minLeadSec)
            minGapFrames = 0; refractoryFrames = 0; targetEventsCount = nil; spectralGateProfile = nil
            self.blackoutFrames = postArmBlackoutSec > 0 ? toFrames(postArmBlackoutSec) : 0
            pairedEvents = false
        case let .cleanEvents(minGapSec, maxTakeSec, trailingSilenceSec, eventMinDistSec, targetEvents, spectralGate, postArmBlackoutSec, paired):
            isFixed = false; isCycle = false; finalPhaseOnly = false; finalSegmentLabel = .whole; countsEvents = true
            trailingFrames = toFrames(trailingSilenceSec)
            maxFrames = toFrames(maxTakeSec)
            minGapFrames = toFrames(minGapSec)
            minActiveFrames = 0; midPauseFrames = 0
            refractoryFrames = toFrames(eventMinDistSec)
            targetEventsCount = targetEvents; spectralGateProfile = spectralGate
            self.blackoutFrames = postArmBlackoutSec > 0 ? toFrames(postArmBlackoutSec) : 0
            pairedEvents = paired
        case let .naturalRhythm(minActiveSec, maxTakeSec, trailingSilenceSec, eventMinDistSec, spectralGate, postArmBlackoutSec, paired):
            isFixed = false; isCycle = false; finalPhaseOnly = false; finalSegmentLabel = .whole; countsEvents = true
            trailingFrames = toFrames(trailingSilenceSec)
            maxFrames = toFrames(maxTakeSec)
            minActiveFrames = toFrames(minActiveSec)
            minGapFrames = 0; midPauseFrames = 0
            refractoryFrames = toFrames(eventMinDistSec)
            self.blackoutFrames = postArmBlackoutSec > 0 ? toFrames(postArmBlackoutSec) : 0
            targetEventsCount = nil; spectralGateProfile = spectralGate
            pairedEvents = paired
        }

        // `.midPause → .exhale`'s release decays from a base bar down to `endBar`'s formula the longer
        // the pause runs — see `updateQuietLoudClassifier`'s doc. `3 × midPauseFrames` scales the decay
        // start with a longer configured pause; the 2s floor covers styles where `midPauseFrames` is 0.
        let releaseDecayStart = max(3 * midPauseFrames, toFrames(Self.releaseBarMinDecayStartSec))
        releaseBarDecayStartFrames = releaseDecayStart
        releaseBarDecayEndFrames = releaseDecayStart + toFrames(Self.releaseBarDecaySpanSec)
    }

    // MARK: Ingest

    /// Feed mono frames; returns the events produced. Cheap and allocation-light (one small array; a
    /// bounded raw-history append+trim when the spectral gate is enabled — the trim is a memmove of at
    /// most a few tens of KB per call, negligible next to a ~93ms tap-buffer period).
    public mutating func ingest(_ frames: [Float]) -> [Event] {
        var events: [Event] = []
        if spectralGateProfile != nil { rawBuffer.append(contentsOf: frames) }
        for sample in frames {
            let sq = sample * sample
            if ringFilled < windowSamples {
                sumSq += Double(sq)
                ring[ringIndex] = sq
                ringFilled += 1
            } else {
                sumSq += Double(sq) - Double(ring[ringIndex])
                ring[ringIndex] = sq
            }
            ringIndex += 1
            if ringIndex == windowSamples { ringIndex = 0 }
            totalFrames += 1
            hopCounter += 1
            if hopCounter >= hopSamples {
                hopCounter = 0
                // `sumSq` is a rolling incremental sum (add the newest squared sample, subtract the
                // one falling out of the window) — over a long, quiet take (many hundreds of thousands
                // of hops) floating-point cancellation can tip it *very* slightly negative even though
                // the true sum can't be, and `.squareRoot()` of a negative value is NaN, which corrupts
                // every downstream percentile/comparison for the rest of the take. Clamping is exact for
                // any real signal (a rolling sum of squares is never truly negative) and costs nothing.
                let env = Float(max(0, sumSq / Double(ringFilled)).squareRoot())
                step(env, into: &events)
            }
        }
        if spectralGateProfile != nil, rawBuffer.count > rawRetentionFrames {
            let excess = rawBuffer.count - rawRetentionFrames
            rawBuffer.removeFirst(excess)
            rawBufferStartFrame += excess
        }
        return events
    }

    /// Raw samples for absolute frames `[start, end)`, clamped to what's currently retained. Empty if
    /// nothing in range is retained (spectral gating disabled, or the window has already aged out).
    private func rawWindow(from start: Int, to end: Int) -> [Float] {
        let bufEnd = rawBufferStartFrame + rawBuffer.count
        let lo = max(start, rawBufferStartFrame)
        let hi = min(end, bufEnd)
        guard lo < hi else { return [] }
        return Array(rawBuffer[(lo - rawBufferStartFrame)..<(hi - rawBufferStartFrame)])
    }

    /// Force the current take to end now (manual Stop): emit the in-progress segment with the
    /// boundaries known so far, then `takeEnded`. A `cycle` still mid-inhale ends `.incomplete` (its
    /// already-emitted `.inhale` plus no exhale → the recorder treats it as invalid → auto-redo).
    public mutating func flush() -> [Event] {
        var events: [Event] = []
        let end = totalFrames
        switch state {
        case .armed, .done:
            break
        case .capturing:
            events.append(.segmentReady(label: .whole, startFrame: segmentStartFrame, endFrame: end))
            events.append(.takeEnded(reason: .silence))
        case .inhale:
            if !finalPhaseOnly {
                events.append(.segmentReady(label: .inhale, startFrame: segmentStartFrame, endFrame: end))
            }
            events.append(.takeEnded(reason: .incomplete))
        case .midPause:
            events.append(.takeEnded(reason: .incomplete))
        case .exhale:
            events.append(.segmentReady(label: finalSegmentLabel, startFrame: segmentStartFrame, endFrame: end))
            events.append(.takeEnded(reason: .silence))
        }
        state = .done
        return events
    }

    // MARK: State machine (one envelope sample per hop)

    private mutating func step(_ env: Float, into events: inout [Event]) {
        let currentFrame = totalFrames
        runningPeak = max(runningPeak, env)
        envSum += Double(env)
        envCount += 1

        if isFixed {
            if state == .capturing, currentFrame >= maxFrames {
                events.append(.segmentReady(label: .whole, startFrame: 0, endFrame: currentFrame))
                events.append(.takeEnded(reason: .duration))
                state = .done
            }
            prevPrevEnv = prevEnv; prevEnv = env
            return
        }

        // Activity transitions with hysteresis. Backs the per-hop sip/counted-event layer
        // (`detectSip`/`detectEventPeak`), which needs a fast, run-based signal — not the windowed
        // classifier below, which a real breath's own burst-scale motion would blur.
        let wasActive = isActive
        if isActive {
            if env < activityThreshold * Self.releaseRatio {
                isActive = false
                // The run that just ended is real airflow only if it sustained `onsetWidthFrames` —
                // the same question the onset gate asks of a *rising* run and the event-width gate
                // asks of a counted run (`detectEventPeak`). A single transient hop (room noise
                // brushing the threshold) produces a sub-width run; bridging it — leaving
                // `silenceFrames`/`silenceStartFrame` untouched — keeps accumulated silence intact
                // instead of restarting the count from this instant, which is what let a handful of
                // real hardware ~10ms blips repeatedly reset a take's trailing-silence countdown (PR
                // #11). Strictly greater, not `>=`: a run landing exactly on the boundary is genuinely
                // ambiguous, and bridging costs nothing while wrongly resetting reproduces the bug
                // this guards against — ties favor bridging.
                if currentFrame - currentRunStartFrame > onsetWidthFrames {
                    silenceStartFrame = currentFrame
                    silenceFrames = 0
                }
            }
        } else if env > activityThreshold {
            isActive = true
        }
        if isActive {
            totalActiveFrames += hopSamples
        } else {
            silenceFrames += hopSamples
        }
        let becameActive = !wasActive && isActive
        if becameActive { currentRunStartFrame = max(0, currentFrame - windowSamples) }

        updateQuietLoudClassifier(env: env)

        if state == .armed {
            armedEnvSamples.append(env)
            if armedEnvSamples.count > Self.armedEnvCap {
                armedEnvSamples.removeFirst()
                armedEnvDroppedCount += 1
            }
            updateAmbientHold()
            if armedEnvSamples.count >= Self.minPreOnsetFloorHops {
                ambientTypical = Self.percentile(armedEnvSamples, 0.5)
            }
        }

        switch state {
        case .armed:
            // A held gate suppresses onset candidacy entirely — any in-progress candidate is dropped,
            // same as the run ending on its own, so a room that goes quiet mid-way through what
            // would've been a confirmed onset still requires a fresh run afterward.
            if isAmbientHold {
                pendingOnsetFrame = nil
                break
            }
            // `blackoutFrames` suppresses onset altogether for a moment right after arming — the
            // between-takes exhale/re-inhale a person needs (see `CaptureDetection`'s docs).
            if currentFrame < blackoutFrames { break }
            if countsEvents {
                // Counted styles (packing/recovery): a real event is itself bursty (150-300ms) and
                // close in shape to ambient noise — a burst-robust window statistic would erase the
                // very signal it's meant to detect. Keep the original per-hop, sustained-width gate.
                if becameActive {
                    pendingOnsetFrame = currentRunStartFrame
                }
                if let onset = pendingOnsetFrame {
                    if !isActive {
                        pendingOnsetFrame = nil
                    } else if currentFrame - onset >= onsetWidthFrames {
                        pendingOnsetFrame = nil
                        confirmOnset(at: onset, into: &events)
                    }
                }
            } else {
                // Continuous styles (calm/FRC/RV): onset via the windowed classifier instead — real
                // ambient can itself clear a per-hop threshold for 100ms+ (PR #11 real hardware: one
                // room's ambient p10 sat *above* the activity threshold), so per-hop onset can't tell
                // "the room got briefly loud" from "a breath started." Pre-onset, `isLoud` is judged
                // against `ambientTypical` alone (no `breathTypical` yet) — see the classifier's doc.
                if isLoud {
                    confirmOnset(at: max(0, currentFrame - loudDetectionLagFrames), into: &events)
                }
            }
        case .capturing:
            if countsEvents {
                if pairedEvents {
                    detectSip(env: env, currentFrame: currentFrame, into: &events)
                } else {
                    detectEventPeak(env: env, currentFrame: currentFrame, into: &events)
                }
            }
            let targetHit = targetEventsCount.map { eventCount >= $0 } ?? false
            let requiredTrailing = targetHit ? postTargetTrailingFrames : trailingFrames
            if currentFrame >= maxFrames {
                endWhole(at: currentFrame, reason: .duration, into: &events)
            } else if countsEvents {
                // Counted styles: tried switching this to `isEndQuiet`/`endBar` (no breath term, so the
                // earlier `breathTypical`-contamination concern doesn't apply) — real packing/recovery
                // fixtures broke (`testRealPackingLiveCountTracksOffline` etc.), because the 0.4s
                // classifier window is comparable to or longer than a real inter-event gap, so
                // `windowStat` never reads "quiet" between events at all — a different, still-real
                // mismatch, not leftover caution. Keep the original per-hop signal, which the sip/event
                // layer already bridges against transients.
                if !isActive, silenceFrames >= requiredTrailing, totalActiveFrames >= minActiveFrames {
                    endWhole(at: silenceStartFrame, reason: targetHit ? .targetReached : .silence, into: &events)
                }
            } else if isEndQuiet, endQuietFrames >= requiredTrailing, totalActiveFrames >= minActiveFrames {
                endWhole(at: endQuietStartFrame, reason: targetHit ? .targetReached : .silence, into: &events)
            }
        case .inhale:
            // Require a real phase's worth of airflow before a pause can split: a natural intra-breath
            // dip (which can exceed `midPauseFrames`) must not be mistaken for the inter-phase pause.
            // `finalPhaseOnly` (e.g. FRC/RV's lead inhale) suppresses this segment — it's discarded.
            if isPauseQuiet, pauseQuietFrames >= midPauseFrames, totalActiveFrames >= minActiveFrames {
                if !finalPhaseOnly {
                    events.append(.segmentReady(label: .inhale, startFrame: segmentStartFrame, endFrame: pauseQuietStartFrame))
                }
                phaseStartFrame = pauseQuietStartFrame
                midPauseEntryFrame = currentFrame
                state = .midPause
            } else if currentFrame >= maxFrames {
                events.append(.takeEnded(reason: .incomplete))
                state = .done
            }
        case .midPause:
            // `isRelease`, not `isLoud`/`becameActive`: detecting the release is onset of a *new*
            // phase, so it's judged against ambient (with a decay toward `endBar` the longer the pause
            // runs) — never against `breathTypical`, which describes the *preceding* phase and is
            // categorically the wrong data here (PR #11 real hardware: a passive FRC release quieter
            // than its own lead inhale hung for the full `maxTakeSec` before this fix). A single
            // transient hop still can't end the pause any more than it could end the take — same
            // persistence gate as every other classifier verdict.
            if isRelease {
                let ambient = ambientTypical ?? ambientTypicalFallback
                let endBar = max(ambient * Self.quietBarAmbientFactor, activityThreshold * Self.releaseRatio)
                segmentStartFrame = retroAnchoredReleaseStart(detectionFrame: currentFrame, endBar: endBar)
                phaseStartFrame = segmentStartFrame
                // `endQuietFrames` still holds the pause's own accumulated value (the pause was quiet
                // by construction) — without resetting it, `.exhale`'s own end check inherits an
                // already-satisfied count and can end the take instantly, exactly the bug this session
                // already fixed once for the pre-classifier `silenceFrames` equivalent.
                endQuietFrames = 0
                state = .exhale
            } else if currentFrame >= maxFrames {
                events.append(.takeEnded(reason: .incomplete))
                state = .done
            }
        case .exhale:
            if isEndQuiet, endQuietFrames >= trailingFrames {
                events.append(.segmentReady(label: finalSegmentLabel, startFrame: segmentStartFrame, endFrame: endQuietStartFrame))
                events.append(.takeEnded(reason: .silence))
                state = .done
            } else if currentFrame >= maxFrames {
                events.append(.segmentReady(label: finalSegmentLabel, startFrame: segmentStartFrame, endFrame: currentFrame))
                events.append(.takeEnded(reason: .duration))
                state = .done
            }
        case .done:
            break
        }

        prevPrevEnv = prevEnv; prevEnv = env
    }

    private mutating func endWhole(at endFrame: Int, reason: EndReason, into events: inout [Event]) {
        events.append(.segmentReady(label: .whole, startFrame: segmentStartFrame, endFrame: max(segmentStartFrame, endFrame)))
        events.append(.takeEnded(reason: reason))
        state = .done
    }

    /// Shared onset-confirmation tail for both the counted (per-hop width gate) and continuous
    /// (windowed classifier) `.armed` paths: freeze the pre-onset ambient measurements, emit `.onset`,
    /// and advance to the take's first real state.
    private mutating func confirmOnset(at onset: Int, into events: inout [Event]) {
        segmentStartFrame = onset
        phaseStartFrame = onset
        if armedEnvSamples.count >= Self.minPreOnsetFloorHops {
            preOnsetFloorRMS = Self.percentile(armedEnvSamples, 0.2)
            let minHops = max(1, Int(Self.minQuietRangeSec / Self.hopSec))
            // Quiet = "not yet a confirmed breath," i.e. below the same activity boundary the analyzer
            // already uses to decide isActive — not a tight multiple of the 20th-percentile floor. Real
            // room ambient naturally wanders over a much wider range (observed: 0.00007-0.003 in one
            // quiet room) than a small margin above its quietest instant covers, so a percentile-relative
            // threshold classified nearly the whole armed period as "not quiet enough," harvesting ~0s
            // per take.
            if let idxRange = Self.longestQuietRun(
                armedEnvSamples, threshold: activityThreshold, minCount: minHops
            ) {
                let start = (armedEnvDroppedCount + idxRange.lowerBound) * hopSamples
                let end = (armedEnvDroppedCount + idxRange.upperBound) * hopSamples
                quietRangeFrames = start..<end
            }
        }
        events.append(.onset)
        state = (isCycle || finalPhaseOnly) ? .inhale : .capturing
    }

    /// Classifies the current moment quiet/loud/neither against a windowed, burst-robust statistic (the
    /// 40th percentile of the last `quietWindowSec` of envelope hops) instead of the raw per-hop
    /// envelope. A real room's ambient is not a flat floor — it wanders and bursts — and real hardware
    /// traces (PR #11) showed bursts of 60-200ms clearing the same per-hop threshold a real breath onset
    /// needs to clear, at a rate that made "quiet, uninterrupted, for N ms" essentially unreachable (one
    /// trace's ambient p10 sat *above* the activity threshold — "quiet" barely existed per-hop). A
    /// window statistic tolerant of a minority-duration burst survives exactly that: a burst occupying
    /// under 40% of the window doesn't move the p40 point, while a genuine, sustained resumption of
    /// breathing fills the whole window and reads loud reliably.
    ///
    /// Calibrated against two measurements *this take makes of itself*, not one global constant:
    /// `ambientTypical` (this room, right now, before any breath) and `breathTypical` (this person's own
    /// breath, once one has been heard) — because the gap between a gentle calm breath and windows-open
    /// ambient can be thin, and a fixed ratio tuned for one room fails in a noisier one and vice versa.
    private mutating func updateQuietLoudClassifier(env: Float) {
        recentEnv.append(env)
        if recentEnv.count > quietWindowHops { recentEnv.removeFirst() }
        guard recentEnv.count >= quietWindowHops else { return }

        let ambient = ambientTypical ?? ambientTypicalFallback
        let windowStat = Self.percentile(recentEnv, 0.4)

        // "Did airflow just abruptly halt" (a deliberate pause) — a discontinuity from a sustained
        // breath level, so a breath-relative term is the fast, robust discriminator here.
        let pauseBar = max(
            ambient * Self.quietBarAmbientFactor,
            (breathTypical ?? 0) * Self.quietBarBreathFactor,
            activityThreshold * Self.releaseRatio
        )
        // "Has this returned to ambient" (a take's actual end) — deliberately *no* breath term: a real
        // exhale's natural decay must be allowed to ride all the way down to ambient without a stale,
        // peak-anchored `breathTypical` cutting it off mid-taper (PR #11 real hardware: FRC/RV kept
        // segments truncated to a fraction of their real length, cut at ~40% of the exhale's early
        // peak while the person was still audibly exhaling, just quieter).
        let endBar = max(ambient * Self.quietBarAmbientFactor, activityThreshold * Self.releaseRatio)
        let loudBar: Float
        if let breathTypical {
            loudBar = max(pauseBar * Self.loudBarQuietFactor, breathTypical * Self.loudBarBreathFactor)
        } else {
            loudBar = max(
                ambient * Self.preOnsetLoudAmbientFactor, activityThreshold * Self.preOnsetLoudThresholdFactor
            )
        }

        // Each verdict flips true only once persisted past its own bar; between a quiet bar and
        // `loudBar` is a hold zone where the last verdict sticks (avoids flicker right at a boundary —
        // matches the original single quiet/loud pair's behavior, extended to two independent quiet
        // bars sharing one loud signal). `isLoud` becoming true is the one unambiguous "not quiet"
        // signal, so it clears both quiet verdicts immediately.
        if windowStat > loudBar {
            loudPendingHops += 1
            if loudPendingHops >= Self.quietLoudPersistHops { isLoud = true }
        } else {
            loudPendingHops = 0
            if windowStat < pauseBar { isLoud = false }
        }

        if windowStat < pauseBar {
            pauseQuietPendingHops += 1
            if pauseQuietPendingHops >= Self.quietLoudPersistHops { isPauseQuiet = true }
        } else {
            pauseQuietPendingHops = 0
        }
        if windowStat < endBar {
            endQuietPendingHops += 1
            if endQuietPendingHops >= Self.quietLoudPersistHops { isEndQuiet = true }
        } else {
            endQuietPendingHops = 0
        }
        if isLoud {
            isPauseQuiet = false
            isEndQuiet = false
        }

        // Don't let a blackout-window between-takes breath (deliberately absorbed, not part of this
        // take — see `CaptureDetection`'s `postArmBlackoutSec` doc) seed `breathTypical`; it isn't this
        // take's breath.
        let inBlackout = state == .armed && totalFrames < blackoutFrames
        if isLoud, !inBlackout {
            breathLoudSamples.append(env)
            if breathLoudSamples.count > Self.breathTypicalCap { breathLoudSamples.removeFirst() }
            if breathLoudSamples.count >= Self.minBreathTypicalHops {
                breathTypical = Self.percentile(breathLoudSamples, 0.8)
            }
        }

        if isPauseQuiet {
            if pauseQuietFrames == 0 { pauseQuietStartFrame = max(0, totalFrames - quietDetectionLagFrames) }
            pauseQuietFrames += hopSamples
        } else {
            pauseQuietFrames = 0
        }
        if isEndQuiet {
            if endQuietFrames == 0 { endQuietStartFrame = max(0, totalFrames - quietDetectionLagFrames) }
            endQuietFrames += hopSamples
        } else {
            endQuietFrames = 0
        }

        // Release detection (`.midPause → .exhale` only): a *new* phase's onset, judged against ambient
        // like any onset — never against the pause's preceding phase's `breathTypical`, which is stale
        // data for "did a new phase begin" (PR #11 real hardware: a passive FRC release topped out well
        // below the loud lead-inhale's `breathTypical`, so `loudBar` never cleared and the take hung for
        // the full `maxTakeSec`). Decays toward `endBar` the longer the pause runs.
        if state == .midPause {
            let pauseElapsed = totalFrames - phaseStartFrame
            // `recentEnv` (and so `windowStat`) is a single ring shared across the whole take, not
            // reset per phase — right as `.midPause` begins it can still hold up to `quietWindowHops`
            // residual hops from the just-ended, louder `.inhale` tail. With `releaseBar`'s base this
            // close to ambient, that leftover contamination alone can clear it before the ring has had
            // a chance to fill with genuine pause-only samples, firing a false release at the pause's
            // very start. Hold off until the window has fully refreshed since the pause began.
            if pauseElapsed >= quietWindowHops * hopSamples {
                let base = max(ambient * Self.preOnsetLoudAmbientFactor, activityThreshold)
                let releaseBar: Float
                if pauseElapsed <= releaseBarDecayStartFrames {
                    releaseBar = base
                } else if pauseElapsed >= releaseBarDecayEndFrames {
                    releaseBar = endBar
                } else {
                    let span = Float(releaseBarDecayEndFrames - releaseBarDecayStartFrames)
                    let t = Float(pauseElapsed - releaseBarDecayStartFrames) / span
                    releaseBar = base + (endBar - base) * t
                }
                if windowStat > releaseBar {
                    releasePendingHops += 1
                    if releasePendingHops >= Self.quietLoudPersistHops { isRelease = true }
                } else {
                    releasePendingHops = 0
                }
            }
            // Kept for `retroAnchoredReleaseStart` — the decay can legitimately take several seconds to
            // confirm a genuinely faint release, and without this history the segment would be anchored
            // to the (late) detection moment instead of where the release actually began.
            midPauseWindowStatHistory.append(windowStat)
            if midPauseWindowStatHistory.count > Self.midPauseHistoryCap { midPauseWindowStatHistory.removeFirst() }
        } else {
            releasePendingHops = 0
            isRelease = false
            midPauseWindowStatHistory.removeAll(keepingCapacity: true)
        }
    }

    /// The true release start, however long `isRelease` took to confirm: scans this pause's
    /// `windowStat` history backward for the last hop that was still genuinely quiet (below `endBar`)
    /// and anchors there instead of at the (possibly much later) detection frame. For a prompt
    /// detection (a loud release, confirmed within ~persistence) this lands at essentially the same
    /// frame the old fixed-lag backdating produced — it's the universal anchor, not a special late-
    /// detection path. Falls back to the fixed lag if history is empty (shouldn't happen: a pause is
    /// quiet by construction at entry).
    private func retroAnchoredReleaseStart(detectionFrame: Int, endBar: Float) -> Int {
        for i in stride(from: midPauseWindowStatHistory.count - 1, through: 0, by: -1) {
            if midPauseWindowStatHistory[i] < endBar {
                let crossingFrame = midPauseEntryFrame + (i + 1) * hopSamples
                return max(0, crossingFrame - windowDominationLagFrames)
            }
        }
        return max(0, detectionFrame - loudDetectionLagFrames)
    }

    /// One-hop-lookahead local-max peak picker, width-gated: a peak-shaped candidate (`prevEnv ≥
    /// prevPrevEnv` then falling, clearing the event threshold) is tracked but not yet counted; it's
    /// only confirmed once *its containing activity run* has lasted `minEventWidthFrames` — a click
    /// whose run ends first is discarded, as if it never happened. At most one pending candidate is
    /// tracked per run (a run confirmed once stays confirmed for any later peak within the same run).
    private mutating func detectEventPeak(env: Float, currentFrame: Int, into events: inout [Event]) {
        // Frozen once the target is reached — the take is just waiting out the post-target trailing
        // silence now, so further activity (including the keyboard sounds that used to keep piling up
        // past the target) is neither counted nor allowed to reset that shorter silence window.
        if let target = targetEventsCount, eventCount >= target { return }
        if pendingPeakFrame == nil {
            let threshold = max(activityThreshold, Self.eventPeakFrac * runningPeak)
            if prevEnv >= threshold, prevEnv >= prevPrevEnv, prevEnv > env {
                pendingPeakFrame = max(0, currentFrame - hopSamples)
                print("[CAL-EVENT] candidate frame=\(pendingPeakFrame!) prevEnv=\(String(format: "%.4f", prevEnv)) threshold=\(String(format: "%.4f", threshold)) runningPeak=\(String(format: "%.4f", runningPeak))")
            }
        }
        guard let candidate = pendingPeakFrame else { return }
        if !isActive {
            print("[CAL-EVENT] rejected frame=\(candidate) reason=run-ended-too-soon")
            pendingPeakFrame = nil  // the run that contained this candidate ended too soon — a click
            return
        }
        guard currentFrame - currentRunStartFrame >= minEventWidthFrames else { return }  // keep waiting
        pendingPeakFrame = nil

        // Spectral gate: reject a width-confirmed candidate whose spectrum is clearly non-breath (a
        // typing roll wide enough to pass the width gate, nearby speech). Discarded exactly like a
        // width-gate rejection — no event, no interval, `lastPeakFrame` untouched so it can't distort
        // the refractory spacing between two genuine events either side of it.
        if spectralGateProfile != nil, !isCandidateBreathShaped(candidate) {
            print("[CAL-EVENT] rejected frame=\(candidate) reason=spectral-gate")
            return
        }

        if let last = lastPeakFrame, candidate - last < refractoryFrames {
            print("[CAL-EVENT] rejected frame=\(candidate) reason=refractory gap=\(candidate - last) needed=\(refractoryFrames)")
            return
        }
        if let last = lastPeakFrame {
            let gap = candidate - last
            intervalsFrames.append(gap)
            lastGapWithinMin = minGapFrames > 0 && gap < minGapFrames
        } else {
            lastGapWithinMin = false
        }
        print("[CAL-EVENT] CONFIRMED frame=\(candidate) index=\(eventCount) runningPeak=\(String(format: "%.4f", runningPeak))")
        lastPeakFrame = candidate
        events.append(.eventDetected(index: eventCount))
        eventCount += 1
    }

    /// `pairedEvents` counterpart to `detectEventPeak`: recovery's hook breath is physiologically a
    /// strict alternation (inhale-sip, then exhale-sip, always in that order — you cannot inhale twice
    /// without exhaling between). Rather than merging a hook's two sips into one event by distance (the
    /// same ~0.7-0.85s gap can mean "same hook's second sip" or "next hook's first sip" depending on the
    /// person's cadence — real hardware data this session showed gaps landing right on that boundary,
    /// so merging succeeded or failed unpredictably), this counts each confirmed *activity run* as one
    /// sip, toggles alternating parity on every sip, and completes one breath (`eventDetected`) every
    /// second sip. A brief dip below `sipMergeGapFrames` inside one sip's own motion bridges into the
    /// same sip rather than starting a new one.
    private mutating func detectSip(env: Float, currentFrame: Int, into events: inout [Event]) {
        if let target = targetEventsCount, eventCount >= target { return }

        if isActive {
            if sipEndFrame != nil {
                sipEndFrame = nil  // a brief dip bridged back within the merge window — same sip continues
            } else if sipStartFrame == nil {
                sipStartFrame = currentRunStartFrame
                sipPeakFrame = currentRunStartFrame
                sipPeakEnv = env
                sipEvaluated = false
                sipConfirmed = false
            }
            if let start = sipStartFrame {
                if env > sipPeakEnv { sipPeakEnv = env; sipPeakFrame = currentFrame }
                if !sipEvaluated, currentFrame - start >= minEventWidthFrames {
                    sipEvaluated = true
                    sipConfirmed = spectralGateProfile == nil || isCandidateBreathShaped(sipPeakFrame)
                }
            }
        } else if sipStartFrame != nil, sipEndFrame == nil {
            sipEndFrame = silenceStartFrame
        }

        if let start = sipStartFrame, let end = sipEndFrame, currentFrame - end >= sipMergeGapFrames {
            if sipConfirmed { finalizeSip(startFrame: start, currentFrame: currentFrame, into: &events) }
            sipStartFrame = nil; sipPeakFrame = 0; sipEvaluated = false; sipConfirmed = false; sipEndFrame = nil
        }
    }

    /// One completed, width/spectral-confirmed sip: on the pair's first (even parity) sip, just anchor
    /// it; on the second (odd parity) sip, the pair is complete — record its anchor-to-anchor interval
    /// and emit the breath. An unconfirmed sip never reaches here, so parity only advances on real sips.
    ///
    /// Deliberately does *not* touch `phaseStartFrame`: `livePhase`'s inhale/exhale label for a paired
    /// style comes from `sipCount` parity alone (see `livePhase`), not from `phaseStartFrame` — that
    /// field's only live consumer for a paired counted style is `phaseFloorHint`'s take-length-floor
    /// readout, which needs elapsed time since the *take's* onset. Resetting it here (as an earlier
    /// version of this method did, mirroring `cycle`'s real phase-transition resets) instead reset the
    /// clock on every sip, making that readout count up from ~0 after each inhale/exhale instead of
    /// accumulating toward the take's length floor — reported on real hardware as the "needs ≥Xs"
    /// counter resetting mid-take on "Recovery — natural rhythm."
    private mutating func finalizeSip(startFrame: Int, currentFrame: Int, into events: inout [Event]) {
        if sipCount % 2 == 0 {
            breathAnchorFrame = startFrame
        } else if let anchor = breathAnchorFrame {
            let gap = startFrame - anchor
            intervalsFrames.append(gap)
            lastGapWithinMin = minGapFrames > 0 && gap < minGapFrames
            events.append(.eventDetected(index: eventCount))
            eventCount += 1
        }
        sipCount += 1
    }

    /// Why a `cycle` take's two phase durations (frames) fail the plausible-split guard, or `nil` if
    /// they pass: each at least `minPhaseFrames`, and within ``cycleBalanceRatio``. The structural
    /// guard against a missing mid-pause (1 segment) or a turbulence-induced false split (2 lopsided
    /// segments) — the grader is *not* a reliable phase backstop for soft broadband airflow.
    public static func cycleIssue(inhaleFrames: Int, exhaleFrames: Int, minPhaseFrames: Int) -> TakeIssue? {
        if inhaleFrames < minPhaseFrames { return .inhaleTooShort }
        if exhaleFrames < minPhaseFrames { return .exhaleTooShort }
        let lo = Double(min(inhaleFrames, exhaleFrames))
        let hi = Double(max(inhaleFrames, exhaleFrames))
        guard lo > 0 else { return .inhaleTooShort }
        let ratio = hi / lo
        return ratio > cycleBalanceRatio ? .phasesImbalanced(ratio: ratio) : nil
    }

    /// Whether a `cycle` take's two phase durations (frames) are a plausible split. Thin wrapper over
    /// ``cycleIssue(inhaleFrames:exhaleFrames:minPhaseFrames:)`` for callers that only need the bool.
    public static func cycleSegmentsValid(inhaleFrames: Int, exhaleFrames: Int, minPhaseFrames: Int) -> Bool {
        cycleIssue(inhaleFrames: inhaleFrames, exhaleFrames: exhaleFrames, minPhaseFrames: minPhaseFrames) == nil
    }

    /// Whether a room-tone reading (`BreathRecorder.lastNoiseFloorRMS`) is loud enough to warrant a
    /// "find a quieter room" prompt before technique capture starts — see ``noisyRoomFloorRMS``.
    public static func isRoomTooNoisy(_ meanFloorRMS: Float) -> Bool {
        meanFloorRMS > noisyRoomFloorRMS
    }

    /// Spectral breath-shape check for a width-confirmed event candidate, reusing the same
    /// `SpectralDenoise.magnitudeProfile` + `SpectralFeatures` formulas the offline `Grader` grades
    /// fragments with. An empty profile (too little retained history at the candidate's position, or a
    /// window too short for even one FFT frame) is never rejected — the width gate already filtered
    /// out anything that short, so an empty profile here means "not enough context," not "not breath."
    private mutating func isCandidateBreathShaped(_ candidate: Int) -> Bool {
        let half = spectralWindowFrames / 2
        let window = rawWindow(from: candidate - half, to: candidate + half)
        let profile = SpectralDenoise.magnitudeProfile(from: window, sampleRate: sampleRate)
        let binHz = sampleRate / 1024.0
        let flat = SpectralFeatures.flatness(profile)
        let ratio = SpectralFeatures.bandEnergyRatio(
            profile, binHz: binHz, low: Self.breathBandLowHz, high: Self.breathBandHighHz)
        let centroid = SpectralFeatures.centroid(profile, binHz: binHz)
        var sumSq: Double = 0
        for s in window { sumSq += Double(s) * Double(s) }
        let rms = window.isEmpty ? 0 : (sumSq / Double(window.count)).squareRoot()
        let accepted = profile.isEmpty
            || (spectralGateProfile?.accepts(flatness: flat, bandRatio: ratio, centroidHz: centroid) ?? true)
        spectralCandidates.append(SpectralCandidate(
            frame: candidate, flatness: flat, bandRatio: ratio, centroidHz: centroid,
            windowFrameCount: window.count, windowRMS: rms, accepted: accepted))
        return accepted
    }

    /// The value at `fraction` (0...1) through a sorted copy of `values` — a low fraction (e.g. 0.2)
    /// reads the quiet end of a mixed-content window (ambient + occasional breath) without needing to
    /// separate the two explicitly, since the breath only ever occupies a minority of the samples.
    private static func percentile(_ values: [Float], _ fraction: Double) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = min(sorted.count - 1, max(0, Int(Double(sorted.count - 1) * fraction)))
        return sorted[index]
    }

    /// The longest contiguous index range in `values` where every element is `<= threshold`, or `nil`
    /// if the longest such stretch is shorter than `minCount`.
    private static func longestQuietRun(_ values: [Float], threshold: Float, minCount: Int) -> Range<Int>? {
        var bestStart = 0, bestLen = 0
        var runStart = 0, runLen = 0
        for (i, v) in values.enumerated() {
            if v <= threshold {
                if runLen == 0 { runStart = i }
                runLen += 1
                if runLen > bestLen { bestLen = runLen; bestStart = runStart }
            } else {
                runLen = 0
            }
        }
        guard bestLen >= minCount else { return nil }
        return bestStart..<(bestStart + bestLen)
    }

    /// Live pre-onset ambient check while armed: the trailing `ambientGateWindowSec` window's 20th
    /// percentile against `ambientGateRMS`, with release hysteresis so it doesn't flap right at the
    /// boundary. A low percentile (not a mean) so the person's own approaching breath — a transient
    /// within the window — doesn't itself read as "the room is loud."
    private mutating func updateAmbientHold() {
        guard let gateRMS = ambientGateRMS, armedEnvSamples.count >= Self.minAmbientGateHops else { return }
        let windowHops = max(1, Int(Self.ambientGateWindowSec / Self.hopSec))
        let window = Array(armedEnvSamples.suffix(windowHops))
        let level = Self.percentile(window, 0.2)
        if isAmbientHold {
            if level < gateRMS * Self.ambientGateReleaseRatio { isAmbientHold = false }
        } else if level > gateRMS {
            isAmbientHold = true
        }
    }
}
