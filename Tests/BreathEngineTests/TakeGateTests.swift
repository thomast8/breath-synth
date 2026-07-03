import XCTest

@testable import BreathEngine

/// Pure decision-table tests for the recorder's take-lifecycle gate — no mic, no `AVAudioEngine`, no
/// async wait required, since `TakeGate` is extracted precisely so this logic is testable this way.
final class TakeGateTests: XCTestCase {
    private let maxRetries = 3

    func testStructuralInvalidUnderCapAlwaysRedoesRegardlessOfReviewer() {
        for retries in 0..<maxRetries {
            for hasReviewer in [true, false] {
                XCTAssertEqual(
                    TakeGate.decide(structurallyValid: false, retries: retries, maxRetries: maxRetries, hasReviewer: hasReviewer),
                    .redoNow, "retries=\(retries) reviewer=\(hasReviewer)"
                )
            }
        }
    }

    func testStructuralInvalidAtCapForceAccepts() {
        for hasReviewer in [true, false] {
            XCTAssertEqual(
                TakeGate.decide(structurallyValid: false, retries: maxRetries, maxRetries: maxRetries, hasReviewer: hasReviewer),
                .emit, "reviewer=\(hasReviewer)"
            )
        }
    }

    func testValidWithNoReviewerAlwaysEmitsRegardlessOfRetries() {
        for retries in 0...maxRetries {
            XCTAssertEqual(
                TakeGate.decide(structurallyValid: true, retries: retries, maxRetries: maxRetries, hasReviewer: false),
                .emit, "retries=\(retries)"
            )
        }
    }

    func testValidWithReviewerUnderCapGoesToReview() {
        for retries in 0..<maxRetries {
            XCTAssertEqual(
                TakeGate.decide(structurallyValid: true, retries: retries, maxRetries: maxRetries, hasReviewer: true),
                .review, "retries=\(retries)"
            )
        }
    }

    func testValidWithReviewerAtCapForceAcceptsSkippingReview() {
        XCTAssertEqual(
            TakeGate.decide(structurallyValid: true, retries: maxRetries, maxRetries: maxRetries, hasReviewer: true),
            .emit
        )
    }

    func testResolveStaleVerdictAlwaysDropsRegardlessOfContent() {
        XCTAssertEqual(TakeGate.resolve(verdict: .accept, isStale: true), .drop)
        XCTAssertEqual(TakeGate.resolve(verdict: .redo, isStale: true), .drop)
    }

    func testResolveFreshVerdictMapsDirectly() {
        XCTAssertEqual(TakeGate.resolve(verdict: .accept, isStale: false), .emit)
        XCTAssertEqual(TakeGate.resolve(verdict: .redo, isStale: false), .redo)
    }
}
