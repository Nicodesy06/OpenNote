import Foundation

/// Costruttore di corpi multipart/form-data. Il file audio viene copiato a
/// blocchi in un file temporaneo, così che anche chunk da 25 MB non vengano
/// mai caricati interamente in memoria.
public struct MultipartFormData: Sendable {
    public enum Part: Sendable {
        case field(name: String, value: String)
        case file(name: String, fileName: String, mimeType: String, url: URL)
        case fileData(name: String, fileName: String, mimeType: String, data: Data)
    }

    public let boundary: String
    public private(set) var parts: [Part] = []

    public init(boundary: String = "QuadernoBoundary-\(UUID().uuidString)") {
        self.boundary = boundary
    }

    public var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    public mutating func addField(_ name: String, _ value: String) {
        parts.append(.field(name: name, value: value))
    }

    public mutating func addFile(_ name: String, fileName: String, mimeType: String, url: URL) {
        parts.append(.file(name: name, fileName: fileName, mimeType: mimeType, url: url))
    }

    public mutating func addFileData(_ name: String, fileName: String, mimeType: String, data: Data) {
        parts.append(.fileData(name: name, fileName: fileName, mimeType: mimeType, data: data))
    }

    private func header(for part: Part) -> Data {
        var text = "--\(boundary)\r\n"
        switch part {
        case .field(let name, _):
            text += "Content-Disposition: form-data; name=\"\(Self.escape(name))\"\r\n\r\n"
        case .file(let name, let fileName, let mimeType, _), .fileData(let name, let fileName, let mimeType, _):
            text += "Content-Disposition: form-data; name=\"\(Self.escape(name))\"; filename=\"\(Self.escape(fileName))\"\r\n"
            text += "Content-Type: \(mimeType)\r\n\r\n"
        }
        return Data(text.utf8)
    }

    private var closing: Data { Data("--\(boundary)--\r\n".utf8) }

    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\"", with: "%22").replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
    }

    /// Corpo completo in memoria (solo per parti piccole o nei test).
    public func encodedData() throws -> Data {
        var data = Data()
        for part in parts {
            data.append(header(for: part))
            switch part {
            case .field(_, let value):
                data.append(Data(value.utf8))
            case .fileData(_, _, _, let fileData):
                data.append(fileData)
            case .file(_, _, _, let url):
                data.append(try Data(contentsOf: url, options: .mappedIfSafe))
            }
            data.append(Data("\r\n".utf8))
        }
        data.append(closing)
        return data
    }

    /// Scrive il corpo su file copiando i file a blocchi da 256 KB.
    public func write(to destination: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        guard fileManager.createFile(atPath: destination.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        for part in parts {
            try output.write(contentsOf: header(for: part))
            switch part {
            case .field(_, let value):
                try output.write(contentsOf: Data(value.utf8))
            case .fileData(_, _, _, let fileData):
                try output.write(contentsOf: fileData)
            case .file(_, _, _, let url):
                let input = try FileHandle(forReadingFrom: url)
                defer { try? input.close() }
                while true {
                    let chunk = try input.read(upToCount: 256 * 1024) ?? Data()
                    if chunk.isEmpty { break }
                    try output.write(contentsOf: chunk)
                }
            }
            try output.write(contentsOf: Data("\r\n".utf8))
        }
        try output.write(contentsOf: closing)
    }
}
