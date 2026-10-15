import Foundation
import SwiftData

/// Materia universitaria: contenitore logico di quaderni, registrazioni,
/// sbobinature, PDF, glossario e preferenze AI.
@Model
final class Subject {
    @Attribute(.unique) var id: UUID
    var name: String
    var colorHex: String
    var iconName: String
    var createdAt: Date
    var updatedAt: Date
    /// Le materie archiviate restano integre ma escono dalla libreria
    /// principale; non vengono mai cancellate implicitamente.
    var archivedAt: Date?
    var sortIndex: Int
    /// Lingua dei documenti generati (es. "italiano").
    var documentLanguage: String
    /// Codici lingua per la trascrizione (es. ["it"]; vuoto = automatico).
    var transcriptionLanguages: [String]
    /// Indicazioni libere dello studente per la sbobinatura di questa materia.
    var aiInstructions: String

    @Relationship(deleteRule: .cascade, inverse: \Notebook.subject) var notebooks: [Notebook] = []
    @Relationship(deleteRule: .cascade, inverse: \AudioRecording.subject) var recordings: [AudioRecording] = []
    @Relationship(deleteRule: .cascade, inverse: \GeneratedDocument.subject) var documents: [GeneratedDocument] = []
    @Relationship(deleteRule: .cascade, inverse: \PDFMaterial.subject) var materials: [PDFMaterial] = []
    @Relationship(deleteRule: .cascade, inverse: \SubjectGlossary.subject) var glossary: SubjectGlossary?

    init(name: String, colorHex: String = "#3B6FD8", iconName: String = "book.closed", sortIndex: Int = 0) {
        self.id = UUID()
        self.name = name
        self.colorHex = colorHex
        self.iconName = iconName
        self.createdAt = Date()
        self.updatedAt = Date()
        self.archivedAt = nil
        self.sortIndex = sortIndex
        self.documentLanguage = "italiano"
        self.transcriptionLanguages = ["it"]
        self.aiInstructions = ""
    }

    var isArchived: Bool { archivedAt != nil }

    var glossaryTerms: [String] { glossary?.terms ?? [] }
}

/// Glossario tecnico della materia: grafie corrette di nomi e termini,
/// usate come parole chiave per la trascrizione e come riferimento per la
/// rielaborazione.
@Model
final class SubjectGlossary {
    @Attribute(.unique) var id: UUID
    var terms: [String]
    var notes: String
    var updatedAt: Date
    var subject: Subject?

    init(terms: [String] = []) {
        self.id = UUID()
        self.terms = terms
        self.notes = ""
        self.updatedAt = Date()
    }
}
