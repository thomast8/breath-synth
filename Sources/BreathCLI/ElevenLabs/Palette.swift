import BreathEngine
import Foundation

/// One asset to generate: its role, prompt, duration, and loop flag.
struct AssetGenSpec {
    let style: String
    let type: BreathType
    let role: BreathRole
    let prompt: String
    let durationSeconds: Double
    let loop: Bool
    let index: Int

    var filename: String {
        "\(style)_\(type.rawValue)_\(role.rawValue)_\(index).wav"
    }
}

/// The default breath palette to generate per style. Prompts are kept short (billing
/// is per ~1000 chars) and `prompt_influence` is set fairly high at call time for
/// predictable, repeatable results.
enum Palette {
    static func specs(for styles: [String]) -> [AssetGenSpec] {
        var specs: [AssetGenSpec] = []
        for style in styles {
            for type in BreathType.allCases {
                specs.append(contentsOf: roleSpecs(style: style, type: type))
            }
        }
        return specs
    }

    private static func roleSpecs(style: String, type: BreathType) -> [AssetGenSpec] {
        let mood = moodPhrase(style)
        let direction = type == .inhale ? "inhale, breath in" : "exhale, breath out"
        let base = "A \(mood) human \(direction), close mic, intimate, no music, no speech"

        return [
            AssetGenSpec(
                style: style, type: type, role: .start,
                prompt: "\(base), the very beginning onset of the breath",
                durationSeconds: 1.0, loop: false, index: 0
            ),
            AssetGenSpec(
                style: style, type: type, role: .loop,
                prompt: "\(base), continuous steady airy sustain, seamless looping texture",
                durationSeconds: 4.0, loop: true, index: 0
            ),
            AssetGenSpec(
                style: style, type: type, role: .end,
                prompt: "\(base), tapering off and settling gently to silence",
                durationSeconds: 1.2, loop: false, index: 0
            ),
            AssetGenSpec(
                style: style, type: type, role: .oneShot,
                prompt: "\(base), a single short complete breath",
                durationSeconds: 1.2, loop: false, index: 0
            ),
        ]
    }

    private static func moodPhrase(_ style: String) -> String {
        switch style {
        case "calm": return "slow, relaxed, meditative, gentle"
        default: return "calm, natural, soft"
        }
    }
}
