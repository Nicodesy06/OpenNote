import Foundation
import SwiftData
import os

/// Creazione, spostamento ed eliminazione dei contenuti, con pulizia
/// coerente dei file su disco. Le eliminazioni passano sempre da qui (e
/// dall'interfaccia con conferma), così nessun file resta orfano e nessun
/// contenuto viene cancellato per errore implicito.
@MainActor
final class ContentManager {
    private let fileStore: FileStore
    private let drawingStore: DrawingStore
    private let modelContainer: ModelContainer
    private let logger = Logger(subsystem: "QuadernoAI", category: "ContentManager")

    init(fileStore: FileStore, drawingStore: DrawingStore, modelContainer: ModelContainer) {
        self.fileStore = fileStore
        self.drawingStore = drawingStore
        self.modelContainer = modelContainer
    }

    private var context: ModelContext { modelContainer.mainContext }

    func save() {
        do {
            try context.save()
        } catch {
            logger.error("Salvataggio non riuscito: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Materie

    @discardableResult
    func createSubject(name: String, colorHex: String, iconName: String) -> Subject {
        let count = (try? context.fetchCount(FetchDescriptor<Subject>())) ?? 0
        let subject = Subject(name: name, colorHex: colorHex, iconName: iconName, sortIndex: count)
        subject.glossary = SubjectGlossary()
        context.insert(subject)
        save()
        return subject
    }

    func archive(_ subject: Subject, archived: Bool) {
        subject.archivedAt = archived ? Date() : nil
        subject.updatedAt = Date()
        save()
    }

    func delete(_ subject: Subject) {
        for notebook in subject.notebooks { deleteFiles(of: notebook) }
        for recording in subject.recordings { deleteFiles(of: recording) }
        for material in subject.materials { deleteFiles(of: material) }
        for document in subject.documents { deleteFiles(of: document) }
        context.delete(subject)
        save()
    }

    // MARK: - Quaderni

    @discardableResult
    func createNotebook(in subject: Subject?, title: String, colorHex: String, template: PageTemplate) -> Notebook {
        let notebook = Notebook(title: title, coverColorHex: colorHex, template: template)
        notebook.subject = subject
        context.insert(notebook)
        let page = NotebookPage(index: 0, template: template)
        page.notebook = notebook
        context.insert(page)
        save()
        return notebook
    }

    @discardableResult
    func insertPage(in notebook: Notebook, at index: Int, template: PageTemplate? = nil) -> NotebookPage {
        for page in notebook.pages where page.index >= index { page.index += 1 }
        let page = NotebookPage(index: index, template: template ?? notebook.defaultTemplate)
        page.notebook = notebook
        context.insert(page)
        notebook.updatedAt = Date()
        save()
        return page
    }

    @discardableResult
    func duplicatePage(_ page: NotebookPage) -> NotebookPage? {
        guard let notebook = page.notebook else { return nil }
        let copy = insertPage(in: notebook, at: page.index + 1, template: page.template)
        if let drawing = page.drawing {
            let path = DrawingStore.relativePath(notebookID: notebook.id, pageID: copy.id)
            drawingStore.copy(from: drawing.relativePath, to: path)
            let data = DrawingData(relativePath: path)
            data.byteCount = drawing.byteCount
            data.strokeCount = drawing.strokeCount
            data.page = copy
            context.insert(data)
        }
        for element in page.elements {
            let duplicate = PageElement(kind: element.kind, frame: element.frame)
            duplicate.text = element.text
            duplicate.fontSize = element.fontSize
            duplicate.zIndex = element.zIndex
            if let image = element.imageRelativePath {
                let newPath = "\(notebook.id.uuidString)/\(UUID().uuidString).jpg"
                try? fileStore.copyFile(from: fileStore.pageImageURL(relativePath: image), to: fileStore.pageImageURL(relativePath: newPath))
                duplicate.imageRelativePath = newPath
            }
            duplicate.page = copy
            context.insert(duplicate)
        }
        save()
        return copy
    }

    func deletePage(_ page: NotebookPage) {
        guard let notebook = page.notebook, notebook.pages.count > 1 else { return }
        if let drawing = page.drawing { drawingStore.delete(relativePath: drawing.relativePath) }
        for element in page.elements {
            if let image = element.imageRelativePath { fileStore.removeItemIfExists(fileStore.pageImageURL(relativePath: image)) }
        }
        let removedIndex = page.index
        context.delete(page)
        for other in notebook.pages where other.index > removedIndex { other.index -= 1 }
        notebook.updatedAt = Date()
        save()
    }

    func movePage(in notebook: Notebook, from source: IndexSet, to destination: Int) {
        var pages = notebook.orderedPages
        pages.move(fromOffsets: source, toOffset: destination)
        for (index, page) in pages.enumerated() { page.index = index }
        notebook.updatedAt = Date()
        save()
    }

    func delete(_ notebook: Notebook) {
        deleteFiles(of: notebook)
        context.delete(notebook)
        save()
    }

    private func deleteFiles(of notebook: Notebook) {
        drawingStore.deleteNotebook(notebook.id)
        fileStore.removeItemIfExists(fileStore.pageImagesDirectory.appendingPathComponent(notebook.id.uuidString))
    }

    // MARK: - Registrazioni

    /// - Parameter deleteDocuments: se `true` elimina anche le sbobinature
    ///   generate da questa registrazione; altrimenti restano, scollegate.
    func delete(_ recording: AudioRecording, deleteDocuments: Bool) {
        if deleteDocuments {
            for document in recording.documents {
                deleteFiles(of: document)
                context.delete(document)
            }
        }
        cancelJobs(for: recording.id)
        deleteFiles(of: recording)
        context.delete(recording)
        save()
    }

    private func deleteFiles(of recording: AudioRecording) {
        fileStore.removeItemIfExists(fileStore.recordingsDirectory.appendingPathComponent(recording.id.uuidString))
    }

    private func cancelJobs(for recordingID: UUID) {
        let jobs = (try? context.fetch(FetchDescriptor<ProcessingJob>(predicate: #Predicate { $0.recordingID == recordingID }))) ?? []
        for job in jobs where !job.state.isTerminal {
            job.state = .cancelled
            job.errorMessage = "Registrazione eliminata"
        }
    }

    func move(_ recording: AudioRecording, to subject: Subject?) {
        recording.subject = subject
        // Le sbobinature collegate seguono la registrazione.
        for document in recording.documents { document.subject = subject }
        save()
    }

    func move(_ notebook: Notebook, to subject: Subject?) {
        notebook.subject = subject
        save()
    }

    func move(_ document: GeneratedDocument, to subject: Subject?) {
        document.subject = subject
        save()
    }

    func move(_ material: PDFMaterial, to subject: Subject?) {
        material.subject = subject
        save()
    }

    // MARK: - Documenti e materiali

    func delete(_ document: GeneratedDocument) {
        deleteFiles(of: document)
        context.delete(document)
        save()
    }

    private func deleteFiles(of document: GeneratedDocument) {
        fileStore.removeItemIfExists(fileStore.documentImagesDirectory.appendingPathComponent(document.id.uuidString))
    }

    func delete(_ material: PDFMaterial) {
        deleteFiles(of: material)
        context.delete(material)
        save()
    }

    private func deleteFiles(of material: PDFMaterial) {
        fileStore.removeItemIfExists(fileStore.materialURL(fileName: material.fileName))
        fileStore.removeItemIfExists(fileStore.materialsDirectory.appendingPathComponent("Annotations-\(material.id.uuidString)"))
    }

    func delete(_ transcript: Transcript) {
        context.delete(transcript)
        save()
    }
}
