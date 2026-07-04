import BreathBank
import Foundation
import Vapor

/// Holds one `LiveTakeGrader` per active enrollment session, created once that session's room tone
/// is uploaded — mirrors the native `EnrollModel`'s session-scoped `liveGrader`, whose cross-take
/// sibling accumulation only makes sense per session, not globally. Actor-isolated for safe
/// concurrent access across requests (multiple participants enrolling at once).
actor GradingSessionStore {
    private var graders: [UUID: LiveTakeGrader] = [:]
    private let assetsDir: URL

    init(assetsDir: URL) {
        self.assetsDir = assetsDir
    }

    func makeGrader(sessionID: UUID, roomToneURL: URL?) {
        graders[sessionID] = LiveTakeGrader(roomToneURL: roomToneURL, assetsDir: assetsDir)
    }

    func grader(for sessionID: UUID) -> LiveTakeGrader? {
        graders[sessionID]
    }

    func removeGrader(sessionID: UUID) {
        graders[sessionID] = nil
    }
}

extension Application {
    private struct GradingSessionStoreKey: StorageKey {
        typealias Value = GradingSessionStore
    }

    var gradingSessions: GradingSessionStore {
        get {
            guard let store = self.storage[GradingSessionStoreKey.self] else {
                fatalError("GradingSessionStore not configured — call configureGrading(_:) first")
            }
            return store
        }
        set { self.storage[GradingSessionStoreKey.self] = newValue }
    }
}
