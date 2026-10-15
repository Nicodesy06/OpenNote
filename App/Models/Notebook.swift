import Foundation
import SwiftData

enum PageTemplate: String, Codable, CaseIterable, Identifiable {
    case blank, lined, grid, dotted

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .blank: return "Bianca"
        case .lined: return "Rigata"
        case .grid: return "Quadrettata"
        case .dotted: return "Puntinata"
        }
    }

    var symbol: String {
        switch self {
        case .blank: return "doc"
        case .lined: return "text.justify"
        case .grid: return "squareshape.split.3x3"
        case .dotted: return "circle.grid.3x3"
        }
    }
}

@Model
final class Notebook {
    @Attribute(.unique) var id: UUID
    var title: String
    var coverColorHex: String
    var defaultTemplateRaw: String
    var createdAt: Date
    var updatedAt: Date
    var lastOpenedPageIndex: Int
    var subject: Subject?
    @Relationship(deleteRule: .cascade, inverse: \NotebookPage.notebook) var pages: [NotebookPage] = []
    /// Registrazioni effettuate mentre il quaderno era aperto.
    @Relationship(deleteRule: .nullify, inverse: \AudioRecording.notebook) var recordings: [AudioRecording] = []

    init(title: String, coverColorHex: String = "#3B6FD8", template: PageTemplate = .lined) {
        self.id = UUID()
        self.title = title
        self.coverColorHex = coverColorHex
        self.defaultTemplateRaw = template.rawValue
        self.createdAt = Date()
        self.updatedAt = Date()
        self.lastOpenedPageIndex = 0
    }

    var defaultTemplate: PageTemplate {
        get { PageTemplate(rawValue: defaultTemplateRaw) ?? .lined }
        set { defaultTemplateRaw = newValue.rawValue }
    }

    var orderedPages: [NotebookPage] {
        pages.sorted { $0.index < $1.index }
    }
}

@Model
final class NotebookPage {
    @Attribute(.unique) var id: UUID
    var index: Int
    var templateRaw: String
    var createdAt: Date
    var updatedAt: Date
    var notebook: Notebook?
    @Relationship(deleteRule: .cascade, inverse: \DrawingData.page) var drawing: DrawingData?
    @Relationship(deleteRule: .cascade, inverse: \PageElement.page) var elements: [PageElement] = []

    init(index: Int, template: PageTemplate) {
        self.id = UUID()
        self.index = index
        self.templateRaw = template.rawValue
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    var template: PageTemplate {
        get { PageTemplate(rawValue: templateRaw) ?? .lined }
        set { templateRaw = newValue.rawValue }
    }
}

/// Metadati del disegno vettoriale di una pagina. I tratti (PKDrawing) sono
/// salvati in un file separato, non nel database, per non appesantire il
/// contesto SwiftData e consentire salvataggi incrementali e atomici.
@Model
final class DrawingData {
    @Attribute(.unique) var id: UUID
    /// Percorso relativo alla cartella dei disegni.
    var relativePath: String
    var byteCount: Int
    var strokeCount: Int
    var updatedAt: Date
    var page: NotebookPage?

    init(relativePath: String) {
        self.id = UUID()
        self.relativePath = relativePath
        self.byteCount = 0
        self.strokeCount = 0
        self.updatedAt = Date()
    }
}

enum PageElementKind: String, Codable {
    case text, image
}

/// Elemento composto sulla pagina sotto l'inchiostro: testo digitato o
/// immagine. Coordinate in punti della pagina (indipendenti dallo zoom).
@Model
final class PageElement {
    @Attribute(.unique) var id: UUID
    var kindRaw: String
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var text: String
    var fontSize: Double
    var imageRelativePath: String?
    var zIndex: Int
    var page: NotebookPage?

    init(kind: PageElementKind, frame: CGRect) {
        self.id = UUID()
        self.kindRaw = kind.rawValue
        self.x = frame.origin.x
        self.y = frame.origin.y
        self.width = frame.width
        self.height = frame.height
        self.text = ""
        self.fontSize = 18
        self.imageRelativePath = nil
        self.zIndex = 0
    }

    var kind: PageElementKind { PageElementKind(rawValue: kindRaw) ?? .text }

    var frame: CGRect {
        get { CGRect(x: x, y: y, width: width, height: height) }
        set {
            x = newValue.origin.x
            y = newValue.origin.y
            width = newValue.width
            height = newValue.height
        }
    }
}
