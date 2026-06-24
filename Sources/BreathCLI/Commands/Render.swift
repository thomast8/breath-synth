import ArgumentParser
import BreathEngine
import Foundation

struct Render: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Render one breath to a WAV file (offline inspection).")

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

    @Option(name: .shortAndLong, help: "Output WAV path.")
    var out: String

    func run() async throws {
        let breathType = try parseBreathType(type)
        let spec = BreathSpec(
            type: breathType,
            durationSec: duration,
            style: style,
            seed: seed,
            variation: variation ? .default : .none
        )
        let url = URL(fileURLWithPath: out)
        let engine = try await loadEngine(
            assetsURL: assetsOpt.assetsURL,
            denoise: denoiseOpt.denoise, oversub: denoiseOpt.oversub, floor: denoiseOpt.floor
        )
        switch await engine.renderMode(for: style) {
        case .counted:
            print("mode: counted [\(style)] count=\(count.map(String.init) ?? "detected")")
            try await engine.renderCountedToWAV(style: style, type: breathType, count: count, seed: seed, url: url)
        case .textured, .oneShot:
            try await engine.renderToWAV(spec, url: url)
        }
        print("wrote \(url.path)")
    }
}
