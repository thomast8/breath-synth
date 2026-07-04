import Foundation

/// Constant-time string equality for secret comparisons (invite codes, admin bearer tokens) — a
/// plain `==` short-circuits on the first differing byte, letting a network attacker recover the
/// secret one character at a time from response-time measurements.
enum ConstantTimeCompare {
    static func equals(_ a: String, _ b: String) -> Bool {
        let aBytes = Array(a.utf8)
        let bBytes = Array(b.utf8)
        // Still walk a length-sized loop on mismatch (not an immediate `return false`) so a
        // length difference isn't a fast additional timing signal on top of the byte comparison.
        let length = max(aBytes.count, bBytes.count)
        var diff: UInt8 = UInt8(aBytes.count == bBytes.count ? 0 : 1)
        for i in 0..<length {
            let byteA = i < aBytes.count ? aBytes[i] : 0
            let byteB = i < bBytes.count ? bBytes[i] : 0
            diff |= byteA ^ byteB
        }
        return diff == 0
    }
}
