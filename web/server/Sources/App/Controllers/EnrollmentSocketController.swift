import BreathBank
import BreathEngineCore
import Fluent
import Vapor

/// Wires `EnrollmentSocketHandler` to a real Vapor `WebSocket` and Fluent — the handler itself knows
/// nothing about either (see its own doc comment), which is what makes it testable without a live
/// socket or database.
struct EnrollmentSocketController {
    /// Every `(step, lane)` pair in the full catalog (including the conditional packing fallback),
    /// grouped by lane slug — a hybrid step (packing) has two lanes sharing one slug under different
    /// roles, so `onSegment`'s single `segmentWritten` event (one per physical file) still produces one
    /// `Take` row per role, matching the pre-WS REST flow's dual-role upload behavior.
    private static let lanesBySlug: [String: [(step: EnrollmentStep, lane: CaptureLane)]] = {
        let allSteps = EnrollmentScript.steps + [EnrollmentScript.packingSeparatedFallback]
        var out: [String: [(EnrollmentStep, CaptureLane)]] = [:]
        for step in allSteps {
            for lane in step.lanes {
                out[lane.slug, default: []].append((step, lane))
            }
        }
        return out
    }()

    static func attach(_ ws: WebSocket, sessionID: UUID, req: Request) async {
        let outputDir: URL
        let assetsDir = URL(fileURLWithPath: req.application.directory.workingDirectory)
            .appendingPathComponent("Resources/gold-refs", isDirectory: true)
        do {
            outputDir = try await req.application.storageDriver.localURL(forKey: "sessions/\(sessionID)/raw")
        } catch {
            req.logger.error("live session \(sessionID): failed to resolve storage dir: \(error)")
            try? await ws.close()
            return
        }

        let handler = EnrollmentSocketHandler(
            sessionID: sessionID, outputDir: outputDir, assetsDir: assetsDir,
            registry: req.application.enrollmentSessions,
            send: { message in
                guard let data = try? JSONEncoder().encode(message), let text = String(data: data, encoding: .utf8)
                else { return }
                try? await ws.send(text)
            },
            onSegment: { takeIndex, laneSlug, filename in
                await persistSegment(
                    sessionID: sessionID, takeIndex: takeIndex, laneSlug: laneSlug, filename: filename,
                    db: req.db, storage: req.application.storageDriver)
            },
            onRoomTone: { filename in
                await persistRoomTone(sessionID: sessionID, filename: filename, db: req.db)
            }
        )

        ws.onText { _, text in
            Task { await handler.handle(text: text) }
        }
        ws.onBinary { _, buffer in
            let bytes = [UInt8](buffer.readableBytesView)
            Task { await handler.handle(binary: bytes) }
        }
        ws.onClose.whenComplete { _ in
            Task { await handler.handleDisconnect() }
        }
    }

    /// Persists one `Take` row per (step, lane) sharing `laneSlug` — see `lanesBySlug`'s doc comment.
    /// Verdict fields are intentionally minimal (`accept: true`, no reason/advisory/fragment counts):
    /// `segmentWritten` only ever fires for a take that was ultimately *accepted* (a redo never reaches
    /// `emit()`, so it never reaches here), and the richer live verdict is already visible to the
    /// participant in real time over the socket — archiving it to SQL too is a nice-to-have, not
    /// required for the export pipeline (`SessionExporter` never reads these fields).
    private static func persistSegment(
        sessionID: UUID, takeIndex: Int, laneSlug: String, filename: String, db: any Database,
        storage: any StorageDriver
    ) async {
        guard let pairs = lanesBySlug[laneSlug] else { return }
        let objectKey = "sessions/\(sessionID)/raw/\(filename)"
        let probed: (durationSec: Double, sampleRate: Double, channels: Int)?
        if let fileURL = try? await storage.localURL(forKey: objectKey) {
            probed = try? AudioIO.probe(url: fileURL)
        } else {
            probed = nil
        }
        for (step, lane) in pairs {
            do {
                if let previous = try await Take.query(on: db)
                    .filter(\.$session.$id == sessionID)
                    .filter(\.$laneSlug == laneSlug)
                    .filter(\.$role == lane.role)
                    .filter(\.$takeIndex == takeIndex)
                    .filter(\.$status == .kept)
                    .first()
                {
                    previous.status = .redone
                    try await previous.save(on: db)
                }
                let take = Take(
                    sessionID: sessionID, stepSlug: step.title, laneSlug: laneSlug, style: lane.style,
                    breathType: lane.type.rawValue, renderMode: step.renderMode.rawValue, role: lane.role,
                    takeIndex: takeIndex, reference: lane.reference, objectKey: objectKey,
                    durationSec: probed?.durationSec ?? 0, sampleRate: probed?.sampleRate ?? 0,
                    peak: nil, rms: nil, verdictAccept: true, verdictReason: nil, verdictAdvisory: [],
                    fragmentsAccepted: nil, fragmentsTotal: nil, status: .kept, clientMeta: nil
                )
                try await take.save(on: db)
            } catch {
                // Best-effort audit trail: a DB write failure here must not tear down the live session
                // (the WAV file itself is already safely on disk) — the offline `breath-bank build`
                // reads from the exported directory, not this row, so a missing row degrades the admin
                // export view, not the corpus.
            }
        }
    }

    private static func persistRoomTone(sessionID: UUID, filename: String, db: any Database) async {
        guard let session = try? await EnrollSession.find(sessionID, on: db) else { return }
        session.roomToneObjectKey = "sessions/\(sessionID)/raw/\(filename)"
        try? await session.save(on: db)
    }
}
