import CoreBluetooth
import Foundation

/// Decodes raw GATT characteristic payloads into `PulseOxMeasurement`s.
///
/// Implementations are pure (`Data` in, value out) so they can be unit-tested against captured
/// frames with no CoreBluetooth or hardware. `parse` returns `nil` when a payload carries no usable
/// measurement (e.g. a pleth-only frame, or a not-yet-decoded proprietary format).
public protocol MeasurementParser: Sendable {
    /// GATT service this parser handles, used for auto-selection against discovered services.
    var serviceUUID: CBUUID { get }
    /// Characteristics this parser knows how to decode (subscribe targets).
    var characteristicUUIDs: [CBUUID] { get }
    func parse(characteristic: CBUUID, value: Data) -> PulseOxMeasurement?
}
