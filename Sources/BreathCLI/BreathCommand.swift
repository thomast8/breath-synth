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

/// Shared option group: spectral-denoise A/B controls (Stage 2). On by default; `--no-denoise`
/// turns it off, and the over-subtraction / floor knobs tune it by ear without a recompile.
struct DenoiseOption: ParsableArguments {
    @Flag(name: .long, inversion: .prefixedNo, help: "Spectral noise-profile subtraction on the breath source.")
    var denoise: Bool = true

    @Option(name: .customLong("denoise-oversub"), help: "Denoise over-subtraction factor (~1.5-2.0; ignored unless --denoise). (default: 1.75)")
    var oversub: Float?

    @Option(name: .customLong("denoise-floor"), help: "Denoise per-bin residual floor (~0.03-0.1; ignored unless --denoise). (default: 0.05)")
    var floor: Float?
}

/// Parse a breath type from a CLI string.
func parseBreathType(_ raw: String) throws -> BreathType {
    guard let type = BreathType(rawValue: raw.lowercased()) else {
        throw ValidationError("type must be 'inhale' or 'exhale' (got '\(raw)')")
    }
    return type
}

@MainActor
func loadEngine(
    assetsURL: URL,
    denoise: Bool = false,
    oversub: Float? = nil,
    floor: Float? = nil
) throws -> BreathEngine {
    let manifest = try BreathManifest.load(from: assetsURL.appendingPathComponent("manifest.json"))
    // Start from the canonical defaults and override only what the caller set, so the defaults
    // live in exactly one place (`AssemblerSettings.init`).
    var settings = AssemblerSettings()
    settings.enableSpectralDenoise = denoise
    if let oversub { settings.denoiseOverSubtraction = oversub }
    if let floor { settings.denoiseFloorGain = floor }
    return try BreathEngine(config: .init(assetsDirectory: assetsURL, manifest: manifest, settings: settings))
}

@main
struct Breath: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "breath",
        abstract: "Asset-driven breathing synthesiser for exact-duration breaths.",
        subcommands: [
            Play.self,
            Cycle.self,
            SequenceCommand.self,
            Render.self,
        ]
    )
}
