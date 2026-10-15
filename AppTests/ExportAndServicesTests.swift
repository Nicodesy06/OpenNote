import PDFKit
import PencilKit
import XCTest
import QuadernoCore
@testable import QuadernoAI

@MainActor
final class ExportTests: XCTestCase {
    func testDocumentPDFExportIsPaginatedAndOmitsSegmentMarkers() throws {
        let paragraph = String(repeating: "Il Bauhaus unisce arte e artigianato in una scuola. ", count: 40)
        let markdown = "# Il Bauhaus\n\n" + (1...12).map { "## Sezione \($0)\n\n\(paragraph) [[S\($0)]]" }.joined(separator: "\n\n")
        let data = PDFExporter.exportDocument(markdown: markdown, title: "Il Bauhaus", imageResolver: nil)
        let document = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertGreaterThan(document.pageCount, 3, "Testo lungo su più pagine")
        let text = document.string ?? ""
        XCTAssertTrue(text.contains("Il Bauhaus"))
        XCTAssertFalse(text.contains("[[S"), "Riferimenti interni rimossi")
        XCTAssertTrue(text.contains("Sezione 12"), "Nessun contenuto perso nell'impaginazione")
    }

    func testNotebookPDFExportHasOnePagePerNotebookPage() throws {
        var drawing = PKDrawing()
        drawing.strokes.append(PersistenceTests.stroke())
        let pages: [(template: PageTemplate, drawing: PKDrawing, elements: [PDFExporter.PageElementSnapshot])] = [
            (.lined, drawing, [PDFExporter.PageElementSnapshot(kind: .text, frame: CGRect(x: 100, y: 100, width: 300, height: 60), text: "Appunto digitato", fontSize: 18, imagePath: nil, zIndex: 0)]),
            (.grid, PKDrawing(), []),
            (.dotted, drawing, [])
        ]
        let data = PDFExporter.exportNotebook(pages: pages, pageSize: NotebookCanvasController.pageSize) { _ in nil }
        let document = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertEqual(document.pageCount, 3)
        XCTAssertTrue(document.page(at: 0)?.string?.contains("Appunto digitato") == true)
    }

    func testAnnotatedPDFKeepsPagesAndSize() throws {
        let source = PDFExporter.exportDocument(markdown: "# A\n\n" + String(repeating: "Testo. ", count: 800), title: "A", imageResolver: nil)
        let original = try XCTUnwrap(PDFDocument(data: source))
        var drawing = PKDrawing()
        drawing.strokes.append(PersistenceTests.stroke())
        let exported = PDFExporter.exportAnnotatedPDF(document: original, annotations: [0: (drawing, CGSize(width: 400, height: 566))])
        let result = try XCTUnwrap(PDFDocument(data: exported))
        XCTAssertEqual(result.pageCount, original.pageCount)
        XCTAssertEqual(result.page(at: 0)?.bounds(for: .mediaBox).size, original.page(at: 0)?.bounds(for: .mediaBox).size)
    }

    func testRendererSegmentLinks() {
        let rendered = MarkdownRenderer().render("Testo con riferimento. [[S3-S5]]")
        var found: URL?
        rendered.enumerateAttribute(.link, in: NSRange(location: 0, length: rendered.length)) { value, _, _ in
            if let url = value as? URL { found = url }
        }
        XCTAssertEqual(found.flatMap(MarkdownRenderer.segmentRange), 3...5)
        let printed = MarkdownRenderer(style: .print).render("Testo. [[S3-S5]]")
        XCTAssertFalse(printed.string.contains("▸"), "Nessun riferimento nella stampa")
    }
}

final class KeychainTests: XCTestCase {
    func testSaveReadReplaceDelete() throws {
        let store = KeychainStore(service: "it.quadernoai.tests.\(UUID().uuidString)")
        XCTAssertNil(store.read(account: "openai"))
        try store.save("sk-uno", account: "openai")
        XCTAssertEqual(store.read(account: "openai"), "sk-uno")
        try store.save("sk-due", account: "openai")
        XCTAssertEqual(store.read(account: "openai"), "sk-due")
        try store.delete(account: "openai")
        XCTAssertFalse(store.hasValue(account: "openai"))
    }

    func testKeysAreNeverStoredInUserDefaults() throws {
        let defaults = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        settings.anthropicModel = "claude-opus-5-5"
        let dump = defaults.dictionaryRepresentation().values.map { "\($0)" }.joined()
        XCTAssertFalse(dump.contains("sk-"), "Nessuna chiave nelle preferenze")
    }
}

@MainActor
final class JobRunnerPersistenceTests: XCTestCase {
    func testSavingGeneratedDocumentCreatesSectionsAndInitialVersion() throws {
        let env = try TestEnvironment()
        defer { env.cleanup() }
        let defaults = UserDefaults(suiteName: "jobs-\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        let maintenance = RecordingMaintenance(fileStore: env.fileStore, modelContainer: env.container)
        let runner = JobRunner(modelContainer: env.container, fileStore: env.fileStore, settings: settings, keychain: KeychainStore(service: "tests-\(UUID().uuidString)"), maintenance: maintenance, network: NetworkMonitor())
        let recording = AudioRecording(title: "Lezione 1", source: .recorded, status: .ready)
        env.context.insert(recording)
        let dto = GeneratedDocumentDTO(title: "Titolo", mode: .integrale, headerMarkdown: "# Titolo", sections: [
            GeneratedSectionDTO(order: 0, title: "A", markdown: "## A\n\nTesto [[S0]]", segmentRange: 0...0, timeRange: 0...10, state: .generated, verification: SectionVerification(status: .noIssuesFound), model: "m", promptVersion: "v", usage: GenerationUsage())
        ], outline: LessonOutline(lessonTitle: "Titolo", sections: [OutlineSection(title: "A", firstSegment: 0, lastSegment: 0)]), promptVersion: "v", providerID: "anthropic", model: "m", usage: GenerationUsage(inputTokens: 1, outputTokens: 2))
        let document = runner.save(dto, recording: recording, transcriptID: UUID())
        XCTAssertEqual(document.sections.count, 1)
        XCTAssertEqual(document.versions.count, 1)
        XCTAssertEqual(document.recording?.id, recording.id)
        XCTAssertNotNil(document.outline)
        XCTAssertEqual(document.outputTokens, 2)
    }

    func testEnqueueWithoutConsentFailsWithoutNetworkCalls() async throws {
        let env = try TestEnvironment()
        defer { env.cleanup() }
        let settings = AppSettings(defaults: UserDefaults(suiteName: "jobs-\(UUID().uuidString)")!)
        let runner = JobRunner(modelContainer: env.container, fileStore: env.fileStore, settings: settings, keychain: KeychainStore(service: "tests-\(UUID().uuidString)"), maintenance: RecordingMaintenance(fileStore: env.fileStore, modelContainer: env.container), network: NetworkMonitor())
        let recording = AudioRecording(title: "Lezione", source: .recorded, status: .ready)
        env.context.insert(recording)
        let job = runner.enqueue(kind: .transcription, recording: recording, mode: .integrale, consent: false, estimatedCost: nil)
        // Attende la conclusione del tentativo.
        for _ in 0..<50 where job.state != .failed {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(job.state, .failed)
        XCTAssertTrue(job.errorMessage?.contains("consenso") == true)
    }
}
