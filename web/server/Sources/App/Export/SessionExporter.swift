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

        var filesByLane: [String: [String]] = [:]
        var stepsByLane: [String: Take] = [:]
        for take in takes {
            let filename = "\(take.laneSlug)_take\(take.takeIndex).wav"
            filesByLane[take.laneSlug, default: []].append(filename)
            stepsByLane[take.laneSlug] = take
        }

        let steps: [CaptureSession.Step] = stepsByLane.keys.sorted().compactMap { lane in
            guard let representative = stepsByLane[lane] else { return nil }
            guard let type = BreathType(rawValue: representative.breathType),
                  let renderMode = RenderMode(rawValue: representative.renderMode) else { return nil }
            return CaptureSession.Step(
                slug: lane, style: representative.style, type: type, renderMode: renderMode,
                role: representative.role, reference: representative.reference,
                files: filesByLane[lane] ?? []
            )
        }

        let roomToneFilename = session.roomToneObjectKey != nil ? "room_tone.wav" : nil
        let captureSession = CaptureSession(roomTone: roomToneFilename, steps: steps)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let capturesJSON = try encoder.encode(captureSession)

        var entries: [ZipWriter.Entry] = [.init(name: "captures.json", data: capturesJSON)]
        for take in takes {
            let data = try await storage.get(key: take.objectKey)
            entries.append(.init(name: "\(take.laneSlug)_take\(take.takeIndex).wav", data: data))
        }
        if let roomToneKey = session.roomToneObjectKey, let roomToneFilename {
            let data = try await storage.get(key: roomToneKey)
            entries.append(.init(name: roomToneFilename, data: data))
        }

        return ZipWriter.write(entries)
    }
}
