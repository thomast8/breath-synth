import CoreBluetooth

/// Well-known GATT identifiers relevant to pulse oximetry, plus a name lookup for `explore` output.
///
/// These are computed (not stored `static let`) because `CBUUID` is not `Sendable`; a stored global
/// of a non-Sendable type trips Swift 6's concurrency check. Rebuilding the small `CBUUID`s on access
/// is negligible and keeps the type free of `@preconcurrency` suppressions.
public enum KnownUUIDs {
    // Pulse Oximeter Service (PLXS) and its characteristics.
    public static var pulseOximeterService: CBUUID { CBUUID(string: "1822") }
    public static var plxSpotCheckMeasurement: CBUUID { CBUUID(string: "2A5E") }
    public static var plxContinuousMeasurement: CBUUID { CBUUID(string: "2A5F") }
    public static var plxFeatures: CBUUID { CBUUID(string: "2A60") }

    // Common informational services seen on these devices.
    public static var deviceInformation: CBUUID { CBUUID(string: "180A") }
    public static var batteryService: CBUUID { CBUUID(string: "180F") }
    public static var batteryLevel: CBUUID { CBUUID(string: "2A19") }

    /// Human-readable name for a known UUID, or nil for vendor/proprietary UUIDs.
    public static func name(for uuid: CBUUID) -> String? {
        switch uuid {
        case pulseOximeterService: return "Pulse Oximeter Service"
        case plxSpotCheckMeasurement: return "PLX Spot-Check Measurement"
        case plxContinuousMeasurement: return "PLX Continuous Measurement"
        case plxFeatures: return "PLX Features"
        case deviceInformation: return "Device Information"
        case batteryService: return "Battery Service"
        case batteryLevel: return "Battery Level"
        default: return nil
        }
    }
}
