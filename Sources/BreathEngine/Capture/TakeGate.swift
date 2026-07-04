import Foundation

/// Pure take-lifecycle decision for `BreathRecorder.finalize` — extracted so the redo/review/emit
/// logic is unit-testable without a live mic or `AVAudioEngine`. The recorder is a thin driver: it
/// computes the inputs, calls these two functions, and acts on the result.
public enum TakeGate {
    /// What to do with a just-finalized take, decided before any segment is written.
    public enum Decision: Sendable, Equatable {
        /// Structurally invalid and under the retry cap — discard, re-arm, listen again.
        case redoNow
        /// Accept immediately: either structurally invalid but the cap is spent (force-accept), or
        /// valid with no reviewer configured. Segments are written and `onSegment` fires right away.
        case emit
        /// Structurally valid, a reviewer is configured, and the cap isn't spent — write segments,
        /// hold for the async grade before firing `onSegment`.
        case review
    }

    /// - Parameters:
    ///   - structurallyValid: the take passed `takeIssue` (cycle balance, `finalPhase` pause, etc).
    ///   - retries: consecutive auto-redos so far this take slot (`takeRetries`).
    ///   - maxRetries: the shared cap (`maxTakeRetries`).
    ///   - hasReviewer: whether `onTakeReview` is configured for this session.
    public static func decide(structurallyValid: Bool, retries: Int, maxRetries: Int, hasReviewer: Bool) -> Decision {
        if !structurallyValid {
            return retries < maxRetries ? .redoNow : .emit
        }
        if !hasReviewer || retries >= maxRetries {
            return .emit
        }
        return .review
    }

    /// What to do once an async review verdict arrives for a take that was put under `.review`.
    public enum ReviewOutcome: Sendable, Equatable {
        /// Fire `onSegment` for the already-written files and advance.
        case emit
        /// Discard the written files' registration (they get overwritten in place) and re-arm.
        case redo
        /// The wait was invalidated (abort/`cancelTake`/config-change) before the verdict arrived —
        /// do nothing; whatever state change caused the staleness already handled the take.
        case drop
    }

    /// - Parameters:
    ///   - verdict: what the app's `onTakeReview` callback returned.
    ///   - isStale: `true` if the recorder session moved on (stopped recording, or the take was
    ///     cancelled/re-armed) while the async grade was in flight.
    public static func resolve(verdict: TakeReview, isStale: Bool) -> ReviewOutcome {
        guard !isStale else { return .drop }
        switch verdict {
        case .accept: return .emit
        case .redo: return .redo
        }
    }
}

/// The app's live per-take grading verdict, returned from `BreathRecorder`'s `onTakeReview` callback.
public enum TakeReview: Sendable {
    case accept
    case redo
}
