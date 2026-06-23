import ArgumentParser
import BreathEngine
import Foundation

/// Shared option: where breath assets + manifest.json live.
struct AssetsOption: ParsableArguments {
    @Option(name: .long, help: "Directory containing breath assets and manifest.json.")
    var assets: String = "Assets/breaths"

    var assetsURL: URL {
        URL(fileURLWithPath: assets, isDirectory: true)
    }
}

/// Parse a breath type from a CLI string.
func parseBreathType(_ raw: String) throws -> BreathType {
    guard let type = BreathType(rawValue: raw.lowercased()) else {
        throw ValidationError("type must be 'inhale' or 'exhale' (got '\(raw)')")
    }
    return type
}

@MainActor
func loadEngine(assetsURL: URL) throws -> BreathEngine {
    let manifest = try BreathManifest.load(from: assetsURL.appendingPathComponent("manifest.json"))
    return try BreathEngine(config: .init(assetsDirectory: assetsURL, manifest: manifest))
}

@main
struct Breath: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "breath",
        abstract: "Asset-driven breathing synthesiser for exact-duration breaths.",
        subcommands: [
            Play.self,
            Cycle.self,
            Render.self,
        ]
    )
}
