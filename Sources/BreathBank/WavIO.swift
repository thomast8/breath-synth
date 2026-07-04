import BreathEngineCore
import Foundation

/// Foundation-only RIFF/WAV reader and writer — the Linux-safe half of `AudioIO`'s decode/encode
/// contract, used when AVFoundation isn't available. WAV is a simple enough container that a
/// hand-rolled parser covers everything this module needs: PCM int16/int32 and IEEE-float32,
/// mono or interleaved multi-channel, any sample rate. It does NOT handle AIFC (the committed
/// gold assets) — those stay macOS-only via `AudioIO`'s AVFoundation path; the web backend only
/// ever decodes browser-uploaded WAV takes.
public enum WavIO {
    struct Format {
        var audioFormat: UInt16 // 1 = PCM, 3 = IEEE float
        var channels: Int
        var sampleRate: Double
        var bitsPerSample: Int
    }

    /// Decode a WAV file to mono Float32 at `targetRate`, downmixing and resampling as needed.
    public static func decodeMono(url: URL, targetRate: Double) throws -> [Float] {
        let data = try Data(contentsOf: url)
        let (format, samples) = try parse(data, url: url)
        var mono = downmix(samples, channels: format.channels)
        if format.sampleRate != targetRate, !mono.isEmpty {
            let target = Int((Double(mono.count) * targetRate / format.sampleRate).rounded())
            mono = Resample.toFrames(mono, target)
        }
        return mono
    }

    /// On-disk `(durationSec, sampleRate, channels)`, reading only the header (not the sample data).
    public static func probe(url: URL) throws -> (durationSec: Double, sampleRate: Double, channels: Int) {
        let data = try Data(contentsOf: url)
        let (format, dataByteCount) = try parseHeader(data, url: url)
        let bytesPerSample = format.bitsPerSample / 8
        let frameBytes = bytesPerSample * format.channels
        let frames = frameBytes > 0 ? dataByteCount / frameBytes : 0
        let duration = format.sampleRate > 0 ? Double(frames) / format.sampleRate : 0
        return (duration, format.sampleRate, format.channels)
    }

    /// Write mono Float samples as 32-bit-float little-endian PCM WAV at `sampleRate` — same
    /// on-disk contract as `AudioIO`'s AVFoundation path (lossless, so `decodeMono` of the same
    /// rate returns identical samples).
    public static func writeMonoWAV(_ samples: [Float], sampleRate: Double, to url: URL) throws {
        var data = Data()
        let bytesPerSample = 4
        let byteRate = Int(sampleRate) * bytesPerSample
        let dataSize = samples.count * bytesPerSample
        let riffSize = 36 + dataSize

        data.appendASCII("RIFF")
        data.appendLE(UInt32(riffSize))
        data.appendASCII("WAVE")

        data.appendASCII("fmt ")
        data.appendLE(UInt32(16)) // fmt chunk size
        data.appendLE(UInt16(3)) // audioFormat: IEEE float
        data.appendLE(UInt16(1)) // channels: mono
        data.appendLE(UInt32(sampleRate))
        data.appendLE(UInt32(byteRate))
        data.appendLE(UInt16(bytesPerSample)) // block align
        data.appendLE(UInt16(32)) // bits per sample

        data.appendASCII("data")
        data.appendLE(UInt32(dataSize))
        for sample in samples {
            data.appendLE(sample.bitPattern)
        }

        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw BreathError.ioFailure("writing \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    // MARK: - Parsing

    private static func parseHeader(_ data: Data, url: URL) throws -> (Format, dataByteCount: Int) {
        var format: Format?
        var dataByteCount = 0
        try walkChunks(data, url: url) { id, range in
            if id == "fmt " { format = try readFormat(data, range) }
            if id == "data" { dataByteCount = range.count }
        }
        guard let format else {
            throw BreathError.ioFailure("\(url.lastPathComponent): missing fmt chunk")
        }
        return (format, dataByteCount)
    }

    private static func parse(_ data: Data, url: URL) throws -> (Format, [Float]) {
        var format: Format?
        var samples: [Float] = []
        try walkChunks(data, url: url) { id, range in
            if id == "fmt " { format = try readFormat(data, range) }
            if id == "data" {
                guard let format else {
                    throw BreathError.ioFailure("\(url.lastPathComponent): data chunk before fmt chunk")
                }
                samples = try readSamples(data, range, format: format, url: url)
            }
        }
        guard let format else {
            throw BreathError.ioFailure("\(url.lastPathComponent): missing fmt chunk")
        }
        return (format, samples)
    }

    /// Walks RIFF sub-chunks, invoking `body` with each chunk's 4-char id and byte range (relative
    /// to `data`'s start — `data` is assumed to start at offset 0, matching `Data(contentsOf:)`).
    /// Chunks with an odd byte count are padded to an even boundary per the RIFF spec.
    private static func walkChunks(_ data: Data, url: URL, _ body: (String, Range<Int>) throws -> Void) throws {
        guard data.count >= 12,
              data.subdataASCII(0..<4) == "RIFF",
              data.subdataASCII(8..<12) == "WAVE" else {
            throw BreathError.ioFailure("\(url.lastPathComponent): not a RIFF/WAVE file")
        }
        var offset = 12
        while offset + 8 <= data.count {
            let id = data.subdataASCII(offset..<(offset + 4))
            let size = Int(data.readLE(UInt32.self, at: offset + 4))
            let start = offset + 8
            let end = min(data.count, start + size)
            guard start <= end else { break }
            try body(id, start..<end)
            offset = end + (size.isMultiple(of: 2) ? 0 : 1)
        }
    }

    private static func readFormat(_ data: Data, _ range: Range<Int>) throws -> Format {
        guard range.count >= 16 else {
            throw BreathError.ioFailure("fmt chunk too short")
        }
        let base = range.lowerBound
        let audioFormat = data.readLE(UInt16.self, at: base)
        let channels = Int(data.readLE(UInt16.self, at: base + 2))
        let sampleRate = Double(data.readLE(UInt32.self, at: base + 4))
        let bitsPerSample = Int(data.readLE(UInt16.self, at: base + 14))
        return Format(audioFormat: audioFormat, channels: max(1, channels), sampleRate: sampleRate,
                      bitsPerSample: bitsPerSample)
    }

    /// Decode interleaved PCM/float samples to interleaved Float32 in `[-1, 1]` (still
    /// multi-channel — `downmix` collapses to mono afterward).
    private static func readSamples(_ data: Data, _ range: Range<Int>, format: Format, url: URL) throws -> [Float] {
        let bytesPerSample = format.bitsPerSample / 8
        guard bytesPerSample > 0 else {
            throw BreathError.ioFailure("\(url.lastPathComponent): unsupported bit depth \(format.bitsPerSample)")
        }
        let count = range.count / bytesPerSample
        var out = [Float](repeating: 0, count: count)
        let base = range.lowerBound

        switch (format.audioFormat, format.bitsPerSample) {
        case (1, 16):
            for i in 0..<count {
                let raw = data.readLE(Int16.self, at: base + i * 2)
                out[i] = Float(raw) / Float(Int16.max)
            }
        case (1, 32):
            for i in 0..<count {
                let raw = data.readLE(Int32.self, at: base + i * 4)
                out[i] = Float(raw) / Float(Int32.max)
            }
        case (3, 32):
            for i in 0..<count {
                out[i] = Float(bitPattern: data.readLE(UInt32.self, at: base + i * 4))
            }
        default:
            throw BreathError.ioFailure(
                "\(url.lastPathComponent): unsupported WAV format (audioFormat=\(format.audioFormat), "
                + "bitsPerSample=\(format.bitsPerSample))")
        }
        return out
    }

    private static func downmix(_ interleaved: [Float], channels: Int) -> [Float] {
        guard channels > 1 else { return interleaved }
        let frames = interleaved.count / channels
        var mono = [Float](repeating: 0, count: frames)
        for f in 0..<frames {
            var sum: Float = 0
            for c in 0..<channels { sum += interleaved[f * channels + c] }
            mono[f] = sum / Float(channels)
        }
        return mono
    }
}

// MARK: - Little-endian byte helpers

private extension Data {
    func subdataASCII(_ range: Range<Int>) -> String {
        String(decoding: self.subdata(in: range), as: UTF8.self)
    }

    func readLE<T: FixedWidthInteger>(_ type: T.Type, at offset: Int) -> T {
        var value: T = 0
        _ = Swift.withUnsafeMutableBytes(of: &value) { dest in
            self.copyBytes(to: dest, from: offset..<(offset + MemoryLayout<T>.size))
        }
        return T(littleEndian: value)
    }

    mutating func appendASCII(_ string: String) {
        self.append(contentsOf: string.utf8)
    }

    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { self.append(contentsOf: $0) }
    }
}
