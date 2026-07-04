import AVFoundation
import BreathEngine
import Foundation

/// Audio file I/O for the offline bank builder: decode enrollment takes to mono Float at the working
/// rate, probe their on-disk properties for the manifest, and write 32-bit-float mono WAV caches the
/// engine reads back losslessly. Kept out of `BreathEngine` (which only ever reads its bundled
/// assets) so the app-layer builder owns capture-side file handling. All functions are non-isolated
/// so the synchronous CLI can call them directly.
public enum AudioIO {
    /// Decode any audio file to mono Float at `sampleRate`, through the engine's exact decoder so the
    /// builder and the renderer agree sample-for-sample on what a take's samples are.
    public static func decodeMono(
        url: URL,
        sampleRate: Double = AudioConstants.workingSampleRate
    ) throws -> [Float] {
        try AssetLibrary.loadMonoSamples(url: url, targetRate: sampleRate)
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
}
