import ArgumentParser
import BreathEngine
import Foundation

struct Play: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Render and play one breath.")

    @OptionGroup var assetsOpt: AssetsOption

    @OptionGroup var denoiseOpt: DenoiseOption

    @Option(help: "inhale or exhale.")
    var type: String = "inhale"

    @Option(help: "Duration in seconds (1-30).")
    var duration: Double = 4

    @Option(help: "Breath style.")
    var style: String = "calm"

    @Option(help: "Unit count for counted styles (recovery/packing); default = detected.")
    var count: Int?

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
            assetsURL: assetsOpt.assetsURL,
            denoise: denoiseOpt.denoise, oversub: denoiseOpt.oversub, floor: denoiseOpt.floor
        )
        switch await engine.renderMode(for: style) {
        case .counted:
            print("playing counted [\(style)] count=\(count.map(String.init) ?? "detected") ...")
            try await engine.playCounted(style: style, type: breathType, count: count, seed: seed)
        case .textured, .oneShot:
            print("playing \(breathType.rawValue) \(duration)s [\(style)] ...")
            try await engine.play(spec)
        }
        await engine.stop()
    }
}
