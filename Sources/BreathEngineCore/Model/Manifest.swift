import Foundation

/// The role a clip plays in attack → sustain → release assembly.
public enum BreathRole: String, Codable, Sendable, CaseIterable {
    /// The breath onset (attack).
    case start
    /// A seamless, loopable sustain texture.
    case loop
    /// The breath release/decay.
    case end
    /// A short complete breath for sub-threshold durations.
    case oneShot
}

/// One generated/recorded asset file plus its true properties.
public struct BreathAsset: Codable, Sendable, Equatable {
    /// Filename relative to the assets directory.
    public var file: String
    public var durationSec: Double
    public var sampleRate: Double
    public var channels: Int

    public init(file: String, durationSec: Double, sampleRate: Double, channels: Int) {
        self.file = file
        self.durationSec = durationSec
        self.sampleRate = sampleRate
        self.channels = channels
    }
}

/// All clips for one breath direction of one style. Each role is an array so extra
/// variants can be added later to enrich "different sample choice" variation.
public struct RolePalette: Codable, Sendable, Equatable {
    public var start: [BreathAsset]
    public var loop: [BreathAsset]
    public var end: [BreathAsset]
    public var oneShot: [BreathAsset]
    /// Optional filename of this (style, type)'s fragment-bank sidecar (graded sub-take
    /// fragments). A missing JSON key decodes to `nil` → single-take behavior. Mirrors
    /// `BreathManifest.noiseProfile`: the manifest names the file, the engine loads it as data.
    public var fragmentBank: String?

    public init(
        start: [BreathAsset] = [],
        loop: [BreathAsset] = [],
        end: [BreathAsset] = [],
        oneShot: [BreathAsset] = [],
        fragmentBank: String? = nil
    ) {
        self.start = start
        self.loop = loop
        self.end = end
        self.oneShot = oneShot
        self.fragmentBank = fragmentBank
    }
}

/// How a style's source is rendered into an output buffer.
public enum RenderMode: String, Codable, Sendable {
    case textured
    case oneShot
    case counted
}

/// Inhale + exhale palettes for a single style.
public struct StyleManifest: Codable, Sendable, Equatable {
    public var inhale: RolePalette
    public var exhale: RolePalette
    /// Optional render override; a missing JSON key decodes to `nil` (→ `.textured`).
    public var render: RenderMode?

    public init(
        inhale: RolePalette = RolePalette(),
        exhale: RolePalette = RolePalette(),
        render: RenderMode? = nil
    ) {
        self.inhale = inhale
        self.exhale = exhale
        self.render = render
    }

    /// The render mode to use, defaulting to `.textured` when unset.
    public var effectiveRender: RenderMode { render ?? .textured }

    public func palette(for type: BreathType) -> RolePalette {
        type == .inhale ? inhale : exhale
    }
}

/// The on-disk manifest describing the breath palette (one `oneShot` recording per
/// style and type), read by the engine.
public struct BreathManifest: Codable, Sendable, Equatable {
    public var version: Int
    /// Keyed by style name.
    public var styles: [String: StyleManifest]
    /// Optional filename of a room-tone recording used as a denoise profile.
    public var noiseProfile: String?

    /// v2 adds the optional per-(style,type) `RolePalette.fragmentBank` sidecar. v1 manifests
    /// still load (every new field is optional), so the bump is purely additive.
    public static let currentVersion = 2

    public init(
        version: Int = BreathManifest.currentVersion,
        styles: [String: StyleManifest] = [:],
        noiseProfile: String? = nil
    ) {
        self.version = version
        self.styles = styles
        self.noiseProfile = noiseProfile
    }

    public func palette(style: BreathStyle, type: BreathType) -> RolePalette? {
        styles[style]?.palette(for: type)
    }

    // MARK: - Disk I/O

    public static func load(from url: URL) throws -> BreathManifest {
        let data = try Data(contentsOf: url)
        let manifest = try JSONDecoder().decode(BreathManifest.self, from: data)
        guard manifest.version <= currentVersion else {
            throw BreathError.unsupportedManifestVersion(found: manifest.version, supported: currentVersion)
        }
        return manifest
    }

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
