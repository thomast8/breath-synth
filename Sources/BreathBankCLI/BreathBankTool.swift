import ArgumentParser
import BreathBank
import BreathEngine
import Foundation

@main
struct BreathBankTool: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "breath-bank",
        abstract: "Grade enrollment takes and pool them into per-(style, type) fragment banks.",
        subcommands: [Build.self, PrepareCaches.self]
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

        @Option(name: .long, help: "Sibling-anomaly robust-z (MAD) cutoff; higher keeps more fragments. Default 3.5.")
        var madK: Double?

        func run() throws {
            var settings = AssemblerSettings()
            if noDenoise { settings.enableSpectralDenoise = false }
            var thresholds = Grader.Thresholds.default
            if let madK { thresholds.madK = madK }
            let summary = try BankBuilder.build(
                capturesDir: URL(fileURLWithPath: captures),
                assetsDir: URL(fileURLWithPath: assets),
                outDir: URL(fileURLWithPath: out),
                settings: settings,
                thresholds: thresholds
            )
            print(summary.description)
        }
    }

    struct PrepareCaches: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "prepare-caches",
            abstract: "Regenerate the gitignored *.prepared.wav caches from committed takes + banks."
        )

        @Option(name: .long, help: "Assets dir with manifest.json, fragments/, and the committed takes.")
        var assets: String = "Assets/breaths"

        @Flag(name: .long, help: "Disable spectral denoise (must match the config the bank was built with).")
        var noDenoise = false

        func run() throws {
            var settings = AssemblerSettings()
            if noDenoise { settings.enableSpectralDenoise = false }
            let written = try BankBuilder.regenerateCaches(assetsDir: URL(fileURLWithPath: assets), settings: settings)
            if written.isEmpty {
                print("No fragment banks declared — nothing to regenerate.")
            } else {
                print("Regenerated \(written.count) prepared cache(s): \(written.joined(separator: ", "))")
            }
        }
    }
}
