import ArgumentParser
import BreathEngine
import Foundation

struct GenerateAssets: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "generate-assets",
        abstract: "Generate the breath palette via ElevenLabs and write manifest.json. Requires ELEVENLABS_API_KEY."
    )

    @OptionGroup var assetsOpt: AssetsOption

    @Option(help: "Comma-separated styles to generate (e.g. neutral,calm).")
    var styles: String = "neutral"

    @Option(help: "ElevenLabs output format (also sets the sample rate, e.g. pcm_44100).")
    var outputFormat: String = "pcm_44100"

    @Flag(help: "Regenerate even if the asset file already exists.")
    var force: Bool = false

    func run() async throws {
        guard let apiKey = ProcessInfo.processInfo.environment["ELEVENLABS_API_KEY"], !apiKey.isEmpty else {
            throw ValidationError("ELEVENLABS_API_KEY is not set. Export it before running generate-assets.")
        }
        let styleList = try validatedStyleList(styles)

        let dir = assetsOpt.assetsURL
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let client = ElevenLabsClient(apiKey: apiKey, outputFormat: outputFormat)
        let sampleRate = client.impliedSampleRate
        let specs = Palette.specs(for: styleList)

        var builder = ManifestBuilder()
        for spec in specs {
            let url = dir.appendingPathComponent(spec.filename)
            if FileManager.default.fileExists(atPath: url.path), !force {
                print("skip  \(spec.filename) (exists)")
            } else {
                print("gen   \(spec.filename) …")
                let pcm = try await client.generate(
                    text: spec.prompt,
                    durationSeconds: spec.durationSeconds,
                    loop: spec.loop
                )
                let samples = postProcess(PCM.int16ToFloat(pcm), role: spec.role, sampleRate: sampleRate)
                try PCM.writeWAV(samples: samples, sampleRate: sampleRate, to: url)
            }
            let asset = BreathAsset(
                file: spec.filename,
                durationSec: fileDuration(url, sampleRate: sampleRate),
                sampleRate: Double(sampleRate),
                channels: 1
            )
            builder.add(asset, style: spec.style, type: spec.type, role: spec.role)
        }

        let manifestURL = dir.appendingPathComponent("manifest.json")
        try builder.manifest().write(to: manifestURL)
        print("wrote \(manifestURL.path)")
    }

    private func postProcess(_ samples: [Float], role: BreathRole, sampleRate: Int) -> [Float] {
        switch role {
        case .loop:
            // Keep the loop intact for seamlessness; just normalize.
            return AudioPostProcess.normalize(samples, targetDb: -1)
        case .start, .oneShot:
            var s = AudioPostProcess.normalize(AudioPostProcess.trimSilence(samples), targetDb: -1)
            AudioPostProcess.fadeIn(&s, frames: sampleRate / 100) // 10ms
            if role == .oneShot { AudioPostProcess.fadeOut(&s, frames: sampleRate / 20) } // 50ms
            return s
        case .end:
            var s = AudioPostProcess.normalize(AudioPostProcess.trimSilence(samples), targetDb: -1)
            AudioPostProcess.fadeOut(&s, frames: sampleRate * 6 / 100) // 60ms
            return s
        }
    }

    private func fileDuration(_ url: URL, sampleRate: Int) -> Double {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? Int) ?? 0
        guard size > 44 else { return 0 }
        return Double((size - 44) / 2) / Double(sampleRate)
    }
}
