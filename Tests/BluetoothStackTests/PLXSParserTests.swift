import XCTest
@testable import BluetoothStack

final class PLXSParserTests: XCTestCase {
    private let parser = PLXSParser()

    func testContinuousBasicSpO2AndPR() {
        // flags=0x00 | SpO2=98 (0x0062) | PR=60 (0x003C)
        let frame = Data([0x00, 0x62, 0x00, 0x3C, 0x00])
        let m = parser.parse(characteristic: KnownUUIDs.plxContinuousMeasurement, value: frame)
        XCTAssertEqual(m?.spo2, 98)
        XCTAssertEqual(m?.pulseRate, 60)
        XCTAssertEqual(m?.fingerDetected, true)
        XCTAssertEqual(m?.quality, .good)
        XCTAssertEqual(m?.raw, frame)
    }

    func testSpotCheckBasic() {
        let frame = Data([0x00, 0x61, 0x00, 0x49, 0x00]) // SpO2=97, PR=73
        let m = parser.parse(characteristic: KnownUUIDs.plxSpotCheckMeasurement, value: frame)
        XCTAssertEqual(m?.spo2, 97)
        XCTAssertEqual(m?.pulseRate, 73)
    }

    func testTooShortReturnsNil() {
        XCTAssertNil(parser.parse(characteristic: KnownUUIDs.plxContinuousMeasurement, value: Data([0x00, 0x62])))
    }

    func testWrongCharacteristicReturnsNil() {
        let frame = Data([0x00, 0x62, 0x00, 0x3C, 0x00])
        XCTAssertNil(parser.parse(characteristic: KnownUUIDs.batteryLevel, value: frame))
    }

    func testDeviceStatusSensorUnconnectedMeansNoFinger() {
        // flags=0x08 (Device & Sensor Status present) | SpO2 NaN | PR NaN | status 0x000800 (bit 11)
        let frame = Data([0x08, 0xFF, 0x07, 0xFF, 0x07, 0x00, 0x08, 0x00])
        let m = parser.parse(characteristic: KnownUUIDs.plxContinuousMeasurement, value: frame)
        XCTAssertNil(m?.spo2, "0x07FF is the SFLOAT NaN sentinel")
        XCTAssertEqual(m?.fingerDetected, false)
        XCTAssertEqual(m?.quality, .noFinger)
    }

    func testDeviceStatusLowPerfusion() {
        // flags=0x08 | SpO2=95 (0x005F) | PR=70 (0x0046) | status 0x000020 (bit 5 low perfusion)
        let frame = Data([0x08, 0x5F, 0x00, 0x46, 0x00, 0x20, 0x00, 0x00])
        let m = parser.parse(characteristic: KnownUUIDs.plxContinuousMeasurement, value: frame)
        XCTAssertEqual(m?.spo2, 95)
        XCTAssertEqual(m?.fingerDetected, true)
        XCTAssertEqual(m?.quality, .lowPerfusion)
    }

    func testInterpretDeviceStatusDirectly() {
        XCTAssertEqual(PLXSParser.interpretDeviceStatus(0, spo2: 98).1, .good)
        XCTAssertEqual(PLXSParser.interpretDeviceStatus(1 << 11, spo2: 98).0, false)
        XCTAssertEqual(PLXSParser.interpretDeviceStatus(1 << 7, spo2: 98).1, .noFinger)
    }
}
