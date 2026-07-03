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
    /// Frozen once onset confirms: the 20th percentile of `armedEnvSamples` — deliberately a low
    /// percentile, not a mean, because the armed window can genuinely contain a between-takes breath
    /// (the blackout window exists for exactly that) and a mean would count that breath as "ambient,"
    /// inflating the floor. A short wait (under `minPreOnsetFloorHops`) isn't enough hops for a
    /// percentile to mean anything, so it stays `nil` rather than report a noisy estimate.
    public private(set) var preOnsetFloorRMS: Float?
    private static let minPreOnsetFloorHops = 150  // 1.5s at the 10ms hop rate

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

    public init(sampleRate: Double, detection: CaptureDetection, noiseFloorRMS: Float?) {
        self.sampleRate = sampleRate
        self.detection = detection
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

        switch detection {
        case let .fixedDuration(seconds):
            isFixed = true; isCycle = false; finalPhaseOnly = false; finalSegmentLabel = .whole; countsEvents = false
            maxFrames = toFrames(seconds)
            trailingFrames = 0; midPauseFrames = 0; minActiveFrames = 0; minGapFrames = 0
            refractoryFrames = 0; targetEventsCount = nil; spectralGateProfile = nil; blackoutFrames = 0
            pairedEvents = false
            state = .capturing
        case let .cycle(minPhaseSec, midPauseSec, maxCycleSec, trailingSilenceSec):
            isFixed = false; isCycle = true; finalPhaseOnly = false; finalSegmentLabel = .exhale; countsEvents = false
            trailingFrames = toFrames(trailingSilenceSec)
            midPauseFrames = toFrames(midPauseSec)
            maxFrames = toFrames(maxCycleSec)
            minActiveFrames = toFrames(minPhaseSec)
            minGapFrames = 0; refractoryFrames = 0; targetEventsCount = nil; spectralGateProfile = nil; blackoutFrames = 0
            pairedEvents = false
        case let .single(minActiveSec, maxTakeSec, trailingSilenceSec):
            isFixed = false; isCycle = false; finalPhaseOnly = false; finalSegmentLabel = .whole; countsEvents = false
            trailingFrames = toFrames(trailingSilenceSec)
            maxFrames = toFrames(maxTakeSec)
            minActiveFrames = toFrames(minActiveSec)
            midPauseFrames = 0; minGapFrames = 0; refractoryFrames = 0
            targetEventsCount = nil; spectralGateProfile = nil; blackoutFrames = 0
            pairedEvents = false
        case let .finalPhase(minLeadSec, midPauseSec, _, maxTakeSec, trailingSilenceSec):
            // `minPhaseSec` (the kept final phase's minimum) isn't used inside the state machine — it's
            // a post-hoc structural check the recorder makes from `CaptureDetection.minPhaseSec`.
            isFixed = false; isCycle = false; finalPhaseOnly = true; finalSegmentLabel = .whole; countsEvents = false
            trailingFrames = toFrames(trailingSilenceSec)
            midPauseFrames = toFrames(midPauseSec)
            maxFrames = toFrames(maxTakeSec)
            minActiveFrames = toFrames(minLeadSec)
            minGapFrames = 0; refractoryFrames = 0; targetEventsCount = nil; spectralGateProfile = nil; blackoutFrames = 0
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
                let env = Float((sumSq / Double(ringFilled)).squareRoot())
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
            print("[CAL-ROOM] frame=\(currentFrame) env=\(String(format: "%.5f", env))")
            prevPrevEnv = prevEnv; prevEnv = env
            return
        }

        // Activity transitions with hysteresis.
        let wasActive = isActive
        if isActive {
            if env < activityThreshold * Self.releaseRatio {
                isActive = false
                silenceStartFrame = currentFrame
                silenceFrames = 0
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

        if state == .armed {
            armedEnvSamples.append(env)
            if armedEnvSamples.count > Self.armedEnvCap { armedEnvSamples.removeFirst() }
            print("[CAL-ARMED] frame=\(currentFrame) env=\(String(format: "%.5f", env)) threshold=\(String(format: "%.5f", activityThreshold)) active=\(isActive)")
        }

        switch state {
        case .armed:
            // Onset is confirmed only once its containing run has lasted `onsetWidthFrames` — a click
            // that ends before that stays un-onset and the take keeps listening for a real one.
            // `blackoutFrames` additionally suppresses onset altogether for a moment right after
            // arming — the counted-event styles' between-takes exhale/re-inhale, with nothing like
            // `finalPhase`'s discarded lead phase to absorb it (see `CaptureDetection.cleanEvents`).
            if currentFrame < blackoutFrames { break }
            if becameActive {
                pendingOnsetFrame = currentRunStartFrame
            }
            if let onset = pendingOnsetFrame {
                if !isActive {
                    pendingOnsetFrame = nil
                } else if currentFrame - onset >= onsetWidthFrames {
                    pendingOnsetFrame = nil
                    segmentStartFrame = onset
                    phaseStartFrame = onset
                    if armedEnvSamples.count >= Self.minPreOnsetFloorHops {
                        preOnsetFloorRMS = Self.percentile(armedEnvSamples, 0.2)
                    }
                    events.append(.onset)
                    state = (isCycle || finalPhaseOnly) ? .inhale : .capturing
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
            } else if !isActive, silenceFrames >= requiredTrailing, totalActiveFrames >= minActiveFrames {
                endWhole(at: silenceStartFrame, reason: targetHit ? .targetReached : .silence, into: &events)
            }
        case .inhale:
            // Require a real phase's worth of airflow before a pause can split: a natural intra-breath
            // dip (which can exceed `midPauseFrames`) must not be mistaken for the inter-phase pause.
            // `finalPhaseOnly` (e.g. FRC/RV's lead inhale) suppresses this segment — it's discarded.
            if !isActive, silenceFrames >= midPauseFrames, totalActiveFrames >= minActiveFrames {
                if !finalPhaseOnly {
                    events.append(.segmentReady(label: .inhale, startFrame: segmentStartFrame, endFrame: silenceStartFrame))
                }
                phaseStartFrame = silenceStartFrame
                state = .midPause
            } else if currentFrame >= maxFrames {
                events.append(.takeEnded(reason: .incomplete))
                state = .done
            }
        case .midPause:
            if becameActive {
                segmentStartFrame = max(0, currentFrame - windowSamples)
                phaseStartFrame = segmentStartFrame
                state = .exhale
            } else if currentFrame >= maxFrames {
                events.append(.takeEnded(reason: .incomplete))
                state = .done
            }
        case .exhale:
            if !isActive, silenceFrames >= trailingFrames {
                events.append(.segmentReady(label: finalSegmentLabel, startFrame: segmentStartFrame, endFrame: silenceStartFrame))
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
}
