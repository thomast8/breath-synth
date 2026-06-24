import Foundation

/// IEEE-11073 16-bit SFLOAT, used by GATT medical characteristics (e.g. PLX measurements).
///
/// Layout (16-bit word): top 4 bits = signed exponent, bottom 12 bits = signed mantissa, both
/// two's complement. `value = mantissa * 10^exponent`. Reserved patterns (NaN / NRes / ±Inf)
/// decode to `nil`.
public enum SFLOAT {
    public static func decode(_ raw: UInt16) -> Double? {
        let mantissaBits = Int(raw & 0x0FFF)
        // Special values defined over the 12-bit mantissa field.
        switch mantissaBits {
        case 0x07FF, // NaN
             0x0800, // NRes (not at this resolution)
             0x0801, // reserved for future use
             0x07FE, // +Inf
             0x0802: // -Inf
            return nil
        default:
            break
        }
        var mantissa = mantissaBits
        if mantissa >= 0x0800 { mantissa -= 0x1000 } // sign-extend 12-bit
        var exponent = Int((raw >> 12) & 0x000F)
        if exponent >= 0x0008 { exponent -= 0x0010 } // sign-extend 4-bit
        return Double(mantissa) * pow(10.0, Double(exponent))
    }

    /// Decode two little-endian bytes starting at `index` (0-based) of `data` as an SFLOAT.
    public static func decode(_ data: Data, at index: Int) -> Double? {
        guard index >= 0, index + 1 < data.count else { return nil }
        let lo = UInt16(data[data.startIndex + index])
        let hi = UInt16(data[data.startIndex + index + 1])
        return decode(lo | (hi << 8))
    }
}
