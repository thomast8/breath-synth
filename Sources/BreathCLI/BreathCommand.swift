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

/// Parse + validate a comma-separated style list. Style names become filename
/// components, so restrict them to a safe character set (no path separators/traversal).
func validatedStyleList(_ raw: String) throws -> [String] {
    let list = raw.commaSeparatedList()
    guard !list.isEmpty else { throw ValidationError("No styles given.") }
    for style in list where style.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) == nil {
        throw ValidationError("Invalid style name '\(style)'. Use letters, digits, '-', and '_' only.")
    }
    return list
}

@main
struct Breath: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "breath",
        abstract: "Procedural breathing synthesiser — assembles exact-duration breaths from an asset palette.",
        subcommands: [
            GenerateAssets.self,
            DevStubAssets.self,
            Play.self,
            Cycle.self,
            Render.self,
        ]
    )
}
