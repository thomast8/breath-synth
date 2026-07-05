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
        // Vapor's async `webSocket` bridge runs this whole function inside an unstructured `Task`
        // (`Task { await onUpgrade(...) }`), so the underlying channel can already be accepting frames
        // — and the client can already be sending them, the instant it sees the HTTP 101 response —
        // before this Task has even started running, let alone reached any particular line. Every
        // `await` before `onText`/`onBinary` are registered widens a real window in which the client's
        // first frame(s) (typically `hello`) silently vanish into WebSocketKit's default no-op handler,
        // hanging the session forever with no error on either side. So: register the callbacks as the
        // very first action, with zero `await` beforehand, queuing into the stream below; everything
        // that legitimately needs to be async (session validation, storage resolution, building the
        // handler) happens after, and any frames that arrive during that work are queued, not dropped.
        let (frames, continuation) = AsyncStream<InboundFrame>.makeStream()
        do {
            // `onText`/`onBinary` write into a NIO-loop-confined box that asserts it's set from `ws`'s
            // own event loop; `submit` hops onto it explicitly so this is safe regardless of which
            // thread this function is actually running on when it reaches this point.
            try await ws.eventLoop.submit {
                ws.onText { _, text in continuation.yield(.text(text)) }
                ws.onBinary { _, buffer in continuation.yield(.binary([UInt8](buffer.readableBytesView))) }
                ws.onClose.whenComplete { _ in
                    continuation.yield(.disconnect)
                    continuation.finish()
                }
            }.get()
        } catch {
            req.logger.error("live session \(sessionID): failed to register socket callbacks: \(error)")
            continuation.finish()
            return
        }

        guard (try? await EnrollSession.find(sessionID, on: req.db)) != nil else {
            try? await ws.close(code: .unacceptableData)
            return
        }

        let assetsDir = URL(fileURLWithPath: req.application.directory.workingDirectory)
            .appendingPathComponent("Resources/gold-refs", isDirectory: true)
        let outputDir: URL
        do {
            outputDir = try await req.application.storageDriver.localURL(forKey: "sessions/\(sessionID)/raw")
            // `localURL(forKey:)` only resolves a path-safety-checked URL — unlike `put(_:key:)`, it
            // never creates the directory. `TakeCaptureEngine` writes segment WAVs directly into this
            // directory via `AudioIO.writeMonoWAV` (bypassing `put` entirely), so without this the first
            // write on every new session throws "no such file or directory" — and `finalize()` swallows
            // that into a silent `teardown()` with no verdict, no error message, nothing sent to the
            // client. The session just hangs forever after the very first take.
            try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
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

        // Vapor invokes `onText`/`onBinary` serially, in arrival order, on the connection's event loop —
        // but spawning an independent `Task` per callback throws that ordering away (Swift makes no
        // guarantee unstructured tasks *begin* in creation order), which could let a `startStep` race
        // behind an audio chunk and silently wedge the session (feed to an unarmed engine, dropped).
        // `continuation.yield` is synchronous, so enqueuing happens in the exact order Vapor calls back;
        // one consumer `Task` then drains the queue and awaits `handler` strictly in that order.
        Task {
            for await frame in frames {
                switch frame {
                case let .text(text): await handler.handle(text: text)
                case let .binary(bytes): await handler.handle(binary: bytes)
                case .disconnect: await handler.handleDisconnect()
                }
            }
        }
    }

    private enum InboundFrame: Sendable {
        case text(String)
        case binary([UInt8])
        case disconnect
    }

    /// Persists one `Take` row per (step, lane) sharing `laneSlug` — see `lanesBySlug`'s doc comment.
    /// Verdict fields are intentionally minimal (`accept: true`, no reason/advisory/fragment counts): the
    /// take this row describes was accepted at write time (a redo never reaches `emit()`, so it never
    /// reaches here) — a *later* take at the same (laneSlug, role, takeIndex) can still demote this row
    /// to `.redone` below, same as the row's own history always allowed. The richer live verdict is
    /// already visible to the participant in real time over the socket — archiving it to SQL too is a
    /// nice-to-have, not required for the export pipeline (`SessionExporter` filters on `status ==
    /// .kept` and never reads the verdict fields at all).
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
