import BreathBank
import Foundation
import Vapor

/// Holds one live `EnrollmentEngine` per active enrollment session, keyed by session ID — so a dropped
/// WebSocket reconnecting (the plan's `resume` message) finds the *same* engine, with its captured
/// files, rolling noise floor, and live grader all intact, rather than starting over. Idle-evicted so a
/// participant who closes the tab mid-session doesn't leak an actor forever.
actor EnrollmentSessionRegistry {
    private var engines: [UUID: EnrollmentEngine] = [:]
    private var lastSeen: [UUID: Date] = [:]

    /// Returns the existing engine for `sessionID` if one is already live (a reconnect), else builds and
    /// registers a new one via `makeNew()`. The caller is responsible for calling `start()` only on a
    /// genuinely new engine — `wasExisting` tells it which case this was.
    func engine(
        for sessionID: UUID, makeNew: @Sendable () -> EnrollmentEngine
    ) -> (engine: EnrollmentEngine, wasExisting: Bool) {
        lastSeen[sessionID] = Date()
        if let existing = engines[sessionID] {
            return (existing, true)
        }
        let created = makeNew()
        engines[sessionID] = created
        return (created, false)
    }

    /// Reconnect/keepalive marker — call whenever a session's socket is actively in use, independent of
    /// whether `engine(for:makeNew:)` was also called this round.
    func touch(_ sessionID: UUID) {
        lastSeen[sessionID] = Date()
    }

    func remove(_ sessionID: UUID) {
        engines[sessionID] = nil
        lastSeen[sessionID] = nil
    }

    /// Drops every session untouched for longer than `maxIdle`, returning their IDs for logging.
    @discardableResult
    func evictIdle(olderThan maxIdle: TimeInterval, now: Date = Date()) -> [UUID] {
        let cutoff = now.addingTimeInterval(-maxIdle)
        let idle = lastSeen.filter { $0.value < cutoff }.map(\.key)
        for id in idle {
            engines[id] = nil
            lastSeen[id] = nil
        }
        return idle
    }
}

extension Application {
    private struct EnrollmentSessionRegistryKey: StorageKey {
        typealias Value = EnrollmentSessionRegistry
    }

    var enrollmentSessions: EnrollmentSessionRegistry {
        get {
            guard let store = self.storage[EnrollmentSessionRegistryKey.self] else {
                fatalError("EnrollmentSessionRegistry not configured — call configureEnrollmentSessions(_:) first")
            }
            return store
        }
        set { self.storage[EnrollmentSessionRegistryKey.self] = newValue }
    }
}
