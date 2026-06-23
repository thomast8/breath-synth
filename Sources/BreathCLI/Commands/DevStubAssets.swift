import ArgumentParser
import BreathEngine
import Foundation

/// Generates synthetic noise-based breath assets so the whole render/play/cycle
/// pipeline can be exercised offline, without ElevenLabs or an API key. These are
/// placeholder textures for development only; real assets come from `generate-assets`.
struct DevStubAssets: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dev-stub-assets",
        abstract: "Generate synthetic (noise) breath assets for offline pipeline testing. Not for production."
    )

    @OptionGroup var assetsOpt: AssetsOption

    @Option(help: "Comma-separated styles to generate.")
    var styles: String = "neutral"

    func run() throws {
        let sampleRate = Int(AudioConstants.workingSampleRate)
        let dir = assetsOpt.assetsURL
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let styleList = try validatedStyleList(styles)
        let roles: [(role: BreathRole, durationSec: Double)] = [
            (.start, 1.0), (.loop, 4.0), (.end, 1.2), (.oneShot, 1.2),
        ]

        var builder = ManifestBuilder()
        var seed: UInt64 = 1
        for style in styleList {
            for type in BreathType.allCases {
                for entry in roles {
                    var rng = SeededRNG(seed: seed)
                    seed += 1
                    let samples = synthesize(
                        type: type,
                        role: entry.role,
                        durationSec: entry.durationSec,
                        sampleRate: sampleRate,
                        rng: &rng
                    )
                    let name = "\(style)_\(type.rawValue)_\(entry.role.rawValue)_0.wav"
                    try PCM.writeWAV(samples: samples, sampleRate: sampleRate, to: dir.appendingPathComponent(name))
                    let asset = BreathAsset(
                        file: name,
                        durationSec: entry.durationSec,
                        sampleRate: Double(sampleRate),
                        channels: 1
                    )
                    builder.add(asset, style: style, type: type, role: entry.role)
                    print("stub  \(name)")
                }
            }
        }

        let manifestURL = dir.appendingPathComponent("manifest.json")
        try builder.manifest().write(to: manifestURL)
        print("wrote \(manifestURL.path)")
    }

    /// White noise → one-pole lowpass (exhale warmer than inhale) → normalize → role shaping.
    private func synthesize(
        type: BreathType,
        role: BreathRole,
        durationSec: Double,
        sampleRate: Int,
        rng: inout SeededRNG
    ) -> [Float] {
        let n = max(1, Int(durationSec * Double(sampleRate)))
        var s = [Float](repeating: 0, count: n)
        for i in 0..<n {
            s[i] = Float.random(in: -1...1, using: &rng)
        }
        let a: Float = type == .inhale ? 0.25 : 0.08
        var y: Float = 0
        for i in 0..<n {
            y += a * (s[i] - y)
            s[i] = y
        }
        s = AudioPostProcess.normalize(s, targetDb: -3)
        switch role {
        case .start:
            AudioPostProcess.fadeIn(&s, frames: sampleRate / 20)   // 50ms
        case .end:
            AudioPostProcess.fadeOut(&s, frames: sampleRate / 5)   // 200ms
        case .oneShot:
            AudioPostProcess.fadeIn(&s, frames: sampleRate / 20)
            AudioPostProcess.fadeOut(&s, frames: sampleRate / 10)
        case .loop:
            break
        }
        return s
    }
}
