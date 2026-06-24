import XCTest
@testable import BluetoothStack

final class SFLOATTests: XCTestCase {
    func testIntegerMantissaZeroExponent() {
        // exponent 0, mantissa 98 → 98.0
        XCTAssertEqual(SFLOAT.decode(0x0062), 98.0)
    }

    func testNegativeExponent() {
        // exponent 0xF (-1), mantissa 0x3D9 (985) → 98.5
        XCTAssertEqual(try XCTUnwrap(SFLOAT.decode(0xF3D9)), 98.5, accuracy: 1e-9)
    }

    func testNegativeMantissa() {
        // exponent 0, mantissa 0xFFF (-1) → -1.0
        XCTAssertEqual(SFLOAT.decode(0x0FFF), -1.0)
    }

    func testNaNReturnsNil() {
        XCTAssertNil(SFLOAT.decode(0x07FF))
    }

    func testNResReturnsNil() {
        XCTAssertNil(SFLOAT.decode(0x0800))
    }

    func testDecodeFromLittleEndianData() {
        let data = Data([0x62, 0x00]) // 0x0062
        XCTAssertEqual(SFLOAT.decode(data, at: 0), 98.0)
    }

    func testDecodeFromDataAtOffset() {
        let data = Data([0xAB, 0x3C, 0x00]) // SFLOAT 0x003C at index 1 → 60.0
        XCTAssertEqual(SFLOAT.decode(data, at: 1), 60.0)
    }

    func testDecodeOutOfBoundsReturnsNil() {
        XCTAssertNil(SFLOAT.decode(Data([0x62]), at: 0))
        XCTAssertNil(SFLOAT.decode(Data([0x62, 0x00]), at: 2))
    }
}
