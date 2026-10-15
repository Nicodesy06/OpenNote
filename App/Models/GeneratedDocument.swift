import Foundation
import SwiftData
import QuadernoCore

/// Sbobinatura (o trascrizione pulita / riassunto) generata dall'AI e poi
/// modificabile. Una nuova generazione crea sempre un nuovo documento: il
/// lavoro dello studente non viene mai sovrascritto in modo silenzioso.
@Model
final class GeneratedDocument {
    @Attribute(.unique) var id: UUID
    var title: String
    var modeRaw: String
    var createdAt: Date
    var updatedAt: Date
    var providerID: String
    var model: String
    var promptVersion: String
    var headerMarkdown: String
    var outlineJSON: Data?
    var inputTokens: Int
    var outputTokens: Int
    var searchText: String
    var subject: Subject?
    var recording: AudioRecording?
    /// Trascrizione da cui è stato generato (per i collegamenti all'audio).
    var transcriptID: UUID?
    @Relationship(deleteRule: .cascade, inverse: \GeneratedSection.document) var sections: [GeneratedSection] = []
    @Relationship(deleteRule: .cascade, inverse: \DocumentVersion.document) var versions: [DocumentVersion] = []

    init(title: String, mode: SbobinaturaMode, providerID: String, model: String, promptVersion: String) {
        self.id = UUID()
        self.title = title
        self.modeRaw = mode.rawValue
        self.createdAt = Date()
        self.updatedAt = Date()
        self.providerID = providerID
        self.model = model
        self.promptVersion = promptVersion
        self.headerMarkdown = ""
        self.inputTokens = 0
        self.outputTokens = 0
        self.searchText = ""
    }

    var mode: SbobinaturaMode { SbobinaturaMode(rawValue: modeRaw) ?? .integrale }

    var orderedSections: [GeneratedSection] { sections.sorted { $0.order < $1.order } }

    var outline: LessonOutline? {
        outlineJSON.flatMap { try? JSONDecoder().decode(LessonOutline.self, from: $0) }
    }

    var markdown: String {
        ([headerMarkdown] + orderedSections.map(\.markdown)).joined(separator: "\n\n")
    }

    var issueCount: Int {
        orderedSections.reduce(0) { $0 + $1.verification.issues.filter { $0.severity >= .medium }.count }
    }

    var failedSectionCount: Int {
        sections.filter { $0.state == .failed }.count
    }

    func refreshSearchText() {
        searchText = SourceMarkers.stripForExport(orderedSections.map(\.markdown).joined(separator: "\n"), keepUncertain: false)
    }
}

@Model
final class GeneratedSection {
    @Attribute(.unique) var id: UUID
    var order: Int
    var title: String
    var markdown: String
    var segmentStart: Int
    var segmentEnd: Int
    var timeStart: TimeInterval
    var timeEnd: TimeInterval
    var stateRaw: String
    var errorMessage: String?
    var verificationJSON: Data?
    /// `true` dopo una modifica manuale: la rigenerazione chiede conferma e
    /// salva prima una versione.
    var isUserEdited: Bool
    var updatedAt: Date
    var model: String
    var promptVersion: String
    var document: GeneratedDocument?

    init(dto: GeneratedSectionDTO) {
        self.id = UUID()
        self.order = dto.order
        self.title = dto.title
        self.markdown = dto.markdown
        self.segmentStart = dto.segmentRange.lowerBound
        self.segmentEnd = dto.segmentRange.upperBound
        self.timeStart = dto.timeRange.lowerBound
        self.timeEnd = dto.timeRange.upperBound
        self.stateRaw = dto.state.rawValue
        self.errorMessage = dto.errorMessage
        self.verificationJSON = try? JSONEncoder().encode(dto.verification)
        self.isUserEdited = false
        self.updatedAt = Date()
        self.model = dto.model
        self.promptVersion = dto.promptVersion
    }

    var state: SectionGenerationState { SectionGenerationState(rawValue: stateRaw) ?? .failed }

    var verification: SectionVerification {
        get { verificationJSON.flatMap { try? JSONDecoder().decode(SectionVerification.self, from: $0) } ?? SectionVerification(status: .notVerified) }
        set { verificationJSON = try? JSONEncoder().encode(newValue) }
    }

    /// Applica il risultato di una rigenerazione mantenendo l'identità.
    func apply(_ dto: GeneratedSectionDTO) {
        title = dto.title
        markdown = dto.markdown
        segmentStart = dto.segmentRange.lowerBound
        segmentEnd = dto.segmentRange.upperBound
        timeStart = dto.timeRange.lowerBound
        timeEnd = dto.timeRange.upperBound
        stateRaw = dto.state.rawValue
        errorMessage = dto.errorMessage
        verification = dto.verification
        isUserEdited = false
        updatedAt = Date()
        model = dto.model
        promptVersion = dto.promptVersion
    }
}

/// Istantanea del documento: creata a ogni generazione, prima di ogni
/// rigenerazione di sezione e dopo modifiche manuali significative.
@Model
final class DocumentVersion {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var reason: String
    @Attribute(.externalStorage) var snapshotJSON: Data
    var document: GeneratedDocument?

    init(reason: String, snapshot: DocumentSnapshot) {
        self.id = UUID()
        self.createdAt = Date()
        self.reason = reason
        self.snapshotJSON = (try? JSONEncoder().encode(snapshot)) ?? Data()
    }

    var snapshot: DocumentSnapshot? {
        try? JSONDecoder().decode(DocumentSnapshot.self, from: snapshotJSON)
    }
}

struct DocumentSnapshot: Codable, Equatable {
    struct Section: Codable, Equatable {
        var id: UUID
        var order: Int
        var title: String
        var markdown: String
        var isUserEdited: Bool
    }
    var title: String
    var headerMarkdown: String
    var sections: [Section]

    init(document: GeneratedDocument) {
        title = document.title
        headerMarkdown = document.headerMarkdown
        sections = document.orderedSections.map { Section(id: $0.id, order: $0.order, title: $0.title, markdown: $0.markdown, isUserEdited: $0.isUserEdited) }
    }
}
