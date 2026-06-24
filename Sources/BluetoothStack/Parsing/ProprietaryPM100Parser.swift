import CoreBluetooth
import Foundation

/// Decoder for the Medisana PM100 ("connect") proprietary BLE protocol.
///
/// STUB — the PM100 is not known to implement the standard PLXS service, so its frame layout must
/// be reverse-engineered from real captures. Run the runbook in the README (`breath sensor raw
/// --csv`), correlate the hex columns to on-display SpO2 / PR / finger-out, then fill in
/// `serviceUUID`, `characteristicUUIDs`, and the byte offsets below and lock it with a fixture test
/// in `BluetoothStackTests`. Until then `parse` returns `nil`.
public struct ProprietaryPM100Parser: MeasurementParser {
    public init() {}

    // TODO(reverse-engineer): set to the vendor service/characteristic UUIDs from `breath sensor explore`.
    public var serviceUUID: CBUUID { CBUUID(string: "0000") }
    public var characteristicUUIDs: [CBUUID] { [] }

    public func parse(characteristic: CBUUID, value: Data) -> PulseOxMeasurement? {
        // TODO(reverse-engineer): decode the captured frame layout here.
        //
        // Common cheap-oximeter shape to look for in `capture.csv`:
        //   - a fixed sync/header byte (often high-bit-set per byte, or a literal 0xAA/0x55 lead);
        //   - short ~5-byte frames at high rate carrying [sync][pleth][signal][spo2][pr];
        //   - SpO2 0x7F (127) and PR 0xFF (255) as the "no reading / finger out" sentinels.
        //
        // Return PulseOxMeasurement(spo2:pulseRate:fingerDetected:quality:raw:) once decoded.
        nil
    }
}
