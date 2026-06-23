import BreathEngine
import Foundation

/// Accumulates assets into a `BreathManifest`.
struct ManifestBuilder {
    private var styles: [String: StyleManifest] = [:]

    mutating func add(_ asset: BreathAsset, style: String, type: BreathType, role: BreathRole) {
        var styleManifest = styles[style] ?? StyleManifest()
        var palette = styleManifest.palette(for: type)
        switch role {
        case .start: palette.start.append(asset)
        case .loop: palette.loop.append(asset)
        case .end: palette.end.append(asset)
        case .oneShot: palette.oneShot.append(asset)
        }
        if type == .inhale {
            styleManifest.inhale = palette
        } else {
            styleManifest.exhale = palette
        }
        styles[style] = styleManifest
    }

    func manifest() -> BreathManifest {
        BreathManifest(styles: styles)
    }
}

extension String {
    /// Split a comma-separated option value into trimmed, non-empty parts.
    func commaSeparatedList() -> [String] {
        split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
