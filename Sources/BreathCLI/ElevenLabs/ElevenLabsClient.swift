import Foundation

/// Minimal client for the ElevenLabs Sound Effects API.
/// Docs: POST https://api.elevenlabs.io/v1/sound-generation
struct ElevenLabsClient {
    let apiKey: String
    /// e.g. "pcm_44100" (raw 16-bit signed LE PCM). Falls back to lower rates on
    /// non-Pro tiers; the manifest records whatever rate we actually request.
    let outputFormat: String

    struct Request: Encodable {
        let text: String
        let model_id: String
        let duration_seconds: Double?
        let prompt_influence: Double
        let loop: Bool
    }

    enum ClientError: Error, CustomStringConvertible {
        case badResponse
        case http(Int, String)

        var description: String {
            switch self {
            case .badResponse:
                return "Unexpected response from ElevenLabs."
            case let .http(code, body):
                return "ElevenLabs HTTP \(code): \(body)"
            }
        }
    }

    /// Generate one sound effect, returning the raw PCM bytes.
    func generate(
        text: String,
        durationSeconds: Double?,
        loop: Bool,
        promptInfluence: Double = 0.5,
        modelID: String = "eleven_text_to_sound_v2"
    ) async throws -> Data {
        var components = URLComponents(string: "https://api.elevenlabs.io/v1/sound-generation")!
        components.queryItems = [URLQueryItem(name: "output_format", value: outputFormat)]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Request(
            text: text,
            model_id: modelID,
            duration_seconds: durationSeconds,
            prompt_influence: promptInfluence,
            loop: loop
        ))

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ClientError.badResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<non-text body>"
            throw ClientError.http(http.statusCode, body)
        }
        return data
    }

    /// The sample rate implied by `outputFormat` (e.g. "pcm_44100" → 44100).
    var impliedSampleRate: Int {
        if let range = outputFormat.range(of: "pcm_"), let value = Int(outputFormat[range.upperBound...]) {
            return value
        }
        return 44_100
    }
}
