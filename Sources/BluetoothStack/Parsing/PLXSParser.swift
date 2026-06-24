import CoreBluetooth
import Foundation

/// Decoder for the standard Bluetooth SIG Pulse Oximeter Service (0x1822):
/// PLX Continuous Measurement (0x2A5F) and PLX Spot-Check Measurement (0x2A5E).
///
/// Both start with a flags byte followed by SpO2 and PR as IEEE-11073 SFLOATs; optional fields
/// follow per the flags. We decode the always-present SpO2/PR and, when present, the Device and
/// Sensor Status field to set finger-detection and quality.
public struct PLXSParser: MeasurementParser {
    public init() {}

    public var serviceUUID: CBUUID { KnownUUIDs.pulseOximeterService }
    public var characteristicUUIDs: [CBUUID] {
        [KnownUUIDs.plxContinuousMeasurement, KnownUUIDs.plxSpotCheckMeasurement]
    }

    public func parse(characteristic: CBUUID, value: Data) -> PulseOxMeasurement? {
        switch characteristic {
        case KnownUUIDs.plxContinuousMeasurement:
            return parseContinuous(value)
        case KnownUUIDs.plxSpotCheckMeasurement:
            return parseSpotCheck(value)
        default:
            return nil
        }
    }

    // 0x2A5F: flags(1) | SpO2 SFLOAT(2) | PR SFLOAT(2) | [optional fast/slow/status fields].
    private func parseContinuous(_ data: Data) -> PulseOxMeasurement? {
        guard data.count >= 5 else { return nil }
        let flags = data[data.startIndex]
        var spo2 = Self.noReadingToNil(SFLOAT.decode(data, at: 1))
        var pr = Self.noReadingToNil(SFLOAT.decode(data, at: 3))

        var offset = 5
        if flags & 0x01 != 0 { offset += 4 } // SpO2PR-Fast (SpO2 + PR SFLOATs)
        if flags & 0x02 != 0 { offset += 4 } // SpO2PR-Slow (SpO2 + PR SFLOATs)
        if flags & 0x04 != 0 { offset += 2 } // Measurement Status (UInt16)

        var finger = spo2 != nil
        var quality: SignalQuality = spo2 == nil ? .searching : .good
        if flags & 0x08 != 0, offset + 2 < data.count { // Device and Sensor Status (24-bit)
            let s0 = UInt32(data[data.startIndex + offset])
            let s1 = UInt32(data[data.startIndex + offset + 1])
            let s2 = UInt32(data[data.startIndex + offset + 2])
            let status = s0 | (s1 << 8) | (s2 << 16)
            (finger, quality) = Self.interpretDeviceStatus(status, spo2: spo2)
        }

        // Finger out: suppress any stale/zero numbers so we never report a bogus 0% SpO2.
        if !finger {
            spo2 = nil
            pr = nil
        }

        return PulseOxMeasurement(
            spo2: spo2,
            pulseRate: pr,
            fingerDetected: finger,
            quality: quality,
            raw: data
        )
    }

    // 0x2A5E: flags(1) | SpO2 SFLOAT(2) | PR SFLOAT(2) | [timestamp | status | ...].
    private func parseSpotCheck(_ data: Data) -> PulseOxMeasurement? {
        guard data.count >= 5 else { return nil }
        let spo2 = Self.noReadingToNil(SFLOAT.decode(data, at: 1))
        let pr = Self.noReadingToNil(SFLOAT.decode(data, at: 3))
        return PulseOxMeasurement(
            spo2: spo2,
            pulseRate: pr,
            fingerDetected: spo2 != nil,
            quality: spo2 == nil ? .searching : .good,
            raw: data
        )
    }

    /// Several oximeters (e.g. the ChoiceMMed MD300C208S that Medisana rebadges as the PM100) signal
    /// "no reading" with a literal `0` rather than the spec's NaN SFLOAT. A SpO2 or pulse rate of 0 is
    /// non-physiological, so treat any value at or below 0 as absent.
    static func noReadingToNil(_ value: Double?) -> Double? {
        guard let value, value > 0 else { return nil }
        return value
    }

    /// Map the PLX Device and Sensor Status bitfield to (fingerDetected, quality).
    static func interpretDeviceStatus(_ status: UInt32, spo2: Double?) -> (Bool, SignalQuality) {
        let poorSignal = status & (1 << 4) != 0
        let lowPerfusion = status & (1 << 5) != 0
        let nonPulsatile = status & (1 << 7) != 0
        let sensorUnconnected = status & (1 << 11) != 0
        if sensorUnconnected || nonPulsatile {
            return (false, .noFinger)
        }
        if lowPerfusion || poorSignal {
            return (spo2 != nil, .lowPerfusion)
        }
        return (spo2 != nil, spo2 != nil ? .good : .searching)
    }
}
