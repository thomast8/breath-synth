import Foundation

/// Shared audio constants for the engine.
public enum AudioConstants {
    /// The single working sample rate. All assets are resampled to this on load,
    /// and all assembly + playback happen at this rate.
    public static let workingSampleRate: Double = 44_100
}

/// A breath direction.
public enum BreathType: String, Codable, Sendable, CaseIterable {
    case inhale
    case exhale
}

/// A breath style. Open-ended on purpose: the asset palette (manifest) defines
/// which styles actually exist (e.g. "neutral", "calm").
public typealias BreathStyle = String

/// Subtle per-render variation so repeated breaths don't sound mechanically identical.
/// Values are *ranges* (±). Concrete deltas are drawn from a seeded RNG so a given
/// seed always produces the same render.
public struct VariationOptions: Sendable, Equatable {
    /// Master switch.
    public var enabled: Bool
    /// Gain wobble, ± dB.
    public var gainDb: Double
    /// Playback-rate wobble, ± percent (applied to the loop texture only, so the
    /// overall breath duration stays exact).
    public var playbackRatePct: Double

    public init(enabled: Bool = true, gainDb: Double = 2.0, playbackRatePct: Double = 2.0) {
        self.enabled = enabled
        self.gainDb = gainDb
        self.playbackRatePct = playbackRatePct
    }

    public static let `default` = VariationOptions()
    public static let none = VariationOptions(enabled: false, gainDb: 0, playbackRatePct: 0)
}

/// A request to render one breath of an exact duration.
public struct BreathSpec: Sendable, Equatable {
    public var type: BreathType
    /// Target duration in seconds (clamped to [minDurationSec, maxDurationSec] at render time).
    public var durationSec: Double
    public var style: BreathStyle
    /// Optional explicit seed. When nil, a stable seed is derived from the spec so
    /// renders are reproducible and cacheable.
    public var seed: UInt64?
    public var variation: VariationOptions
    /// Master gain scalar applied to the whole breath (default 1.0).
    public var gain: Double

    public static let minDurationSec: Double = 1.0
    public static let maxDurationSec: Double = 30.0

    public init(
        type: BreathType,
        durationSec: Double,
        style: BreathStyle = "neutral",
        seed: UInt64? = nil,
        variation: VariationOptions = .default,
        gain: Double = 1.0
    ) {
        self.type = type
        self.durationSec = durationSec
        self.style = style
        self.seed = seed
        self.variation = variation
        self.gain = gain
    }

    /// Duration clamped to the supported range.
    public var clampedDurationSec: Double {
        min(max(durationSec, Self.minDurationSec), Self.maxDurationSec)
    }
}

/// A full breathing cycle: inhale → hold → exhale → hold, optionally looping.
public struct CycleSpec: Sendable, Equatable {
    public var inhale: BreathSpec
    public var holdAfterInhaleSec: Double
    public var exhale: BreathSpec
    public var holdAfterExhaleSec: Double
    /// Loop forever when true (ignores `cycles`).
    public var loop: Bool
    /// Number of cycles to play when not looping forever.
    public var cycles: Int

    public init(
        inhale: BreathSpec,
        holdAfterInhaleSec: Double = 0,
        exhale: BreathSpec,
        holdAfterExhaleSec: Double = 0,
        loop: Bool = true,
        cycles: Int = 1
    ) {
        self.inhale = inhale
        self.holdAfterInhaleSec = holdAfterInhaleSec
        self.exhale = exhale
        self.holdAfterExhaleSec = holdAfterExhaleSec
        self.loop = loop
        self.cycles = cycles
    }
}

/// Errors surfaced by the engine.
public enum BreathError: Error, CustomStringConvertible, Equatable {
    case missingStyle(BreathStyle, BreathType)
    case emptyRole(BreathStyle, BreathType, BreathRole)
    case assetNotFound(String)
    case audioFormatUnavailable
    case unsupportedManifestVersion(found: Int, supported: Int)
    case ioFailure(String)

    public var description: String {
        switch self {
        case let .missingStyle(style, type):
            return "No assets for style '\(style)' (\(type.rawValue)). Check the manifest in your assets directory."
        case let .emptyRole(style, type, role):
            return "Style '\(style)' (\(type.rawValue)) is missing the '\(role.rawValue)' clip."
        case let .assetNotFound(path):
            return "Asset file not found: \(path)"
        case .audioFormatUnavailable:
            return "Could not create the working audio format."
        case let .unsupportedManifestVersion(found, supported):
            return "Manifest version \(found) is newer than supported (\(supported)). Update breath-synth or use a matching manifest."
        case let .ioFailure(message):
            return "Audio I/O failure: \(message)"
        }
    }
}
