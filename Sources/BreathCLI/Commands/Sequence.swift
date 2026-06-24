import ArgumentParser
import BreathEngine
import Foundation

struct SequenceCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sequence",
        abstract: "Fill a total duration with a whole number of breath cycles.",
        discussion: """
        Lays inhale/hold/exhale/hold cycles end to end to fill --total. Breath durations \
        are kept exact, so the total flexes to the nearest whole-cycle length. By default a \
        pattern that doesn't tile the total evenly fails and proposes the nearest totals; \
        pass --closest to render the nearest one instead.
        """
    )

    @OptionGroup var assetsOpt: AssetsOption

    @OptionGroup var denoiseOpt: DenoiseOption

    @Option(help: "Total target length (s).")
    var total: Double

    @Option(help: "Inhale duration (s, 1-30).")
    var inhale: Double = 4

    @Option(help: "Exhale duration (s, 1-30).")
    var exhale: Double = 6

    @Option(name: .customLong("hold-in"), help: "Hold after inhale (s).")
    var holdIn: Double = 0

    @Option(name: .customLong("hold-out"), help: "Hold after exhale (s).")
    var holdOut: Double = 0

    @Option(help: "Breath style.")
    var style: String = "calm"

    @Option(help: "Optional fixed seed; pins the whole sequence for reproducible variation.")
    var seed: UInt64?

    @Flag(name: .long, help: "Render the nearest whole-cycle total instead of failing when the pattern doesn't tile --total evenly.")
    var closest: Bool = false

    @Flag(name: .long, help: "Loop the whole sequence on playback (Ctrl-C to stop).")
    var loop: Bool = false

    @Option(name: .shortAndLong, help: "Output WAV path. If omitted, the sequence is played.")
    var out: String?

    func run() async throws {
        let pattern = BreathPattern(
            inhaleSec: inhale,
            holdInSec: holdIn,
            exhaleSec: exhale,
            holdOutSec: holdOut,
            style: style,
            seed: seed
        )

        let plan: SequencePlan
        do {
            plan = try SequencePlanner.plan(total: total, pattern: pattern, mode: closest ? .closest : .strict)
        } catch let error as SequencePlanError {
            FileHandle.standardError.write(Data("error: \(error.description)\n".utf8))
            throw ExitCode.failure
        }

        let fit = plan.isExact ? "exact" : "\(BreathFormat.signedSec(plan.deltaSec))s from request"
        let summary = "\(BreathFormat.sec(plan.actualTotalSec))s (\(plan.cycles) cycles, \(fit))"

        let engine = try await loadEngine(
            assetsURL: assetsOpt.assetsURL,
            denoise: denoiseOpt.denoise, oversub: denoiseOpt.oversub, floor: denoiseOpt.floor
        )

        if let out {
            let url = URL(fileURLWithPath: out)
            print("rendering \(summary) ...")
            try await engine.renderSequenceToWAV(plan, url: url)
            print("wrote \(url.path)")
        } else if loop {
            print("looping \(summary) - Ctrl-C to stop")
            try await engine.playSequence(plan, loop: true)
            while true {
                try await Task.sleep(nanoseconds: 60 * 1_000_000_000)
            }
        } else {
            print("playing \(summary) ...")
            try await engine.playSequence(plan)
            await engine.stop()
        }
    }
}
