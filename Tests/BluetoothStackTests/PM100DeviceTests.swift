import XCTest
@testable import BluetoothStack

/// Regression fixtures captured from a real Medisana PM100 ("e-Oximeter", ChoiceMMed MD300C208S),
/// which implements the standard PLX Continuous Measurement (0x2A5F) characteristic. Frames taken
/// verbatim from a live session log. Locks in the finger-on decode and the finger-out suppression.
final class PM100DeviceTests: XCTestCase {
    private let parser = PLXSParser()

    private func frame(_ hex: String) -> Data {
        Data(hex.split(separator: " ").map { UInt8($0, radix: 16)! })
    }

    private func parse(_ hex: String) -> PulseOxMeasurement? {
        parser.parse(characteristic: KnownUUIDs.plxContinuousMeasurement, value: frame(hex))
    }

    func testRestingFrameDecodesSpO2AndPulse() {
        // flags=0x1C (MeasStatus + DevStatus + PAI present); SpO2 0x0062=98; PR 0x0040=64.
        let m = parse("1C 62 00 40 00 20 00 20 00 00 22 F0")
        XCTAssertEqual(m?.spo2, 98)
        XCTAssertEqual(m?.pulseRate, 64)
        XCTAssertEqual(m?.fingerDetected, true)
    }

    func testActivePulseFrame() {
        // SpO2 0x0060=96; PR 0x0049=73.
        let m = parse("1C 60 00 49 00 20 00 24 00 00 23 F0")
        XCTAssertEqual(m?.spo2, 96)
        XCTAssertEqual(m?.pulseRate, 73)
        XCTAssertEqual(m?.fingerDetected, true)
    }

    func testFingerOutSuppressesZeroReading() {
        // Steady finger-out: SpO2/PR bytes 0x0000 (device's no-reading sentinel), DevStatus bit 11.
        let m = parse("1C 00 00 00 00 00 00 20 08 00 00 F0")
        XCTAssertEqual(m?.fingerDetected, false)
        XCTAssertEqual(m?.quality, .noFinger)
        XCTAssertNil(m?.spo2, "must not report 0% SpO2 when the finger is out")
        XCTAssertNil(m?.pulseRate)
    }

    func testFingerOutSuppressesStaleReading() {
        // Transitional: device still carries a stale SpO2 (0x0061=97) but DevStatus bit 11 is set.
        let m = parse("1C 61 00 00 00 00 00 20 08 00 00 F0")
        XCTAssertEqual(m?.fingerDetected, false)
        XCTAssertNil(m?.spo2, "stale SpO2 must be suppressed once the sensor reports unconnected")
        XCTAssertNil(m?.pulseRate)
    }
}
