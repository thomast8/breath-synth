import Testing
import Foundation
import BreathBank
import BreathEngineCore

/// Round-trip coverage for `WavIO`, the Foundation-only decoder/encoder Linux uses in place of
/// `AudioIO`'s AVFoundation path. On macOS both paths exist, so these tests cross-check them
/// directly against each other — the closest thing to a Linux proof available without leaving
/// this machine (the real proof is `swift test` inside the Linux Docker image, see the plan's
/// Phase 1.5).
struct WavIOTests {
    private let sr = 44_100.0

    private func tempURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-\(name)")
    }

    private func toneSamples(_ sec: Double, freqHz: Double = 440) -> [Float] {
        let n = Int(sec * sr)
        return (0..<n).map { i in Float(0.4 * sin(2 * Double.pi * freqHz * Double(i) / sr)) }
    }

    @Test
    func testWavIOWriteThenWavIODecodeRoundTripsExactly() throws {
        let url = tempURL("wavio-roundtrip.wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let original = toneSamples(0.5)

        try WavIO.writeMonoWAV(original, sampleRate: sr, to: url)
        let decoded = try WavIO.decodeMono(url: url, targetRate: sr)

        #expect(decoded.count == original.count)
        // 32-bit float PCM is lossless — this must be bit-exact, not merely close.
        for i in 0..<original.count { #expect(decoded[i] == original[i]) }
    }



    @Test
    func testAudioIOWriteIsReadableByWavIODecode() throws {
        let url = tempURL("audioio-write.wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let original = toneSamples(0.3, freqHz: 880)

        try AudioIO.writeMonoWAV(original, sampleRate: sr, to: url)
        let decoded = try WavIO.decodeMono(url: url, targetRate: sr)

        #expect(decoded.count == original.count)
        for i in 0..<original.count { #expect(decoded[i] == original[i]) }
    }

    @Test
    func testWavIOWriteIsReadableByAudioIODecode() throws {
        let url = tempURL("wavio-write.wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let original = toneSamples(0.3, freqHz: 220)

        try WavIO.writeMonoWAV(original, sampleRate: sr, to: url)
        let decoded = try AudioIO.decodeMono(url: url, sampleRate: sr)

        #expect(decoded.count == original.count)
        for i in 0..<original.count { #expect(decoded[i] == original[i]) }
    }

    @Test
    func testProbeAgreesWithAudioIO() throws {
        let url = tempURL("probe.wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let original = toneSamples(1.25)
        try WavIO.writeMonoWAV(original, sampleRate: sr, to: url)

        let viaWavIO = try WavIO.probe(url: url)
        let viaAudioIO = try AudioIO.probe(url: url)

        #expect(viaWavIO.channels == viaAudioIO.channels)
        #expect(abs(viaWavIO.sampleRate - viaAudioIO.sampleRate) < 0.01)
        #expect(abs(viaWavIO.durationSec - viaAudioIO.durationSec) < 0.001)
        #expect(abs(viaWavIO.durationSec - 1.25) < 0.001)
    }

    // MARK: - Hand-built 16-bit PCM fixture (what a browser MediaRecorder/WAV-encoder would produce)

    private func build16BitPCMWav(samples: [Int16], sampleRate: Int = 44_100, channels: Int = 1) -> Data {
        var data = Data()
        let bytesPerSample = 2
        let blockAlign = bytesPerSample * channels
        let byteRate = sampleRate * blockAlign
        let dataSize = samples.count * bytesPerSample
        func appendASCII(_ s: String) { data.append(contentsOf: s.utf8) }
        func appendLE(_ v: UInt32) { var le = v.littleEndian; withUnsafeBytes(of: &le) { data.append(contentsOf: $0) } }
        func appendLE(_ v: UInt16) { var le = v.littleEndian; withUnsafeBytes(of: &le) { data.append(contentsOf: $0) } }
        func appendLE(_ v: Int16) { var le = v.littleEndian; withUnsafeBytes(of: &le) { data.append(contentsOf: $0) } }

        appendASCII("RIFF"); appendLE(UInt32(36 + dataSize)); appendASCII("WAVE")
        appendASCII("fmt "); appendLE(UInt32(16))
        appendLE(UInt16(1)) // PCM
        appendLE(UInt16(channels))
        appendLE(UInt32(sampleRate))
        appendLE(UInt32(byteRate))
        appendLE(UInt16(blockAlign))
        appendLE(UInt16(16)) // bits per sample
        appendASCII("data"); appendLE(UInt32(dataSize))
        for s in samples { appendLE(s) }
        return data
    }

    @Test
    func testDecodes16BitPCMFixture() throws {
        let url = tempURL("pcm16.wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let raw: [Int16] = [0, 16_384, -16_384, Int16.max, Int16.min, 0]
        try build16BitPCMWav(samples: raw).write(to: url)

        let decoded = try WavIO.decodeMono(url: url, targetRate: 44_100)

        #expect(decoded.count == raw.count)
        for (i, r) in raw.enumerated() {
            let expected = Float(r) / Float(Int16.max)
            #expect(abs(decoded[i] - expected) < 1e-4, "sample \(i)")
        }
    }

    @Test
    func testDecodes16BitStereoFixtureDownmixed() throws {
        let url = tempURL("pcm16-stereo.wav")
        defer { try? FileManager.default.removeItem(at: url) }
        // Interleaved L/R: (1.0, -1.0) repeated — downmix should average to ~0 every frame.
        let raw: [Int16] = [Int16.max, Int16.min, Int16.max, Int16.min]
        try build16BitPCMWav(samples: raw, channels: 2).write(to: url)

        let decoded = try WavIO.decodeMono(url: url, targetRate: 44_100)
        #expect(decoded.count == 2)
        for v in decoded { #expect(abs(v) < 0.01) }
    }
}
