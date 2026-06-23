import ArgumentParser
import BreathEngine
import Foundation

struct Shootout: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Render the A/B/C procedural generator shootout to WAV files."
    )

    @Option(help: "Breath style.")
    var style: String = "calm"

    @Option(help: "Base seed for reproducible procedural texture.")
    var seed: UInt64 = 42_424

    @Flag(name: .long, inversion: .prefixedNo, help: "Subtle per-render variation.")
    var variation: Bool = false

    @Flag(help: "Play each generated file after rendering.")
    var play: Bool = false

    @Option(name: .shortAndLong, help: "Output directory.")
    var out: String = "/tmp/breath-shootout"

    func run() async throws {
        let outputURL = URL(fileURLWithPath: out, isDirectory: true)
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
        let variationOptions = variation ? VariationOptions.default : .none
        let candidates: [(prefix: String, generator: CLIProceduralGenerator)] = [
            ("A_tract", .tract),
            ("B_klatt", .klatt),
            ("C_granular", .granular),
        ]
        let singles: [(name: String, type: BreathType, duration: Double, seedOffset: UInt64)] = [
            ("inhale_04", .inhale, 4, 1),
            ("exhale_06", .exhale, 6, 2),
            ("inhale_12", .inhale, 12, 3),
        ]

        print("rendering shootout to \(outputURL.path)")
        for candidate in candidates {
            let engine = try await loadEngine(
                source: .procedural,
                generator: candidate.generator,
                assembly: .sustain,
                assetsURL: URL(fileURLWithPath: "Assets/breaths", isDirectory: true)
            )
            for item in singles {
                let spec = BreathSpec(
                    type: item.type,
                    durationSec: item.duration,
                    style: style,
                    seed: seed + item.seedOffset,
                    variation: variationOptions
                )
                let url = outputURL.appendingPathComponent("\(candidate.prefix)_\(item.name).wav")
                try await engine.renderToWAV(spec, url: url)
                print("wrote \(url.path)")
                if play {
                    try await engine.play(spec)
                }
            }

            let cycle = CycleSpec(
                inhale: BreathSpec(
                    type: .inhale,
                    durationSec: 4,
                    style: style,
                    seed: seed + 10,
                    variation: variationOptions
                ),
                holdAfterInhaleSec: 1,
                exhale: BreathSpec(
                    type: .exhale,
                    durationSec: 6,
                    style: style,
                    seed: seed + 11,
                    variation: variationOptions
                ),
                holdAfterExhaleSec: 1,
                loop: false,
                cycles: 1
            )
            let url = outputURL.appendingPathComponent("\(candidate.prefix)_cycle_04_01_06_01.wav")
            try await engine.renderCycleToWAV(cycle, url: url)
            print("wrote \(url.path)")
            if play {
                try await engine.playCycle(cycle)
            }
            await engine.stop()
        }
    }
}
