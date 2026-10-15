import Foundation

/// Stato della registrazione salvato su disco accanto ai segmenti, in modo
/// indipendente dal database: consente di ricostruire la registrazione dopo
/// un crash o una chiusura forzata, anche se il database non era stato
/// ancora aggiornato.
struct RecordingManifest: Codable, Equatable {
    enum Status: String, Codable {
        case recording
        case paused
        case finished
    }

    struct Mark: Codable, Equatable {
        var pageID: UUID
        var pageIndex: Int
        var time: TimeInterval
        var kind: String
    }

    struct Interruption: Codable, Equatable {
        var time: TimeInterval
        var reason: String
        var date: Date
    }

    var version = 1
    var recordingID: UUID
    var subjectID: UUID?
    var notebookID: UUID?
    var title: String
    var startedAt: Date
    var updatedAt: Date
    var status: Status
    var profile: String
    var bitrate: Int
    var inputDescription: String?
    var segments: [SegmentedAudioWriter.Segment]
    var marks: [Mark]
    var interruptions: [Interruption]

    static let fileName = "manifest.json"

    var totalDuration: TimeInterval {
        segments.reduce(0) { $0 + $1.duration }
    }
}

/// Scrittura atomica e serializzata del manifest, fuori dal main thread.
final class ManifestWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "it.quadernoai.manifest", qos: .utility)
    private let fileStore: FileStore

    init(fileStore: FileStore) {
        self.fileStore = fileStore
    }

    func url(for recordingID: UUID) -> URL {
        fileStore.recordingDirectory(recordingID).appendingPathComponent(RecordingManifest.fileName)
    }

    func persist(_ manifest: RecordingManifest) {
        let url = url(for: manifest.recordingID)
        queue.async {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(manifest) else { return }
            try? self.fileStore.writeAtomically(data, to: url)
        }
    }

    func persistSynchronously(_ manifest: RecordingManifest) {
        let url = url(for: manifest.recordingID)
        queue.sync {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(manifest) else { return }
            try? self.fileStore.writeAtomically(data, to: url)
        }
    }

    static func load(from url: URL) -> RecordingManifest? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(RecordingManifest.self, from: data)
    }
}
