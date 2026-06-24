import ArgumentParser
import BreathEngine
import Foundation

struct Cycle: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Play a breathing cycle: inhale, hold, exhale, hold.")

    @OptionGroup var assetsOpt: AssetsOption

    @OptionGroup var denoiseOpt: DenoiseOption

    @Option(help: "Inhale duration (s).")
    var inhale: Double = 4

    @Option(name: .customLong("hold-in"), help: "Hold after inhale (s).")
    var holdIn: Double = 0

    @Option(help: "Exhale duration (s).")
    var exhale: Double = 6

    @Option(name: .customLong("hold-out"), help: "Hold after exhale (s).")
    var holdOut: Double = 0

    @Option(help: "Breath style.")
    var style: String = "calm"

    @Flag(name: .long, help: "Loop forever (Ctrl-C to stop).")
    var loop: Bool = false

    @Option(help: "Number of cycles to play when not looping.")
    var cycles: Int = 3

    func run() async throws {
        let cycle = CycleSpec(
            inhale: BreathSpec(type: .inhale, durationSec: inhale, style: style),
            holdAfterInhaleSec: holdIn,
            exhale: BreathSpec(type: .exhale, durationSec: exhale, style: style),
            holdAfterExhaleSec: holdOut,
            loop: loop,
            cycles: cycles
        )
        let engine = try await loadEngine(
            assetsURL: assetsOpt.assetsURL,
            denoise: denoiseOpt.denoise, oversub: denoiseOpt.oversub, floor: denoiseOpt.floor
        )
        let shape = "in \(inhale)s / hold \(holdIn)s / out \(exhale)s / hold \(holdOut)s"
        if loop {
            print("looping cycle (\(shape)) - Ctrl-C to stop")
            try await engine.playCycle(cycle)
            while true {
                try await Task.sleep(nanoseconds: 60 * 1_000_000_000)
            }
        } else {
            print("playing \(cycles) cycles (\(shape)) ...")
            try await engine.playCycle(cycle)
            await engine.stop()
        }
    }
}
