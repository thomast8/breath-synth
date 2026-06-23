import ArgumentParser
import BreathEngine
import Foundation

struct Play: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Render and play one breath.")

    @OptionGroup var sourceOpt: SourceOption
    @OptionGroup var assetsOpt: AssetsOption

    @Option(help: "inhale or exhale.")
    var type: String = "inhale"

    @Option(help: "Duration in seconds (1-30).")
    var duration: Double = 4

    @Option(help: "Breath style.")
    var style: String = "neutral"

    @Option(help: "Optional fixed seed for reproducible variation.")
    var seed: UInt64?

    @Flag(name: .long, inversion: .prefixedNo, help: "Subtle per-render variation.")
    var variation: Bool = true

    func run() async throws {
        let breathType = try parseBreathType(type)
        let spec = BreathSpec(
            type: breathType,
            durationSec: duration,
            style: style,
            seed: seed,
            variation: variation ? .default : .none
        )
        let engine = try await loadEngine(
            source: sourceOpt.source,
            generator: sourceOpt.generator,
            assembly: sourceOpt.assembly,
            assetsURL: assetsOpt.assetsURL
        )
        let sourceName = sourceOpt.source == .procedural
            ? "\(sourceOpt.source.rawValue)/\(sourceOpt.generator.rawValue)"
            : sourceOpt.source.rawValue
        print("playing \(sourceName) \(breathType.rawValue) \(duration)s [\(style)] ...")
        try await engine.play(spec)
        await engine.stop()
    }
}
