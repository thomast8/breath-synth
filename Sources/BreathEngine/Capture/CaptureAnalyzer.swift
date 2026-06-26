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

    // MARK: Tuning

    private static let windowSec = 0.020
    private static let hopSec = 0.010
    /// Active when the envelope exceeds `activityFloorK × noiseFloor` (room-tone-relative gate).
    private static let activityFloorK: Float = 3.0
    /// Fallback activity floor when no room-tone level is known (~ -48 dBFS).
    private static let absActivityFloor: Float = 0.004
    /// Hysteresis: once active, stay active until the envelope drops below `threshold × releaseRatio`.
    private static let releaseRatio: Float = 0.6
    /// An event peak must exceed this fraction of the take's running peak (matches `UnitExtractor`).
    private static let eventPeakFrac: Float = 0.12
    /// Refractory spacing between counted events (matches the offline gulp cadence floor).
    private static let eventRefractorySec = UnitExtractor.gulpMinDistSec
    /// A cycle's two phases must be within this duration ratio to be accepted.
    public static let cycleBalanceRatio = 3.0

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
    private let isFixed: Bool

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

    // MARK: Capture state machine

    private enum State { case armed, capturing, inhale, midPause, exhale, done }
    private var state: State = .armed
    private var segmentStartFrame = 0

    // MARK: Public detection results (read by the recorder for live UI)

    public private(set) var eventCount = 0
    public private(set) var intervalsFrames: [Int] = []
    public private(set) var lastGapWithinMin = false
    private var lastPeakFrame: Int?

    /// The most recent envelope value — a smoothed level for the UI meter.
    public var currentLevel: Float { prevEnv }

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
        refractoryFrames = toFrames(Self.eventRefractorySec)

        switch detection {
        case let .fixedDuration(seconds):
            isFixed = true; isCycle = false; countsEvents = false
            maxFrames = toFrames(seconds)
            trailingFrames = 0; midPauseFrames = 0; minActiveFrames = 0; minGapFrames = 0
            state = .capturing
        case let .cycle(minPhaseSec, midPauseSec, maxCycleSec, trailingSilenceSec):
            isFixed = false; isCycle = true; countsEvents = false
            trailingFrames = toFrames(trailingSilenceSec)
            midPauseFrames = toFrames(midPauseSec)
            maxFrames = toFrames(maxCycleSec)
            minActiveFrames = toFrames(minPhaseSec)
            minGapFrames = 0
        case let .single(minActiveSec, maxTakeSec, trailingSilenceSec):
            isFixed = false; isCycle = false; countsEvents = false
            trailingFrames = toFrames(trailingSilenceSec)
            maxFrames = toFrames(maxTakeSec)
            minActiveFrames = toFrames(minActiveSec)
            midPauseFrames = 0; minGapFrames = 0
        case let .cleanEvents(minGapSec, maxTakeSec, trailingSilenceSec):
            isFixed = false; isCycle = false; countsEvents = true
            trailingFrames = toFrames(trailingSilenceSec)
            maxFrames = toFrames(maxTakeSec)
            minGapFrames = toFrames(minGapSec)
            minActiveFrames = 0; midPauseFrames = 0
        case let .naturalRhythm(minActiveSec, maxTakeSec, trailingSilenceSec):
            isFixed = false; isCycle = false; countsEvents = true
            trailingFrames = toFrames(trailingSilenceSec)
            maxFrames = toFrames(maxTakeSec)
            minActiveFrames = toFrames(minActiveSec)
            minGapFrames = 0; midPauseFrames = 0
        }
    }

    // MARK: Ingest

    /// Feed mono frames; returns the events produced. Cheap and allocation-light (one small array).
    public mutating func ingest(_ frames: [Float]) -> [Event] {
        var events: [Event] = []
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
        return events
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
            events.append(.segmentReady(label: .inhale, startFrame: segmentStartFrame, endFrame: end))
            events.append(.takeEnded(reason: .incomplete))
        case .midPause:
            events.append(.takeEnded(reason: .incomplete))
        case .exhale:
            events.append(.segmentReady(label: .exhale, startFrame: segmentStartFrame, endFrame: end))
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

        switch state {
        case .armed:
            if becameActive {
                segmentStartFrame = max(0, currentFrame - windowSamples)
                events.append(.onset)
                state = isCycle ? .inhale : .capturing
            }
        case .capturing:
            if countsEvents { detectEventPeak(env: env, currentFrame: currentFrame, into: &events) }
            if currentFrame >= maxFrames {
                endWhole(at: currentFrame, reason: .duration, into: &events)
            } else if !isActive, silenceFrames >= trailingFrames, totalActiveFrames >= minActiveFrames {
                endWhole(at: silenceStartFrame, reason: .silence, into: &events)
            }
        case .inhale:
            // Require a real phase's worth of airflow before a pause can split: a natural intra-breath
            // dip (which can exceed `midPauseFrames`) must not be mistaken for the inter-phase pause.
            if !isActive, silenceFrames >= midPauseFrames, totalActiveFrames >= minActiveFrames {
                events.append(.segmentReady(label: .inhale, startFrame: segmentStartFrame, endFrame: silenceStartFrame))
                state = .midPause
            } else if currentFrame >= maxFrames {
                events.append(.takeEnded(reason: .incomplete))
                state = .done
            }
        case .midPause:
            if becameActive {
                segmentStartFrame = max(0, currentFrame - windowSamples)
                state = .exhale
            } else if currentFrame >= maxFrames {
                events.append(.takeEnded(reason: .incomplete))
                state = .done
            }
        case .exhale:
            if !isActive, silenceFrames >= trailingFrames {
                events.append(.segmentReady(label: .exhale, startFrame: segmentStartFrame, endFrame: silenceStartFrame))
                events.append(.takeEnded(reason: .silence))
                state = .done
            } else if currentFrame >= maxFrames {
                events.append(.segmentReady(label: .exhale, startFrame: segmentStartFrame, endFrame: currentFrame))
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

    /// One-hop-lookahead local-max peak picker: the previous hop is a peak if it rose (`prevEnv ≥
    /// prevPrevEnv`) then fell (`prevEnv > env`), clears the event threshold, and is at least the
    /// refractory distance from the last counted peak. The peak's frame is one hop back.
    private mutating func detectEventPeak(env: Float, currentFrame: Int, into events: inout [Event]) {
        let threshold = max(activityThreshold, Self.eventPeakFrac * runningPeak)
        guard prevEnv >= threshold, prevEnv >= prevPrevEnv, prevEnv > env else { return }
        let peakFrame = max(0, currentFrame - hopSamples)
        if let last = lastPeakFrame, peakFrame - last < refractoryFrames { return }
        if let last = lastPeakFrame {
            let gap = peakFrame - last
            intervalsFrames.append(gap)
            lastGapWithinMin = minGapFrames > 0 && gap < minGapFrames
        } else {
            lastGapWithinMin = false
        }
        lastPeakFrame = peakFrame
        events.append(.eventDetected(index: eventCount))
        eventCount += 1
    }

    /// Whether a `cycle` take's two phase durations (frames) are a plausible split: each at least
    /// `minPhaseFrames`, and within ``cycleBalanceRatio``. The structural guard against a missing
    /// mid-pause (1 segment) or a turbulence-induced false split (2 lopsided segments) — the grader is
    /// *not* a reliable phase backstop for soft broadband airflow.
    public static func cycleSegmentsValid(inhaleFrames: Int, exhaleFrames: Int, minPhaseFrames: Int) -> Bool {
        guard inhaleFrames >= minPhaseFrames, exhaleFrames >= minPhaseFrames else { return false }
        let lo = Double(min(inhaleFrames, exhaleFrames))
        let hi = Double(max(inhaleFrames, exhaleFrames))
        return lo > 0 && hi / lo <= cycleBalanceRatio
    }
}
