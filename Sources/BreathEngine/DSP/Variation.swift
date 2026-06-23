import Foundation

/// Deterministic PRNG (splitmix64). Conforms to `RandomNumberGenerator` so it can
/// drive `Double.random(in:using:)` etc. Same seed → same sequence, always.
public struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64

    public init(seed: UInt64) {
        self.state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Concrete variation values drawn for a single render.
public struct VariationDeltas: Sendable, Equatable {
    /// Linear gain multiplier.
    public var gainScalar: Double
    /// Resample factor applied to the loop texture.
    public var playbackRate: Double

    public static let identity = VariationDeltas(gainScalar: 1, playbackRate: 1)
}

public enum Variation {
    public static func dbToGain(_ db: Double) -> Double { pow(10, db / 20) }
    public static func gainToDb(_ gain: Double) -> Double { 20 * log10(max(gain, 1e-9)) }

    /// Draw concrete deltas from `options` using `rng`.
    public static func draw(_ options: VariationOptions, rng: inout SeededRNG) -> VariationDeltas {
        guard options.enabled else { return .identity }
        let db = options.gainDb > 0 ? Double.random(in: -options.gainDb...options.gainDb, using: &rng) : 0
        let pct = options.playbackRatePct > 0
            ? Double.random(in: -options.playbackRatePct...options.playbackRatePct, using: &rng)
            : 0
        return VariationDeltas(gainScalar: dbToGain(db), playbackRate: 1 + pct / 100)
    }

    /// FNV-1a 64-bit hash over a string. Stable across runs (unlike `Hasher`).
    static func fnv1a(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }

    /// A stable seed derived from a spec, so a given breath always varies the same way.
    public static func stableSeed(for spec: BreathSpec) -> UInt64 {
        fnv1a(canonicalString(spec))
    }

    /// Canonical, stable serialization of the render-affecting fields of a spec.
    static func canonicalString(_ spec: BreathSpec) -> String {
        let v = spec.variation
        return [
            spec.type.rawValue,
            String(format: "%.4f", spec.clampedDurationSec),
            spec.style,
            String(format: "%.4f", spec.gain),
            v.enabled ? "1" : "0",
            String(format: "%.4f", v.gainDb),
            String(format: "%.4f", v.playbackRatePct),
        ].joined(separator: "|")
    }
}
