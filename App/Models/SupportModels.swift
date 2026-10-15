import Foundation
import SwiftData
import QuadernoCore

enum MaterialKind: String, Codable, CaseIterable, Identifiable {
    case slides, manual, other
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .slides: return "Slide"
        case .manual: return "Manuale"
        case .other: return "Documento"
        }
    }
}

/// PDF della materia (slide, manuali). Il file e le annotazioni stanno su
/// disco; qui solo i metadati.
@Model
final class PDFMaterial {
    @Attribute(.unique) var id: UUID
    var title: String
    var fileName: String
    var pageCount: Int
    var importedAt: Date
    var updatedAt: Date
    var kindRaw: String
    var lastPageIndex: Int
    var subject: Subject?

    init(title: String, fileName: String, pageCount: Int, kind: MaterialKind = .other) {
        self.id = UUID()
        self.title = title
        self.fileName = fileName
        self.pageCount = pageCount
        self.importedAt = Date()
        self.updatedAt = Date()
        self.kindRaw = kind.rawValue
        self.lastPageIndex = 0
    }

    var kind: MaterialKind {
        get { MaterialKind(rawValue: kindRaw) ?? .other }
        set { kindRaw = newValue.rawValue }
    }
}

/// Lavoro di elaborazione persistente e riprendibile. Usa identificatori
/// invece di relazioni, così l'eliminazione di un contenuto non lascia il
/// lavoro in uno stato incoerente (viene semplicemente annullato).
@Model
final class ProcessingJob {
    @Attribute(.unique) var id: UUID
    var kindRaw: String
    var stateRaw: String
    var createdAt: Date
    var updatedAt: Date
    var recordingID: UUID
    var subjectID: UUID?
    var transcriptID: UUID?
    var resultDocumentID: UUID?
    var modeRaw: String
    var transcriptionProviderID: String
    var transcriptionModel: String
    var generationProviderID: String
    var generationModel: String
    var progress: Double
    var stepDescription: String
    var errorMessage: String?
    var attemptCount: Int
    var nextAttemptAt: Date?
    /// Momento in cui l'utente ha acconsentito all'invio dei dati ai
    /// provider cloud indicati. Nessun lavoro cloud parte senza consenso.
    var consentGivenAt: Date?
    var estimatedCostUSD: Double?

    init(kind: ProcessingJobKind, recordingID: UUID, subjectID: UUID?, mode: SbobinaturaMode, transcriptionProviderID: String, transcriptionModel: String, generationProviderID: String, generationModel: String) {
        self.id = UUID()
        self.kindRaw = kind.rawValue
        self.stateRaw = ProcessingJobState.pending.rawValue
        self.createdAt = Date()
        self.updatedAt = Date()
        self.recordingID = recordingID
        self.subjectID = subjectID
        self.modeRaw = mode.rawValue
        self.transcriptionProviderID = transcriptionProviderID
        self.transcriptionModel = transcriptionModel
        self.generationProviderID = generationProviderID
        self.generationModel = generationModel
        self.progress = 0
        self.stepDescription = ""
        self.attemptCount = 0
    }

    var kind: ProcessingJobKind { ProcessingJobKind(rawValue: kindRaw) ?? .transcriptionAndSbobinatura }

    var state: ProcessingJobState {
        get { ProcessingJobState(rawValue: stateRaw) ?? .failed }
        set {
            guard state.canTransition(to: newValue) else { return }
            stateRaw = newValue.rawValue
            updatedAt = Date()
        }
    }

    var mode: SbobinaturaMode { SbobinaturaMode(rawValue: modeRaw) ?? .integrale }

    var includesTranscription: Bool { kind != .sbobinatura }
    var includesGeneration: Bool { kind != .transcription }
}

enum AIProviderKind: String, Codable {
    case transcription
    case generation
}

/// Configurazione (non segreta) di un provider AI. Le chiavi API stanno
/// esclusivamente nel Keychain.
@Model
final class AIProviderConfiguration {
    @Attribute(.unique) var id: UUID
    var providerID: String
    var kindRaw: String
    var model: String
    var availableModels: [String]
    var lastTestedAt: Date?
    var lastTestSucceeded: Bool
    var lastTestMessage: String?

    init(providerID: String, kind: AIProviderKind, model: String) {
        self.id = UUID()
        self.providerID = providerID
        self.kindRaw = kind.rawValue
        self.model = model
        self.availableModels = []
        self.lastTestSucceeded = false
    }

    var kind: AIProviderKind { AIProviderKind(rawValue: kindRaw) ?? .generation }
}
