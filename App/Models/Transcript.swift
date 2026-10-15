import Foundation
import SwiftData
import QuadernoCore

enum TranscriptStatus: String, Codable {
    case completed
    case failed
}

/// Trascrizione originale, conservata separatamente dalla sbobinatura e
/// modificabile dall'utente (il testo originale del provider resta in
/// `TranscriptSegment.originalText`).
@Model
final class Transcript {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var providerID: String
    var model: String
    var languageCodes: [String]
    var precisionRaw: String
    var statusRaw: String
    /// Testo completo per la ricerca.
    var searchText: String
    /// `TranscriptMergeReport` serializzato.
    var reportJSON: Data?
    var isEdited: Bool
    var recording: AudioRecording?
    @Relationship(deleteRule: .cascade, inverse: \TranscriptSegment.transcript) var segments: [TranscriptSegment] = []

    init(providerID: String, model: String, precision: TimingPrecision) {
        self.id = UUID()
        self.createdAt = Date()
        self.providerID = providerID
        self.model = model
        self.languageCodes = []
        self.precisionRaw = precision.rawValue
        self.statusRaw = TranscriptStatus.completed.rawValue
        self.searchText = ""
        self.isEdited = false
    }

    var status: TranscriptStatus { TranscriptStatus(rawValue: statusRaw) ?? .failed }
    var precision: TimingPrecision { TimingPrecision(rawValue: precisionRaw) ?? .chunk }

    var orderedSegments: [TranscriptSegment] { segments.sorted { $0.index < $1.index } }

    var report: TranscriptMergeReport? {
        reportJSON.flatMap { try? JSONDecoder().decode(TranscriptMergeReport.self, from: $0) }
    }

    /// Segmenti nel formato del motore di sbobinatura.
    var segmentDTOs: [TranscriptSegmentDTO] {
        orderedSegments.map { segment in
            TranscriptSegmentDTO(index: segment.index, start: segment.start, end: segment.end, text: segment.text, speaker: segment.speaker, chunkIndex: segment.chunkIndex, precision: TimingPrecision(rawValue: segment.precisionRaw) ?? .chunk)
        }
    }

    func refreshSearchText() {
        searchText = orderedSegments.map(\.text).joined(separator: " ")
    }
}

@Model
final class TranscriptSegment {
    @Attribute(.unique) var id: UUID
    var index: Int
    var start: TimeInterval
    var end: TimeInterval
    var text: String
    var originalText: String
    var speaker: String?
    var chunkIndex: Int
    var precisionRaw: String
    var transcript: Transcript?

    init(dto: TranscriptSegmentDTO) {
        self.id = UUID()
        self.index = dto.index
        self.start = dto.start
        self.end = dto.end
        self.text = dto.text
        self.originalText = dto.text
        self.speaker = dto.speaker
        self.chunkIndex = dto.chunkIndex
        self.precisionRaw = dto.precision.rawValue
    }

    var isEdited: Bool { text != originalText }
}
