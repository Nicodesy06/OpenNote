import PencilKit
import SwiftData
import XCTest
import QuadernoCore
@testable import QuadernoAI

@MainActor
final class PersistenceTests: XCTestCase {
    var env: TestEnvironment!

    override func setUp() async throws {
        env = try TestEnvironment()
    }

    override func tearDown() async throws {
        env.cleanup()
    }

    func testCreateEditArchiveAndDeleteSubject() throws {
        let subject = env.content.createSubject(name: "Storia del Design", colorHex: "#3B6FD8", iconName: "paintpalette")
        XCTAssertNotNil(subject.glossary)
        subject.name = "Storia del Design I"
        env.content.archive(subject, archived: true)
        let archived = try env.context.fetch(FetchDescriptor<Subject>(predicate: #Predicate { $0.archivedAt != nil }))
        XCTAssertEqual(archived.map(\.name), ["Storia del Design I"])
        env.content.archive(subject, archived: false)
        XCTAssertNil(subject.archivedAt)

        let notebook = env.content.createNotebook(in: subject, title: "Lezioni", colorHex: "#E5484D", template: .grid)
        XCTAssertEqual(notebook.pages.count, 1)
        env.content.delete(subject)
        XCTAssertEqual(try env.context.fetchCount(FetchDescriptor<Subject>()), 0)
        XCTAssertEqual(try env.context.fetchCount(FetchDescriptor<Notebook>()), 0, "Cascade su quaderni")
        XCTAssertEqual(try env.context.fetchCount(FetchDescriptor<NotebookPage>()), 0, "Cascade su pagine")
    }

    func testPageInsertDuplicateMoveDelete() throws {
        let notebook = env.content.createNotebook(in: nil, title: "Q", colorHex: "#000000", template: .lined)
        let first = notebook.orderedPages[0]
        env.content.insertPage(in: notebook, at: 1, template: .dotted)
        env.content.insertPage(in: notebook, at: 0, template: .blank)
        XCTAssertEqual(notebook.orderedPages.map(\.template), [.blank, .lined, .dotted])
        XCTAssertEqual(notebook.orderedPages.map(\.index), [0, 1, 2])

        // Duplicazione con disegno.
        var drawing = PKDrawing()
        drawing.strokes.append(Self.stroke())
        let path = DrawingStore.relativePath(notebookID: notebook.id, pageID: first.id)
        try env.drawingStore.saveSynchronously(drawing, relativePath: path)
        let data = DrawingData(relativePath: path)
        data.page = first
        env.context.insert(data)
        let copy = try XCTUnwrap(env.content.duplicatePage(first))
        XCTAssertEqual(copy.index, first.index + 1)
        XCTAssertNotNil(copy.drawing)
        XCTAssertNotEqual(copy.drawing?.relativePath, first.drawing?.relativePath)
        XCTAssertTrue(env.fileStore.fileExists(env.fileStore.drawingURL(relativePath: copy.drawing!.relativePath)))

        env.content.movePage(in: notebook, from: IndexSet(integer: 0), to: 4)
        XCTAssertEqual(notebook.orderedPages.map(\.index), Array(0..<4))
        XCTAssertEqual(notebook.orderedPages.last?.template, .blank)

        env.content.deletePage(notebook.orderedPages[0])
        XCTAssertEqual(notebook.pages.count, 3)
        XCTAssertEqual(notebook.orderedPages.map(\.index), [0, 1, 2])
    }

    func testLastPageCannotBeDeleted() {
        let notebook = env.content.createNotebook(in: nil, title: "Q", colorHex: "#000000", template: .lined)
        env.content.deletePage(notebook.orderedPages[0])
        XCTAssertEqual(notebook.pages.count, 1)
    }

    func testDrawingVectorDataRoundTrip() async throws {
        var drawing = PKDrawing()
        drawing.strokes.append(Self.stroke())
        drawing.strokes.append(Self.stroke(offset: 100))
        let path = "nb/page.drawing"
        try env.drawingStore.saveSynchronously(drawing, relativePath: path)
        // Nuovo store (cache vuota): lettura dal file su disco.
        let freshStore = DrawingStore(fileStore: env.fileStore)
        let loaded = await freshStore.load(relativePath: path)
        XCTAssertEqual(loaded.strokes.count, 2, "I tratti vettoriali sopravvivono alla riapertura")
        XCTAssertEqual(loaded.bounds.width, drawing.bounds.width, accuracy: 0.5)
        XCTAssertEqual(loaded.strokes[0].path.count, drawing.strokes[0].path.count)
    }

    func testMoveRecordingCarriesDocuments() throws {
        let a = env.content.createSubject(name: "A", colorHex: "#111111", iconName: "book")
        let b = env.content.createSubject(name: "B", colorHex: "#222222", iconName: "book")
        let recording = AudioRecording(title: "Lezione", source: .recorded, status: .ready)
        recording.subject = a
        env.context.insert(recording)
        let document = GeneratedDocument(title: "Sbob", mode: .integrale, providerID: "x", model: "m", promptVersion: "v")
        document.subject = a
        document.recording = recording
        env.context.insert(document)
        env.content.move(recording, to: b)
        XCTAssertEqual(recording.subject?.name, "B")
        XCTAssertEqual(document.subject?.name, "B")
    }

    func testDeletingRecordingKeepsDocumentsUnlessRequested() throws {
        let recording = AudioRecording(title: "Lezione", source: .recorded, status: .ready)
        env.context.insert(recording)
        let document = GeneratedDocument(title: "Sbob", mode: .integrale, providerID: "x", model: "m", promptVersion: "v")
        document.recording = recording
        env.context.insert(document)
        try env.context.save()
        env.content.delete(recording, deleteDocuments: false)
        let documents = try env.context.fetch(FetchDescriptor<GeneratedDocument>())
        XCTAssertEqual(documents.count, 1, "La sbobinatura resta")
        XCTAssertNil(documents.first?.recording)
    }

    func testJobStateTransitionsArePersistedAndGuarded() throws {
        let job = ProcessingJob(kind: .transcriptionAndSbobinatura, recordingID: UUID(), subjectID: nil, mode: .integrale, transcriptionProviderID: "openai", transcriptionModel: "gpt-transcribe", generationProviderID: "anthropic", generationModel: "claude-opus-5-5")
        env.context.insert(job)
        job.state = .transcribing
        job.state = .cancelled
        job.state = .completed
        XCTAssertEqual(job.state, .cancelled, "Un lavoro annullato non può diventare completato")
    }

    static func stroke(offset: CGFloat = 0) -> PKStroke {
        let points = (0..<20).map { index in
            PKStrokePoint(location: CGPoint(x: 50 + CGFloat(index) * 10 + offset, y: 80 + offset), timeOffset: TimeInterval(index) * 0.01, size: CGSize(width: 3, height: 3), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: points, creationDate: Date()))
    }
}

@MainActor
final class DocumentModelTests: XCTestCase {
    func testSaveGeneratedDocumentAndVersionRestore() throws {
        let env = try TestEnvironment()
        defer { env.cleanup() }
        let dto = GeneratedDocumentDTO(
            title: "Il Bauhaus",
            mode: .integrale,
            headerMarkdown: "# Il Bauhaus",
            sections: [
                GeneratedSectionDTO(order: 0, title: "Fondazione", markdown: "## Fondazione\n\nTesto. [[S0-S2]]", segmentRange: 0...2, timeRange: 0...90, state: .generated, verification: SectionVerification(status: .noIssuesFound), model: "m", promptVersion: "v", usage: GenerationUsage()),
                GeneratedSectionDTO(order: 1, title: "Dessau", markdown: "## Dessau\n\nAltro. [[S3]]", segmentRange: 3...3, timeRange: 90...120, state: .generated, verification: SectionVerification(status: .issuesFound, issues: [VerificationIssue(type: .omission, severity: .high, description: "x")]), model: "m", promptVersion: "v", usage: GenerationUsage())
            ],
            outline: LessonOutline(lessonTitle: "Il Bauhaus", sections: []),
            promptVersion: "v", providerID: "anthropic", model: "m", usage: GenerationUsage(inputTokens: 10, outputTokens: 5))
        let document = GeneratedDocument(title: dto.title, mode: dto.mode, providerID: dto.providerID, model: dto.model, promptVersion: dto.promptVersion)
        document.headerMarkdown = dto.headerMarkdown
        env.context.insert(document)
        for sectionDTO in dto.sections {
            let section = GeneratedSection(dto: sectionDTO)
            section.document = document
            env.context.insert(section)
        }
        let version = DocumentVersion(reason: "Generazione", snapshot: DocumentSnapshot(document: document))
        version.document = document
        env.context.insert(version)
        try env.context.save()

        XCTAssertEqual(document.issueCount, 1)
        XCTAssertEqual(document.orderedSections.first?.segmentStart, 0)
        XCTAssertTrue(document.markdown.hasPrefix("# Il Bauhaus"))

        // Modifica manuale, poi verifica che la versione conservi l'originale.
        let first = document.orderedSections[0]
        first.markdown = "## Fondazione\n\nTesto modificato a mano."
        first.isUserEdited = true
        let snapshot = try XCTUnwrap(document.versions.first?.snapshot)
        XCTAssertEqual(snapshot.sections.first?.markdown, "## Fondazione\n\nTesto. [[S0-S2]]")
        XCTAssertFalse(snapshot.sections.first?.isUserEdited ?? true)
        document.refreshSearchText()
        XCTAssertTrue(document.searchText.contains("modificato"))
        XCTAssertFalse(document.searchText.contains("[[S"))
    }
}
