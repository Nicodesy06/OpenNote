import Foundation
import SwiftData

enum RecordingSource: String, Codable {
    case recorded
    case imported
}

enum RecordingStatus: String, Codable {
    /// Registrazione in corso (o interrotta da un crash, finché non recuperata).
    case recording
    /// Stop premuto: unione dei segmenti in corso.
    case finalizing
    case ready
    /// Ricostruita dai segmenti dopo una chiusura imprevista.
    case recovered
    /// File audio mancante o illeggibile.
    case damaged

    var displayName: String {
        switch self {
        case .recording: return "In registrazione"
        case .finalizing: return "Salvataggio"
        case .ready: return "Pronta"
        case .recovered: return "Recuperata"
        case .damaged: return "Danneggiata"
        }
    }
}

@Model
final class AudioRecording {
    @Attribute(.unique) var id: UUID
    var title: String
    var createdAt: Date
    var recordedAt: Date
    var duration: TimeInterval
    /// File audio consolidato, relativo alla cartella della registrazione.
    var audioFileName: String?
    var sourceRaw: String
    var statusRaw: String
    var originalFileName: String?
    var byteSize: Int64
    var profileName: String?
    var inputDescription: String?
    var notes: String
    var subject: Subject?
    var notebook: Notebook?
    @Relationship(deleteRule: .cascade, inverse: \AudioSegment.recording) var segments: [AudioSegment] = []
    @Relationship(deleteRule: .cascade, inverse: \PageMark.recording) var pageMarks: [PageMark] = []
    @Relationship(deleteRule: .cascade, inverse: \Transcript.recording) var transcripts: [Transcript] = []
    /// Le sbobinature sopravvivono all'eliminazione dell'audio (vengono
    /// scollegate, non cancellate).
    @Relationship(deleteRule: .nullify, inverse: \GeneratedDocument.recording) var documents: [GeneratedDocument] = []

    init(title: String, source: RecordingSource, status: RecordingStatus) {
        self.id = UUID()
        self.title = title
        self.createdAt = Date()
        self.recordedAt = Date()
        self.duration = 0
        self.audioFileName = nil
        self.sourceRaw = source.rawValue
        self.statusRaw = status.rawValue
        self.byteSize = 0
        self.notes = ""
    }

    var source: RecordingSource { RecordingSource(rawValue: sourceRaw) ?? .recorded }

    var status: RecordingStatus {
        get { RecordingStatus(rawValue: statusRaw) ?? .damaged }
        set { statusRaw = newValue.rawValue }
    }

    var latestTranscript: Transcript? {
        transcripts.filter { $0.status == .completed }.max { $0.createdAt < $1.createdAt }
    }

    var orderedSegments: [AudioSegment] { segments.sorted { $0.index < $1.index } }
}

/// Segmento audio scritto dal registratore (rotazione periodica dei file per
/// limitare la perdita in caso di chiusura imprevista). Dopo lo Stop i
/// segmenti vengono uniti in un unico file e rimossi.
@Model
final class AudioSegment {
    @Attribute(.unique) var id: UUID
    var index: Int
    var fileName: String
    var startOffset: TimeInterval
    var duration: TimeInterval
    var recording: AudioRecording?

    init(index: Int, fileName: String, startOffset: TimeInterval, duration: TimeInterval) {
        self.id = UUID()
        self.index = index
        self.fileName = fileName
        self.startOffset = startOffset
        self.duration = duration
    }
}

enum PageMarkKind: String, Codable {
    case visited
    case edited
}

/// Riferimento temporale fra registrazione e pagina del quaderno, base per
/// la sincronizzazione audio-appunti.
@Model
final class PageMark {
    @Attribute(.unique) var id: UUID
    var pageID: UUID
    var pageIndex: Int
    var time: TimeInterval
    var kindRaw: String
    var recording: AudioRecording?

    init(pageID: UUID, pageIndex: Int, time: TimeInterval, kind: PageMarkKind) {
        self.id = UUID()
        self.pageID = pageID
        self.pageIndex = pageIndex
        self.time = time
        self.kindRaw = kind.rawValue
    }

    var kind: PageMarkKind { PageMarkKind(rawValue: kindRaw) ?? .visited }
}
