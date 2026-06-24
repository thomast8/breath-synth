import Foundation

/// How to select a peripheral when scanning to connect.
public enum PeripheralMatch: Sendable, CustomStringConvertible {
    /// Case-insensitive substring of the advertised name.
    case name(String)
    /// Exact CoreBluetooth identifier (per-host UUID, printed by `scan`).
    case id(UUID)

    public var description: String {
        switch self {
        case .name(let s): return "name~=\(s)"
        case .id(let u): return "id=\(u)"
        }
    }
}

/// A peripheral seen while scanning. UUIDs are kept as strings so the value is cleanly `Sendable`
/// (CoreBluetooth's CBUUID/CBPeripheral are not) and can cross the AsyncStream boundary.
public struct DiscoveredPeripheral: Sendable, Equatable {
    public let id: UUID
    public let name: String?
    public let rssi: Int
    public let advertisedServices: [String]
    public let isConnectable: Bool

    public init(id: UUID, name: String?, rssi: Int, advertisedServices: [String], isConnectable: Bool) {
        self.id = id
        self.name = name
        self.rssi = rssi
        self.advertisedServices = advertisedServices
        self.isConnectable = isConnectable
    }
}

/// `Sendable` mirror of `CBCharacteristicProperties` (snapshotted to a raw value at the delegate).
public struct CharacteristicProperties: OptionSet, Sendable {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }

    public static let broadcast = CharacteristicProperties(rawValue: 0x01)
    public static let read = CharacteristicProperties(rawValue: 0x02)
    public static let writeWithoutResponse = CharacteristicProperties(rawValue: 0x04)
    public static let write = CharacteristicProperties(rawValue: 0x08)
    public static let notify = CharacteristicProperties(rawValue: 0x10)
    public static let indicate = CharacteristicProperties(rawValue: 0x20)

    /// Whether this characteristic streams values (notify or indicate).
    public var streams: Bool { contains(.notify) || contains(.indicate) }

    /// Compact `[R,W,N,I]`-style flag string for the `explore` tree.
    public var shortDescription: String {
        var flags: [String] = []
        if contains(.read) { flags.append("R") }
        if contains(.write) { flags.append("W") }
        if contains(.writeWithoutResponse) { flags.append("WNR") }
        if contains(.notify) { flags.append("N") }
        if contains(.indicate) { flags.append("I") }
        return flags.isEmpty ? "-" : flags.joined(separator: ",")
    }
}

/// One characteristic in a discovered service tree.
public struct CharacteristicInfo: Sendable {
    public let uuid: String
    public let knownName: String?
    public let propertiesRaw: UInt
    public let value: Data?
    public let descriptors: [String]

    public var properties: CharacteristicProperties { .init(rawValue: propertiesRaw) }

    public init(uuid: String, knownName: String?, propertiesRaw: UInt, value: Data?, descriptors: [String]) {
        self.uuid = uuid
        self.knownName = knownName
        self.propertiesRaw = propertiesRaw
        self.value = value
        self.descriptors = descriptors
    }
}

/// One service in a discovered service tree.
public struct ServiceInfo: Sendable {
    public let uuid: String
    public let knownName: String?
    public let characteristics: [CharacteristicInfo]

    public init(uuid: String, knownName: String?, characteristics: [CharacteristicInfo]) {
        self.uuid = uuid
        self.knownName = knownName
        self.characteristics = characteristics
    }
}

/// A raw notification payload with both a capture-relative (monotonic) and wall-clock timestamp.
public struct RawNotification: Sendable {
    public let characteristicUUID: String
    public let data: Data
    public let monotonicSeconds: Double
    public let wallClock: Date

    public init(characteristicUUID: String, data: Data, monotonicSeconds: Double, wallClock: Date) {
        self.characteristicUUID = characteristicUUID
        self.data = data
        self.monotonicSeconds = monotonicSeconds
        self.wallClock = wallClock
    }
}
