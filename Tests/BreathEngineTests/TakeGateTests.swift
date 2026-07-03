import Testing

@testable import BreathEngine

/// Pure decision-table tests for the recorder's take-lifecycle gate — no mic, no `AVAudioEngine`, no
/// async wait required, since `TakeGate` is extracted precisely so this logic is testable this way.
struct TakeGateTests {
    private let maxRetries = 3

    @Test func structuralInvalidUnderCapAlwaysRedoesRegardlessOfReviewer() {
        for retries in 0..<maxRetries {
            for hasReviewer in [true, false] {
                #expect(
                    TakeGate.decide(structurallyValid: false, retries: retries, maxRetries: maxRetries, hasReviewer: hasReviewer)
                    == .redoNow, "retries=\(retries) reviewer=\(hasReviewer)"
                )
            }
        }
    }

    @Test func structuralInvalidAtCapForceAccepts() {
        for hasReviewer in [true, false] {
            #expect(
                TakeGate.decide(structurallyValid: false, retries: maxRetries, maxRetries: maxRetries, hasReviewer: hasReviewer)
                == .emit, "reviewer=\(hasReviewer)"
            )
        }
    }

    @Test func validWithNoReviewerAlwaysEmitsRegardlessOfRetries() {
        for retries in 0...maxRetries {
            #expect(
                TakeGate.decide(structurallyValid: true, retries: retries, maxRetries: maxRetries, hasReviewer: false)
                == .emit, "retries=\(retries)"
            )
        }
    }

    @Test func validWithReviewerUnderCapGoesToReview() {
        for retries in 0..<maxRetries {
            #expect(
                TakeGate.decide(structurallyValid: true, retries: retries, maxRetries: maxRetries, hasReviewer: true)
                == .review, "retries=\(retries)"
            )
        }
    }

    @Test func validWithReviewerAtCapForceAcceptsSkippingReview() {
        #expect(
            TakeGate.decide(structurallyValid: true, retries: maxRetries, maxRetries: maxRetries, hasReviewer: true)
            == .emit
        )
    }

    @Test func resolveStaleVerdictAlwaysDropsRegardlessOfContent() {
        #expect(TakeGate.resolve(verdict: .accept, isStale: true) == .drop)
        #expect(TakeGate.resolve(verdict: .redo, isStale: true) == .drop)
    }

    @Test func resolveFreshVerdictMapsDirectly() {
        #expect(TakeGate.resolve(verdict: .accept, isStale: false) == .emit)
        #expect(TakeGate.resolve(verdict: .redo, isStale: false) == .redo)
    }
}
