import BluetoothStack
import Foundation

/// Main-actor orchestration for the `sensor` subcommands. Keeping the whole flow on `@MainActor`
/// means the `BLECentral` (also main-actor) and its `AsyncStream`s are used without cross-actor
/// hops; `for await` suspends the actor so CoreBluetooth's delegate callbacks can run.
@MainActor
enum SensorRunner {
    // MARK: scan

    static func scan(nameFilter: String?) async throws {
        let central = BLECentral()
        try await central.waitUntilReady()
        let source = installInterruptHandler { Task { @MainActor in central.finishActiveStreams() } }
        defer { source.cancel() }

        print("scanning — Ctrl-C to stop")
        var seen = Set<UUID>()
        for await peripheral in central.scan() {
            if let nameFilter,
               !(peripheral.name?.localizedCaseInsensitiveContains(nameFilter) ?? false) {
                continue
            }
            guard seen.insert(peripheral.id).inserted else { continue }
            let services = peripheral.advertisedServices.isEmpty
                ? "-" : peripheral.advertisedServices.joined(separator: ",")
            let name = peripheral.name ?? "(no name)"
            print("\(name)  id=\(peripheral.id)  rssi=\(peripheral.rssi)  services=[\(services)]  connectable=\(peripheral.isConnectable)")
        }
        central.disconnect()
    }

    // MARK: explore

    static func explore(match: PeripheralMatch, timeout: Double, json: Bool) async throws {
        let central = BLECentral()
        try await central.connect(matching: match, timeout: timeout)
        let services = try await central.inventory(readValues: true)
        central.disconnect()

        if json {
            print(try ExploreReport(services: services).jsonString())
            return
        }
        for service in services {
            let sname = service.knownName.map { " (\($0))" } ?? ""
            print("service \(service.uuid)\(sname)")
            for ch in service.characteristics {
                let cname = ch.knownName.map { " (\($0))" } ?? ""
                var line = "  char \(ch.uuid)\(cname)  [\(ch.properties.shortDescription)]"
                if let value = ch.value, !value.isEmpty {
                    line += "  = \(hexString(value))  \(asciiString(value))"
                }
                print(line)
            }
        }
    }

    // MARK: raw

    static func raw(match: PeripheralMatch, timeout: Double, csv: Bool, out: String?, chars: [String]?) async throws {
        let central = BLECentral()
        try await central.connect(matching: match, timeout: timeout)

        let header = csv ? "t_mono_s,t_wall_iso,char_uuid,len,hex" : nil
        let writer = try out.map { try CaptureWriter(path: $0, header: header) }
        if writer == nil, let header { print(header) }

        let source = installInterruptHandler { Task { @MainActor in central.finishActiveStreams() } }
        defer { source.cancel() }

        let stream = central.notifications()
        try await central.subscribe(characteristics: chars)
        print("subscribed — Ctrl-C to stop")

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var count = 0
        for await note in stream {
            count += 1
            let line: String
            if csv {
                line = "\(String(format: "%.3f", note.monotonicSeconds)),\(iso.string(from: note.wallClock)),\(note.characteristicUUID),\(note.data.count),\(hexString(note.data))"
            } else {
                line = "\(String(format: "%8.3f", note.monotonicSeconds))  \(note.characteristicUUID)  \(String(format: "%3d", note.data.count))  \(hexString(note.data))"
            }
            if let writer { writer.write(line) } else { print(line) }
        }
        writer?.close()
        central.disconnect()
        print("captured \(count) frames" + (out.map { " → \($0)" } ?? ""))
    }

    // MARK: decode

    static func decode(match: PeripheralMatch, timeout: Double, service: String) async throws {
        let central = BLECentral()
        try await central.connect(matching: match, timeout: timeout)
        let services = try await central.inventory(readValues: false)
        let hasPLXS = services.contains { $0.uuid.localizedCaseInsensitiveContains("1822") }

        let parser: MeasurementParser
        switch service.lowercased() {
        case "plxs": parser = PLXSParser()
        case "proprietary": parser = ProprietaryPM100Parser()
        default: parser = hasPLXS ? PLXSParser() : ProprietaryPM100Parser()
        }

        let source = installInterruptHandler { Task { @MainActor in central.finishActiveStreams() } }
        defer { source.cancel() }

        let targets = parser.characteristicUUIDs.map { $0.uuidString }
        let stream = central.measurements(using: parser)
        try await central.subscribe(characteristics: targets.isEmpty ? nil : targets)
        print("decoding with \(type(of: parser)) — Ctrl-C to stop")

        for await m in stream {
            let spo2 = m.spo2.map { String(format: "%.0f%%", $0) } ?? "--"
            let pr = m.pulseRate.map { String(format: "%.0f bpm", $0) } ?? "--"
            print("SpO2 \(spo2)  PR \(pr)  finger=\(m.fingerDetected)  q=\(m.quality.rawValue)")
        }
        central.disconnect()
    }
}

/// Minimal Encodable view of a service tree for `explore --json`.
private struct ExploreReport: Encodable {
    struct Char: Encodable {
        let uuid: String
        let name: String?
        let properties: String
        let valueHex: String?
    }
    struct Svc: Encodable {
        let uuid: String
        let name: String?
        let characteristics: [Char]
    }
    let services: [Svc]

    init(services serviceInfos: [ServiceInfo]) {
        services = serviceInfos.map { service in
            Svc(
                uuid: service.uuid,
                name: service.knownName,
                characteristics: service.characteristics.map { ch in
                    Char(
                        uuid: ch.uuid,
                        name: ch.knownName,
                        properties: ch.properties.shortDescription,
                        valueHex: ch.value.flatMap { $0.isEmpty ? nil : hexString($0) }
                    )
                }
            )
        }
    }

    func jsonString() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}
