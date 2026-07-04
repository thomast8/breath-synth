import BreathBank
import BreathEngineCore
import Fluent
import Foundation
import Vapor

/// Builds the exact `captures.json` shape `swift run breath-bank build` expects, plus a ZIP of
/// every kept take and the room tone, so `POST /api/admin/sessions/:id/export`'s output can be fed
/// straight into that CLI unchanged.
enum SessionExporter {
    static func export(session: EnrollSession, on db: any Database, storage: any StorageDriver) async throws -> Data {
        let sessionID = try session.requireID()
        let takes = try await Take.query(on: db)
            .filter(\.$session.$id == sessionID)
            .filter(\.$status == .kept)
            .sort(\.$takeIndex)
            .all()

        // Grouped by (laneSlug, role), not laneSlug alone: packing uploads the same recording
        // twice under one shared laneSlug ("packing_cadence") with two different roles
        // ("cores"/"gaps") — collapsing on laneSlug alone would silently drop one of the two
        // roles' `captures.json` step entries (native parity needs both, each listing the same
        // files, exactly like `CaptureLane`'s two same-slug entries in the native script).
        var filesByKey: [String: [String]] = [:]
        var stepsByKey: [String: Take] = [:]
        for take in takes {
            let key = "\(take.laneSlug)|\(take.role)"
            let filename = "\(take.laneSlug)_take\(take.takeIndex).wav"
            filesByKey[key, default: []].append(filename)
            stepsByKey[key] = take
        }

        let steps: [CaptureSession.Step] = stepsByKey.keys.sorted().compactMap { key in
            guard let representative = stepsByKey[key] else { return nil }
            guard let type = BreathType(rawValue: representative.breathType),
                  let renderMode = RenderMode(rawValue: representative.renderMode) else { return nil }
            return CaptureSession.Step(
                slug: representative.laneSlug, style: representative.style, type: type,
                renderMode: renderMode, role: representative.role, reference: representative.reference,
                files: filesByKey[key] ?? []
            )
        }

        let roomToneFilename = session.roomToneObjectKey != nil ? "room_tone.wav" : nil
        let captureSession = CaptureSession(roomTone: roomToneFilename, steps: steps)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let capturesJSON = try encoder.encode(captureSession)

        var entries: [ZipWriter.Entry] = [.init(name: "captures.json", data: capturesJSON)]
        // Dedupe by filename: packing's cores/gaps takes share one physical recording per
        // (laneSlug, takeIndex), so without this the same bytes would be written into the ZIP
        // twice under the identical entry name (harmless content-wise, but most unzip tools don't
        // handle duplicate entry names gracefully).
        var writtenFilenames: Set<String> = []
        for take in takes {
            let filename = "\(take.laneSlug)_take\(take.takeIndex).wav"
            guard !writtenFilenames.contains(filename) else { continue }
            // Defense-in-depth against zip-slip: `laneSlug` was validated at intake
            // (`TakesController`), but this re-checks independently rather than trusting that
            // every write path into `takes` remembered to — an entry name like "../../etc/foo"
            // would let a naive `unzip` on whoever downloads this archive write outside the
            // target directory.
            guard SlugValidation.isSafe(take.laneSlug) else {
                throw Abort(.internalServerError, reason: "Unsafe lane slug in stored take: \(take.laneSlug)")
            }
            let data = try await storage.get(key: take.objectKey)
            entries.append(.init(name: filename, data: data))
            writtenFilenames.insert(filename)
        }
        if let roomToneKey = session.roomToneObjectKey, let roomToneFilename {
            let data = try await storage.get(key: roomToneKey)
            entries.append(.init(name: roomToneFilename, data: data))
        }

        return ZipWriter.write(entries)
    }
}
