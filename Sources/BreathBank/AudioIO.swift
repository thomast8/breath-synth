#if canImport(AVFoundation)
import AVFoundation
#endif
import BreathEngineCore
import Foundation

/// Audio file I/O for the offline bank builder: decode enrollment takes to mono Float at the working
/// rate, probe their on-disk properties for the manifest, and write 32-bit-float mono WAV caches the
/// engine reads back losslessly. Kept out of `BreathEngine` (which only ever reads its bundled
/// assets) so the app-layer builder owns capture-side file handling. All functions are non-isolated
/// so the synchronous CLI can call them directly.
///
/// Dual-path: AVFoundation decodes any container format (WAV, AIFC, ...) on Apple platforms; a
/// Foundation-only `WavIO` handles WAV specifically on Linux, since that's all the web backend's
/// browser-uploaded takes ever are. Both write the identical 32-bit-float WAV contract, so a cache
/// written by one is byte-identical to one written by the other.
public enum AudioIO {
#if canImport(AVFoundation)
    /// Decode any audio file to mono Float at `sampleRate`. Own decode path (not a call into
    /// `BreathEngine`'s `AssetLibrary`, which is Apple-only and would drag this whole module out of
    /// Linux's reach) — same downmix + resample logic, kept in sync by inspection since both are
    /// small and rarely change.
    public static func decodeMono(
        url: URL,
        sampleRate: Double = AudioConstants.workingSampleRate
    ) throws -> [Float] {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw BreathError.ioFailure("opening \(url.lastPathComponent): \(error.localizedDescription)")
        }
        let inFormat = file.processingFormat
        guard file.length > 0 else { return [] }
        let channelCount = Int(inFormat.channelCount)

        // `AVAudioFile.read(into:)` is NOT guaranteed to fill a large buffer in one call (observed:
        // a 13230-frame mono Float32 WAV under-read to 12277 frames on a single call) — loop reading
        // fixed-size chunks until the file position reaches EOF, exactly as Apple's own docs recommend.
        var mono: [Float] = []
        mono.reserveCapacity(Int(file.length))
        let chunkFrames: AVAudioFrameCount = 65_536
        while file.framePosition < file.length {
            guard let chunk = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: chunkFrames) else { break }
            do {
                try file.read(into: chunk)
            } catch {
                throw BreathError.ioFailure("reading \(url.lastPathComponent): \(error.localizedDescription)")
            }
            let frames = Int(chunk.frameLength)
            guard frames > 0, let channelData = chunk.floatChannelData else { break }
            if channelCount == 1 {
                mono.append(contentsOf: UnsafeBufferPointer(start: channelData[0], count: frames))
            } else {
                let scale = 1 / Float(channelCount)
                for i in 0..<frames {
                    var sum: Float = 0
                    for c in 0..<channelCount { sum += channelData[c][i] }
                    mono.append(sum * scale)
                }
            }
        }
        let frames = mono.count

        if inFormat.sampleRate != sampleRate {
            let target = Int((Double(frames) * sampleRate / inFormat.sampleRate).rounded())
            mono = Resample.toFrames(mono, target)
        }
        return mono
    }

    /// On-disk `(durationSec, sampleRate, channels)` for a take, for its manifest `BreathAsset` entry.
    public static func probe(url: URL) throws -> (durationSec: Double, sampleRate: Double, channels: Int) {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw BreathError.ioFailure("probing \(url.lastPathComponent): \(error.localizedDescription)")
        }
        let sr = file.fileFormat.sampleRate
        let frames = Double(file.length)
        return (sr > 0 ? frames / sr : 0, sr, Int(file.fileFormat.channelCount))
    }

    /// Write mono Float samples as 32-bit-float little-endian PCM WAV at `sampleRate`. Lossless, so a
    /// later `decodeMono` of the same rate returns the identical samples (the offset-validity contract
    /// the fragment bank relies on).
    public static func writeMonoWAV(_ samples: [Float], sampleRate: Double, to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false
        ) else {
            throw BreathError.audioFormatUnavailable
        }
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings)
            let frameCount = AVAudioFrameCount(max(1, samples.count))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
                throw BreathError.audioFormatUnavailable
            }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            if let channel = buffer.floatChannelData, !samples.isEmpty {
                samples.withUnsafeBufferPointer { src in
                    channel[0].update(from: src.baseAddress!, count: samples.count)
                }
            }
            try file.write(from: buffer)
        } catch let error as BreathError {
            throw error
        } catch {
            throw BreathError.ioFailure("writing \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }
#else
    /// Decode a WAV file to mono Float at `sampleRate`. Linux only ever needs to read
    /// browser-uploaded takes (always WAV), so `WavIO` — not a general-purpose decoder — is enough.
    public static func decodeMono(
        url: URL,
        sampleRate: Double = AudioConstants.workingSampleRate
    ) throws -> [Float] {
        try WavIO.decodeMono(url: url, targetRate: sampleRate)
    }

    /// On-disk `(durationSec, sampleRate, channels)` for a take, for its manifest `BreathAsset` entry.
    public static func probe(url: URL) throws -> (durationSec: Double, sampleRate: Double, channels: Int) {
        try WavIO.probe(url: url)
    }

    /// Write mono Float samples as 32-bit-float little-endian PCM WAV at `sampleRate` — byte-identical
    /// contract to the AVFoundation path above.
    public static func writeMonoWAV(_ samples: [Float], sampleRate: Double, to url: URL) throws {
        try WavIO.writeMonoWAV(samples, sampleRate: sampleRate, to: url)
    }
#endif
}
