import ArgumentParser
import BreathBank
import BreathEngine
import Foundation

@main
struct BreathBankTool: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "breath-bank",
        abstract: "Grade enrollment takes and pool them into per-(style, type) fragment banks.",
        subcommands: [Build.self]
    )
}

extension BreathBankTool {
    struct Build: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Build fragment banks from an enrollment folder (captures.json + takes)."
        )

        @Option(name: .long, help: "Enrollment folder containing captures.json and the recorded takes.")
        var captures: String

        @Option(name: .long, help: "Assets dir with gold reference takes (grading templates).")
        var assets: String = "Assets/breaths"

        @Option(name: .long, help: "Output dir for the v2 manifest + fragments/ sidecars + prepared caches.")
        var out: String

        @Flag(name: .long, help: "Disable spectral denoise during source prep (matches an engine run with it off).")
        var noDenoise = false

        func run() throws {
            var settings = AssemblerSettings()
            if noDenoise { settings.enableSpectralDenoise = false }
            let summary = try BankBuilder.build(
                capturesDir: URL(fileURLWithPath: captures),
                assetsDir: URL(fileURLWithPath: assets),
                outDir: URL(fileURLWithPath: out),
                settings: settings
            )
            print(summary.description)
        }
    }
}
