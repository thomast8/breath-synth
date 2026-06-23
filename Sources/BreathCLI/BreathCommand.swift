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

enum CLIBreathSource: String, ExpressibleByArgument {
    case procedural
    case assets
}

enum CLIProceduralGenerator: String, CaseIterable, ExpressibleByArgument {
    case tract
    case klatt
    case granular
    case legacy

    var engineKind: ProceduralGeneratorKind {
        switch self {
        case .tract:
            return .tract
        case .klatt:
            return .klatt
        case .granular:
            return .granular
        case .legacy:
            return .legacy
        }
    }
}

enum CLIAssetAssemblyMode: String, CaseIterable, ExpressibleByArgument {
    case sustain
    case segmented
    case shape

    var engineMode: BreathAssemblyMode {
        switch self {
        case .sustain:
            return .sustainOnly
        case .segmented:
            return .segmented
        case .shape:
            return .recordedShape
        }
    }
}

/// Shared source selection. Procedural is the normal path; assets are opt-in.
struct SourceOption: ParsableArguments {
    @Option(help: "Audio source: procedural or assets.")
    var source: CLIBreathSource = .procedural

    @Option(help: "Procedural generator: tract, klatt, granular, or legacy.")
    var generator: CLIProceduralGenerator = .tract

    @Option(help: "Asset assembly: sustain, segmented, or shape.")
    var assembly: CLIAssetAssemblyMode = .sustain
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

@MainActor
func loadEngine(
    source: CLIBreathSource,
    generator: CLIProceduralGenerator,
    assembly: CLIAssetAssemblyMode,
    assetsURL: URL
) throws -> BreathEngine {
    switch source {
    case .procedural:
        return try BreathEngine(config: BreathEngine.Config(
            source: .procedural(ProceduralBreathConfig(generator: generator.engineKind))
        ))
    case .assets:
        let manifest = try BreathManifest.load(from: assetsURL.appendingPathComponent("manifest.json"))
        var config = BreathEngine.Config(source: .assets(directory: assetsURL, manifest: manifest))
        config.settings.assemblyMode = assembly.engineMode
        return try BreathEngine(config: config)
    }
}

@main
struct Breath: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "breath",
        abstract: "Procedural breathing synthesiser for exact-duration breaths.",
        subcommands: [
            GenerateAssets.self,
            DevStubAssets.self,
            Play.self,
            Cycle.self,
            Render.self,
            Shootout.self,
        ]
    )
}
