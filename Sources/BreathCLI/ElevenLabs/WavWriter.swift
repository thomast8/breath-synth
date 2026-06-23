import Foundation

/// PCM conversion + canonical WAV writing. Kept dependency-free so it is easy to
/// reason about and test.
enum PCM {
    /// Interpret little-endian signed 16-bit PCM bytes as normalized Float samples.
    static func int16ToFloat(_ data: Data) -> [Float] {
        let count = data.count / 2
        guard count > 0 else { return [] }
        var out = [Float](repeating: 0, count: count)
        data.withUnsafeBytes { raw in
            let base = raw.baseAddress!
            for i in 0..<count {
                let lo = UInt16(base.load(fromByteOffset: i * 2, as: UInt8.self))
                let hi = UInt16(base.load(fromByteOffset: i * 2 + 1, as: UInt8.self))
                let bits = lo | (hi << 8)
                out[i] = Float(Int16(bitPattern: bits)) / 32768.0
            }
        }
        return out
    }

    /// Encode normalized Float samples as little-endian signed 16-bit PCM bytes.
    static func floatToInt16(_ samples: [Float]) -> Data {
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            let clamped = max(-1, min(1, sample))
            let value = Int16(clamped * 32767)
            let bits = UInt16(bitPattern: value)
            data.append(UInt8(bits & 0xFF))
            data.append(UInt8((bits >> 8) & 0xFF))
        }
        return data
    }

    /// Wrap little-endian 16-bit PCM bytes in a canonical 44-byte WAV header.
    static func wavData(int16LE pcm: Data, sampleRate: Int, channels: Int) -> Data {
        let bitsPerSample = 16
        let byteRate = sampleRate * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8
        let dataLength = pcm.count

        var data = Data()
        func appendString(_ string: String) { data.append(contentsOf: string.utf8) }
        func appendU32(_ value: UInt32) {
            var v = value.littleEndian
            withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
        }
        func appendU16(_ value: UInt16) {
            var v = value.littleEndian
            withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
        }

        appendString("RIFF")
        appendU32(UInt32(36 + dataLength))
        appendString("WAVE")
        appendString("fmt ")
        appendU32(16)                       // PCM fmt chunk size
        appendU16(1)                        // audio format = PCM
        appendU16(UInt16(channels))
        appendU32(UInt32(sampleRate))
        appendU32(UInt32(byteRate))
        appendU16(UInt16(blockAlign))
        appendU16(UInt16(bitsPerSample))
        appendString("data")
        appendU32(UInt32(dataLength))
        data.append(pcm)
        return data
    }

    /// Write Float samples to a 16-bit WAV file.
    static func writeWAV(samples: [Float], sampleRate: Int, to url: URL) throws {
        let pcm = floatToInt16(samples)
        let wav = wavData(int16LE: pcm, sampleRate: sampleRate, channels: 1)
        try wav.write(to: url, options: .atomic)
    }
}
