import Foundation
import SwiftData

// MARK: - Perché SwiftData
//
// - È il framework di persistenza nativo per SwiftUI su iPadOS 17+, con
//   osservazione automatica dei modelli e query dichiarative (@Query).
// - Supporta schemi versionati e piani di migrazione (VersionedSchema /
//   SchemaMigrationPlan), necessari per far evolvere l'app senza perdere dati.
// - I dati voluminosi (audio, PDF, disegni, immagini) NON stanno nel database:
//   sono file separati gestiti da `FileStore`, con scritture atomiche. Il
//   database contiene solo metadati e testo, così resta piccolo e veloce.
// - Rischio noto: alcune versioni iniziali di iOS 17 avevano bug con
//   relazioni complesse. Le relazioni qui sono semplici (alberi con cascade)
//   e i lavori usano identificatori anziché relazioni.

enum QuadernoSchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        [
            Subject.self,
            SubjectGlossary.self,
            Notebook.self,
            NotebookPage.self,
            DrawingData.self,
            PageElement.self,
            AudioRecording.self,
            AudioSegment.self,
            PageMark.self,
            Transcript.self,
            TranscriptSegment.self,
            GeneratedDocument.self,
            GeneratedSection.self,
            DocumentVersion.self,
            PDFMaterial.self,
            ProcessingJob.self,
            AIProviderConfiguration.self
        ]
    }
}

/// Piano di migrazione. Per una nuova versione dello schema:
/// 1. copiare i modelli modificati in `QuadernoSchemaV2` (come tipi annidati);
/// 2. aggiungere `QuadernoSchemaV2.self` a `schemas`;
/// 3. aggiungere uno stadio `.lightweight` o `.custom` a `stages`;
/// 4. aggiornare `AppModelContainer.currentSchema`.
enum QuadernoMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [QuadernoSchemaV1.self]
    }

    static var stages: [MigrationStage] {
        []
    }
}

enum AppModelContainer {
    static let currentSchema = Schema(versionedSchema: QuadernoSchemaV1.self)

    /// Contenitore persistente nella cartella Application Support dell'app.
    static func make(storeURL: URL) throws -> ModelContainer {
        let configuration = ModelConfiguration("QuadernoAI", schema: currentSchema, url: storeURL, allowsSave: true, cloudKitDatabase: .none)
        return try ModelContainer(for: currentSchema, migrationPlan: QuadernoMigrationPlan.self, configurations: [configuration])
    }

    /// Contenitore in memoria per test e anteprime.
    static func makeInMemory() throws -> ModelContainer {
        let configuration = ModelConfiguration("QuadernoAITest", schema: currentSchema, isStoredInMemoryOnly: true, allowsSave: true, cloudKitDatabase: .none)
        return try ModelContainer(for: currentSchema, migrationPlan: QuadernoMigrationPlan.self, configurations: [configuration])
    }
}
