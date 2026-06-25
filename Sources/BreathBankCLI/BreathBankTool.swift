import ArgumentParser
import BreathBank
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

        func run() throws {
            let url = URL(fileURLWithPath: captures).appendingPathComponent("captures.json")
            let session = try CaptureSession.load(from: url)
            print("Loaded \(session.steps.count) steps (room tone: \(session.roomTone ?? "none"))")
            for step in session.steps {
                print("  \(step.slug): \(step.files.count) take(s), role=\(step.role), ref=\(step.reference ?? "—")")
            }
            print("Grading + bank emission land in the next step of PR4.")
        }
    }
}
