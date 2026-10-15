import Foundation

/// Modalità di generazione richieste dall'utente.
public enum SbobinaturaMode: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Predefinita: sbobinatura integrale rielaborata, senza tagli intenzionali.
    case integrale
    case trascrizionePulita
    case riassunto

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .integrale: return "Sbobinatura integrale rielaborata"
        case .trascrizionePulita: return "Trascrizione pulita"
        case .riassunto: return "Riassunto per il ripasso"
        }
    }

    var sectionTemplate: PromptLibrary.Template {
        switch self {
        case .integrale: return .sectionIntegrale
        case .trascrizionePulita: return .sectionPulita
        case .riassunto: return .sectionRiassunto
        }
    }

    /// Rapporto atteso fra caratteri prodotti e caratteri della trascrizione,
    /// usato per stime di costo e per dimensionare `max_tokens`.
    var expectedOutputRatio: Double {
        switch self {
        case .integrale: return 0.95
        case .trascrizionePulita: return 0.9
        case .riassunto: return 0.35
        }
    }
}

/// Metadati della lezione inseriti nei prompt e nell'intestazione.
public struct LessonContext: Codable, Sendable, Equatable {
    public var subjectName: String
    public var lessonTitle: String
    public var lessonDate: Date?
    public var language: String
    public var glossary: [String]
    public var userInstructions: String?

    public init(subjectName: String, lessonTitle: String, lessonDate: Date? = nil, language: String = "italiano", glossary: [String] = [], userInstructions: String? = nil) {
        self.subjectName = subjectName
        self.lessonTitle = lessonTitle
        self.lessonDate = lessonDate
        self.language = language
        self.glossary = glossary
        self.userInstructions = userInstructions
    }
}

public struct OutlineKeyItem: Codable, Sendable, Equatable {
    public var kind: String
    public var text: String

    public init(kind: String, text: String) {
        self.kind = kind
        self.text = text
    }
}

public struct OutlineSection: Codable, Sendable, Equatable {
    public var title: String
    public var firstSegment: Int
    public var lastSegment: Int
    public var summary: String
    public var keyItems: [OutlineKeyItem]

    public init(title: String, firstSegment: Int, lastSegment: Int, summary: String = "", keyItems: [OutlineKeyItem] = []) {
        self.title = title
        self.firstSegment = firstSegment
        self.lastSegment = lastSegment
        self.summary = summary
        self.keyItems = keyItems
    }

    public var segmentRange: ClosedRange<Int> { firstSegment...lastSegment }
}

public struct LessonOutline: Codable, Sendable, Equatable {
    public var lessonTitle: String
    public var sections: [OutlineSection]
    /// Correzioni applicate localmente all'output del modello (buchi,
    /// sovrapposizioni), per trasparenza.
    public var normalizationNotes: [String]

    public init(lessonTitle: String, sections: [OutlineSection], normalizationNotes: [String] = []) {
        self.lessonTitle = lessonTitle
        self.sections = sections
        self.normalizationNotes = normalizationNotes
    }
}

public enum VerificationIssueType: String, Codable, Sendable, CaseIterable {
    case omission
    case alteredValue = "altered_value"
    case dateChanged = "date_changed"
    case nameChanged = "name_changed"
    case unsupportedClaim = "unsupported_claim"
    case wrongCorrection = "wrong_correction"
    case other
    /// Controllo locale euristico (numeri e nomi propri non ritrovati).
    case heuristicMissingFact = "heuristic_missing_fact"

    public var displayName: String {
        switch self {
        case .omission: return "Possibile omissione"
        case .alteredValue: return "Valore modificato"
        case .dateChanged: return "Data modificata"
        case .nameChanged: return "Nome alterato"
        case .unsupportedClaim: return "Affermazione non presente nella lezione"
        case .wrongCorrection: return "Correzione del docente non rispettata"
        case .other: return "Altro problema di fedeltà"
        case .heuristicMissingFact: return "Dato non ritrovato (controllo automatico)"
        }
    }
}

public enum VerificationSeverity: String, Codable, Sendable, Comparable {
    case low, medium, high

    private var rank: Int {
        switch self {
        case .low: return 0
        case .medium: return 1
        case .high: return 2
        }
    }

    public static func < (lhs: VerificationSeverity, rhs: VerificationSeverity) -> Bool { lhs.rank < rhs.rank }
}

public struct VerificationIssue: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var type: VerificationIssueType
    public var severity: VerificationSeverity
    public var description: String
    public var sourceSegments: [Int]
    public var excerpt: String
    /// `true` se una passata di correzione automatica ha tentato di
    /// risolverlo (va comunque ricontrollato dall'utente).
    public var repairAttempted: Bool

    public init(id: UUID = UUID(), type: VerificationIssueType, severity: VerificationSeverity, description: String, sourceSegments: [Int] = [], excerpt: String = "", repairAttempted: Bool = false) {
        self.id = id
        self.type = type
        self.severity = severity
        self.description = description
        self.sourceSegments = sourceSegments
        self.excerpt = excerpt
        self.repairAttempted = repairAttempted
    }
}

public enum VerificationStatus: String, Codable, Sendable {
    /// Nessun problema rilevato (non è una garanzia di completezza).
    case noIssuesFound
    case issuesFound
    case repairedNeedsReview
    case notVerified
    case failed
}

public struct SectionVerification: Codable, Sendable, Equatable {
    public var status: VerificationStatus
    public var issues: [VerificationIssue]
    public var unverifiable: [String]
    public var sourceWordCount: Int
    public var outputWordCount: Int

    public init(status: VerificationStatus, issues: [VerificationIssue] = [], unverifiable: [String] = [], sourceWordCount: Int = 0, outputWordCount: Int = 0) {
        self.status = status
        self.issues = issues
        self.unverifiable = unverifiable
        self.sourceWordCount = sourceWordCount
        self.outputWordCount = outputWordCount
    }

    /// Rapporto parole prodotte / parole della trascrizione: un valore molto
    /// basso in modalità integrale indica una compressione sospetta.
    public var lengthRatio: Double {
        sourceWordCount == 0 ? 0 : Double(outputWordCount) / Double(sourceWordCount)
    }
}

public enum SectionGenerationState: String, Codable, Sendable {
    case generated
    case failed
}

/// Sezione generata, come prodotta dal motore (prima del salvataggio nel
/// database dell'app).
public struct GeneratedSectionDTO: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var order: Int
    public var title: String
    public var markdown: String
    public var segmentRange: ClosedRange<Int>
    public var timeRange: ClosedRange<TimeInterval>
    public var state: SectionGenerationState
    public var errorMessage: String?
    public var verification: SectionVerification
    public var model: String
    public var promptVersion: String
    public var usage: GenerationUsage

    public init(id: UUID = UUID(), order: Int, title: String, markdown: String, segmentRange: ClosedRange<Int>, timeRange: ClosedRange<TimeInterval>, state: SectionGenerationState, errorMessage: String? = nil, verification: SectionVerification, model: String, promptVersion: String, usage: GenerationUsage) {
        self.id = id
        self.order = order
        self.title = title
        self.markdown = markdown
        self.segmentRange = segmentRange
        self.timeRange = timeRange
        self.state = state
        self.errorMessage = errorMessage
        self.verification = verification
        self.model = model
        self.promptVersion = promptVersion
        self.usage = usage
    }
}

public struct GeneratedDocumentDTO: Codable, Sendable, Equatable {
    public var title: String
    public var mode: SbobinaturaMode
    public var headerMarkdown: String
    public var sections: [GeneratedSectionDTO]
    public var outline: LessonOutline
    public var promptVersion: String
    public var providerID: String
    public var model: String
    public var usage: GenerationUsage
    public var createdAt: Date

    public init(title: String, mode: SbobinaturaMode, headerMarkdown: String, sections: [GeneratedSectionDTO], outline: LessonOutline, promptVersion: String, providerID: String, model: String, usage: GenerationUsage, createdAt: Date = Date()) {
        self.title = title
        self.mode = mode
        self.headerMarkdown = headerMarkdown
        self.sections = sections
        self.outline = outline
        self.promptVersion = promptVersion
        self.providerID = providerID
        self.model = model
        self.usage = usage
        self.createdAt = createdAt
    }

    public var markdown: String {
        ([headerMarkdown] + sections.sorted { $0.order < $1.order }.map(\.markdown)).joined(separator: "\n\n")
    }

    public var hasFailures: Bool { sections.contains { $0.state == .failed } }
}

public struct SbobinaturaProgress: Sendable, Equatable {
    public enum Phase: String, Sendable {
        case preparing, analyzing, writing, verifying, repairing, assembling, completed
    }
    public var phase: Phase
    public var currentSection: Int
    public var totalSections: Int
    public var detail: String

    public init(phase: Phase, currentSection: Int = 0, totalSections: Int = 0, detail: String = "") {
        self.phase = phase
        self.currentSection = currentSection
        self.totalSections = totalSections
        self.detail = detail
    }

    /// Frazione approssimativa del lavoro completato.
    public var fraction: Double {
        switch phase {
        case .preparing: return 0.01
        case .analyzing: return 0.05
        case .writing, .verifying, .repairing:
            guard totalSections > 0 else { return 0.1 }
            return 0.1 + 0.85 * Double(currentSection) / Double(totalSections)
        case .assembling: return 0.97
        case .completed: return 1
        }
    }
}
