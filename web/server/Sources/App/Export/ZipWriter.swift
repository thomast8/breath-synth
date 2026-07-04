import Foundation

/// A minimal, dependency-free ZIP writer — STORED (uncompressed) entries only. Avoids pulling in a
/// zlib-based archiver dependency or shelling out to a `zip`/`tar` binary that may not exist in a
/// slim runtime image. WAV audio barely compresses anyway, so STORED costs nothing in practice, and
/// the output is a fully standard ZIP file any unzip tool can open.
enum ZipWriter {
    struct Entry {
        var name: String
        var data: Data
    }

    static func write(_ entries: [Entry]) -> Data {
        var body = Data()
        var centralDirectory = Data()
        var offset: UInt32 = 0

        for entry in entries {
            let nameBytes = Array(entry.name.utf8)
            let crc = CRC32.checksum(entry.data)
            let size = UInt32(entry.data.count)

            var local = Data()
            local.appendLE(UInt32(0x0403_4b50)) // local file header signature
            local.appendLE(UInt16(20)) // version needed
            local.appendLE(UInt16(0)) // flags
            local.appendLE(UInt16(0)) // compression: stored
            local.appendLE(UInt16(0)) // mod time
            local.appendLE(UInt16(0)) // mod date
            local.appendLE(crc)
            local.appendLE(size) // compressed size == uncompressed for stored
            local.appendLE(size)
            local.appendLE(UInt16(nameBytes.count))
            local.appendLE(UInt16(0)) // extra field length
            local.append(contentsOf: nameBytes)
            local.append(entry.data)
            body.append(local)

            var central = Data()
            central.appendLE(UInt32(0x0201_4b50)) // central directory header signature
            central.appendLE(UInt16(20)) // version made by
            central.appendLE(UInt16(20)) // version needed
            central.appendLE(UInt16(0)) // flags
            central.appendLE(UInt16(0)) // compression: stored
            central.appendLE(UInt16(0)) // mod time
            central.appendLE(UInt16(0)) // mod date
            central.appendLE(crc)
            central.appendLE(size)
            central.appendLE(size)
            central.appendLE(UInt16(nameBytes.count))
            central.appendLE(UInt16(0)) // extra field length
            central.appendLE(UInt16(0)) // comment length
            central.appendLE(UInt16(0)) // disk number start
            central.appendLE(UInt16(0)) // internal attributes
            central.appendLE(UInt32(0)) // external attributes
            central.appendLE(offset) // relative offset of local header
            central.append(contentsOf: nameBytes)
            centralDirectory.append(central)

            offset += UInt32(local.count)
        }

        var end = Data()
        end.appendLE(UInt32(0x0605_4b50)) // end of central directory signature
        end.appendLE(UInt16(0)) // disk number
        end.appendLE(UInt16(0)) // disk with central directory
        end.appendLE(UInt16(entries.count)) // entries on this disk
        end.appendLE(UInt16(entries.count)) // total entries
        end.appendLE(UInt32(centralDirectory.count))
        end.appendLE(offset) // offset of central directory
        end.appendLE(UInt16(0)) // comment length

        return body + centralDirectory + end
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { self.append(contentsOf: $0) }
    }
}
