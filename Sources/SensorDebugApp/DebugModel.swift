import BluetoothStack
import Foundation
import Observation

/// Drives a `BLECentral` for the debug GUI: scan → connect → inventory → live raw hex + decoded
/// measurements. All state is `@Observable` for SwiftUI; everything stays on the main actor. Every
/// event is also fanned out through `SessionLogger` (live SSE stream + JSONL file) so an external
/// observer sees exactly what the GUI sees.
@MainActor
@Observable
final class DebugModel {
    enum Phase: Equatable {
        case idle
        case scanning
        case connecting
        case connected
        case failed(String)
    }

    enum ParserChoice: String, CaseIterable, Identifiable {
        case auto, plxs, proprietary
        var id: String { rawValue }
    }

    struct LogLine: Identifiable {
        let id = UUID()
        let monotonic: Double
        let characteristic: String
        let hex: String
    }

    private let central = BLECentral()
    private let logger = SessionLogger()
    private var scanTask: Task<Void, Never>?
    private var rawTask: Task<Void, Never>?
    private var measureTask: Task<Void, Never>?

    var phase: Phase = .idle
    var authorization: String = ""
    var devices: [DiscoveredPeripheral] = []
    var connectedName: String?
    var services: [ServiceInfo] = []
    var latest: PulseOxMeasurement?
    var log: [LogLine] = []
    var parserChoice: ParserChoice = .auto

    private let logLimit = 500

    /// Where an external observer can watch this session live.
    var logPath: String { logger.url.path }
    var streamURL: String { "http://127.0.0.1:\(logger.server.port)/" }

    func refreshAuthorization() {
        authorization = central.authorizationDescription
        logger.log("auth", ["value": authorization, "stream": streamURL, "file": logPath])
    }

    func startScan() {
        devices = []
        phase = .scanning
        logger.log("scan_start")
        scanTask?.cancel()
        scanTask = Task { @MainActor in
            do {
                try await self.central.waitUntilReady()
            } catch {
                self.fail(error)
                return
            }
            for await device in self.central.scan() {
                if let index = self.devices.firstIndex(where: { $0.id == device.id }) {
                    self.devices[index] = device
                } else {
                    self.devices.append(device)
                    self.logger.log("device", [
                        "id": device.id.uuidString,
                        "name": device.name ?? NSNull(),
                        "rssi": device.rssi,
                        "services": device.advertisedServices,
                        "connectable": device.isConnectable,
                    ])
                }
            }
        }
    }

    func stopScan() {
        central.finishActiveStreams()
        scanTask?.cancel()
        if phase == .scanning { phase = .idle }
        logger.log("scan_stop")
    }

    func connect(to device: DiscoveredPeripheral) {
        scanTask?.cancel()
        central.finishActiveStreams()
        phase = .connecting
        connectedName = device.name ?? device.id.uuidString
        logger.log("connecting", ["id": device.id.uuidString, "name": connectedName ?? NSNull()])
        Task { @MainActor in
            do {
                try await self.central.connect(matching: .id(device.id), timeout: 15)
                self.services = try await self.central.inventory(readValues: true)
                self.phase = .connected
                self.logger.log("connected", ["name": self.connectedName ?? NSNull()])
                self.logger.log("gatt", ["services": self.gattJSON()])
                self.startStreaming()
            } catch {
                self.fail(error)
            }
        }
    }

    func disconnect() {
        rawTask?.cancel()
        measureTask?.cancel()
        central.finishActiveStreams()
        central.disconnect()
        phase = .idle
        services = []
        latest = nil
        connectedName = nil
        logger.log("disconnect")
    }

    func clearLog() {
        log = []
    }

    private func fail(_ error: Error) {
        let message = (error as? BLEError)?.description ?? "\(error)"
        phase = .failed(message)
        logger.log("error", ["message": message])
    }

    private func makeParser() -> MeasurementParser {
        switch parserChoice {
        case .plxs: return PLXSParser()
        case .proprietary: return ProprietaryPM100Parser()
        case .auto:
            let hasPLXS = services.contains { $0.uuid.localizedCaseInsensitiveContains("1822") }
            return hasPLXS ? PLXSParser() : ProprietaryPM100Parser()
        }
    }

    private func startStreaming() {
        logger.log("parser", ["choice": parserChoice.rawValue])
        let rawStream = central.notifications()
        let measureStream = central.measurements(using: makeParser())

        rawTask = Task { @MainActor in
            for await note in rawStream {
                let hex = Self.hex(note.data)
                self.log.append(LogLine(monotonic: note.monotonicSeconds, characteristic: note.characteristicUUID, hex: hex))
                if self.log.count > self.logLimit {
                    self.log.removeFirst(self.log.count - self.logLimit)
                }
                self.logger.log("notify", [
                    "t": note.monotonicSeconds,
                    "char": note.characteristicUUID,
                    "len": note.data.count,
                    "hex": hex,
                ])
            }
        }
        measureTask = Task { @MainActor in
            for await measurement in measureStream {
                self.latest = measurement
                self.logger.log("measurement", [
                    "spo2": measurement.spo2 ?? NSNull(),
                    "pr": measurement.pulseRate ?? NSNull(),
                    "finger": measurement.fingerDetected,
                    "quality": measurement.quality.rawValue,
                    "hex": Self.hex(measurement.raw),
                ])
            }
        }
        Task { @MainActor in
            do {
                try await self.central.subscribe(characteristics: nil)
            } catch {
                self.fail(error)
            }
        }
    }

    private func gattJSON() -> [[String: Any]] {
        services.map { service in
            [
                "uuid": service.uuid,
                "name": service.knownName ?? NSNull(),
                "chars": service.characteristics.map { ch in
                    [
                        "uuid": ch.uuid,
                        "name": ch.knownName ?? NSNull(),
                        "props": ch.properties.shortDescription,
                        "valueHex": ch.value.map { Self.hex($0) } ?? NSNull(),
                    ] as [String: Any]
                },
            ] as [String: Any]
        }
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}
