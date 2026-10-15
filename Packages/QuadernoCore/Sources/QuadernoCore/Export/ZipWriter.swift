import Foundation

/// Scrittore ZIP minimale (metodo "stored", senza compressione), sufficiente
/// per produrre pacchetti DOCX validi senza dipendenze esterne.
public struct ZipWriter {
    private struct Entry {
        var name: Data
        var crc: UInt32
        var size: UInt32
        var offset: UInt32
    }

    private var data = Data()
    private var entries: [Entry] = []

    public init() {}

    public mutating func add(path: String, contents: Data) {
        let name = Data(path.utf8)
        let crc = CRC32.checksum(contents)
        let offset = UInt32(data.count)
        // Local file header
        data.appendLE(UInt32(0x04034b50))
        data.appendLE(UInt16(20))        // versione necessaria
        data.appendLE(UInt16(0x0800))    // nomi UTF-8
        data.appendLE(UInt16(0))         // metodo: stored
        data.appendLE(UInt16(0))         // ora
        data.appendLE(UInt16(0x5A21))    // data fissa (1 gen 2025), per output deterministico
        data.appendLE(crc)
        data.appendLE(UInt32(contents.count))
        data.appendLE(UInt32(contents.count))
        data.appendLE(UInt16(name.count))
        data.appendLE(UInt16(0))
        data.append(name)
        data.append(contents)
        entries.append(Entry(name: name, crc: crc, size: UInt32(contents.count), offset: offset))
    }

    public mutating func add(path: String, text: String) {
        add(path: path, contents: Data(text.utf8))
    }

    public func finalize() -> Data {
        var output = data
        let centralStart = UInt32(output.count)
        for entry in entries {
            output.appendLE(UInt32(0x02014b50))
            output.appendLE(UInt16(20))
            output.appendLE(UInt16(20))
            output.appendLE(UInt16(0x0800))
            output.appendLE(UInt16(0))
            output.appendLE(UInt16(0))
            output.appendLE(UInt16(0x5A21))
            output.appendLE(entry.crc)
            output.appendLE(entry.size)
            output.appendLE(entry.size)
            output.appendLE(UInt16(entry.name.count))
            output.appendLE(UInt16(0)) // extra
            output.appendLE(UInt16(0)) // commento
            output.appendLE(UInt16(0)) // disco
            output.appendLE(UInt16(0)) // attributi interni
            output.appendLE(UInt32(0)) // attributi esterni
            output.appendLE(entry.offset)
            output.append(entry.name)
        }
        let centralSize = UInt32(output.count) - centralStart
        output.appendLE(UInt32(0x06054b50))
        output.appendLE(UInt16(0))
        output.appendLE(UInt16(0))
        output.appendLE(UInt16(entries.count))
        output.appendLE(UInt16(entries.count))
        output.appendLE(centralSize)
        output.appendLE(centralStart)
        output.appendLE(UInt16(0))
        return output
    }
}

enum CRC32 {
    static let table: [UInt32] = (0..<256).map { value -> UInt32 in
        var crc = UInt32(value)
        for _ in 0..<8 {
            crc = (crc & 1) != 0 ? (0xEDB88320 ^ (crc >> 1)) : (crc >> 1)
        }
        return crc
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFFFFFF
    }
}

extension Data {
    mutating func appendLE(_ value: UInt16) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }

    mutating func appendLE(_ value: UInt32) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
