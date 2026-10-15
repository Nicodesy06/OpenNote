import PDFKit
import PencilKit
import SwiftUI
import os

/// Lettura e annotazione dei PDF con Apple Pencil. Ogni pagina ha una tela
/// PencilKit sovrapposta (PDFPageOverlayViewProvider); i disegni vengono
/// salvati per pagina insieme alla dimensione della tela, così da riportarli
/// esattamente alle coordinate della pagina in esportazione.
struct PDFMaterialView: View {
    @Bindable var material: PDFMaterial
    @Environment(\.dismiss) private var dismiss
    @Environment(AppServices.self) private var services
    @State private var reference = PDFControllerReference()
    @State private var annotating = false
    @State private var exported: ExportedFile?
    @State private var errorMessage: String?
    @State private var pageLabel = ""

    var body: some View {
        NavigationStack {
            PDFAnnotationRepresentable(material: material, reference: reference, annotating: annotating) { label in
                pageLabel = label
            }
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle(material.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        reference.controller?.saveAll()
                        dismiss()
                    } label: {
                        Label("Chiudi", systemImage: "chevron.down")
                    }
                }
                ToolbarItem(placement: .principal) {
                    Text(pageLabel).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Toggle(isOn: $annotating) {
                        Label("Annota", systemImage: "pencil.tip.crop.circle")
                    }
                    .toggleStyle(.button)
                    Button {
                        export()
                    } label: {
                        Label("Esporta con annotazioni", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        .sheet(item: $exported) { file in ShareSheet(items: [file.url]) }
        .alert("Errore", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func export() {
        guard let controller = reference.controller else { return }
        controller.saveAll()
        guard let document = PDFDocument(url: services.fileStore.materialURL(fileName: material.fileName)) else {
            errorMessage = "PDF non leggibile."
            return
        }
        let annotations = controller.loadAllAnnotations(pageCount: document.pageCount)
        let data = PDFExporter.exportAnnotatedPDF(document: document, annotations: annotations)
        let url = services.fileStore.newExportURL(fileName: "\(material.title) (annotato).pdf")
        do {
            try data.write(to: url, options: .atomic)
            exported = ExportedFile(url: url)
        } catch {
            errorMessage = "Esportazione non riuscita: \(error.localizedDescription)"
        }
    }
}

@MainActor
final class PDFControllerReference {
    weak var controller: PDFAnnotationController?
}

struct PDFAnnotationRepresentable: UIViewControllerRepresentable {
    let material: PDFMaterial
    let reference: PDFControllerReference
    let annotating: Bool
    let onPageLabel: (String) -> Void
    @Environment(AppServices.self) private var services

    func makeUIViewController(context: Context) -> PDFAnnotationController {
        let controller = PDFAnnotationController(material: material, fileStore: services.fileStore)
        controller.onPageLabel = onPageLabel
        reference.controller = controller
        return controller
    }

    func updateUIViewController(_ controller: PDFAnnotationController, context: Context) {
        controller.setAnnotating(annotating)
    }

    static func dismantleUIViewController(_ controller: PDFAnnotationController, coordinator: ()) {
        controller.saveAll()
    }
}

final class PDFAnnotationController: UIViewController, PDFPageOverlayViewProvider, PKCanvasViewDelegate {
    private struct CanvasMetadata: Codable {
        var width: Double
        var height: Double
    }

    let material: PDFMaterial
    private let fileStore: FileStore
    private let pdfView = PDFView()
    private let toolPicker = PKToolPicker()
    private var canvases: [Int: PKCanvasView] = [:]
    private var dirtyPages = Set<Int>()
    private var annotating = false
    private let logger = Logger(subsystem: "QuadernoAI", category: "PDFAnnotation")
    var onPageLabel: ((String) -> Void)?

    init(material: PDFMaterial, fileStore: FileStore) {
        self.material = material
        self.fileStore = fileStore
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var annotationsDirectory: URL { fileStore.materialAnnotationsDirectory(material.id) }

    override func viewDidLoad() {
        super.viewDidLoad()
        pdfView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(pdfView)
        NSLayoutConstraint.activate([
            pdfView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pdfView.topAnchor.constraint(equalTo: view.topAnchor),
            pdfView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.pageShadowsEnabled = true
        pdfView.backgroundColor = .secondarySystemBackground
        pdfView.pageOverlayViewProvider = self
        pdfView.document = PDFDocument(url: fileStore.materialURL(fileName: material.fileName))
        if let page = pdfView.document?.page(at: min(material.lastPageIndex, max(0, (pdfView.document?.pageCount ?? 1) - 1))) {
            pdfView.go(to: page)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(pageChanged), name: .PDFViewPageChanged, object: pdfView)
        NotificationCenter.default.addObserver(self, selector: #selector(saveAll), name: UIApplication.willResignActiveNotification, object: nil)
        pageChanged()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func pageChanged() {
        guard let document = pdfView.document, let page = pdfView.currentPage else { return }
        let index = document.index(for: page)
        material.lastPageIndex = index
        onPageLabel?("Pagina \(index + 1) di \(document.pageCount)")
    }

    func setAnnotating(_ value: Bool) {
        guard value != annotating else { return }
        annotating = value
        // In modalità markup PDFView cede i gesti alle tele PencilKit.
        pdfView.isInMarkupMode = value
        for canvas in canvases.values {
            canvas.isUserInteractionEnabled = value
            canvas.drawingGestureRecognizer.isEnabled = value
        }
        if value, let canvas = currentCanvas() {
            toolPicker.setVisible(true, forFirstResponder: canvas)
            canvas.becomeFirstResponder()
        } else {
            canvases.values.forEach { toolPicker.setVisible(false, forFirstResponder: $0) }
            saveAll()
        }
    }

    private func currentCanvas() -> PKCanvasView? {
        guard let document = pdfView.document, let page = pdfView.currentPage else { return nil }
        return canvases[document.index(for: page)]
    }

    // MARK: - PDFPageOverlayViewProvider

    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> UIView? {
        guard let document = view.document else { return nil }
        let index = document.index(for: page)
        if let existing = canvases[index] { return existing }
        let canvas = PKCanvasView()
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.drawingPolicy = .pencilOnly
        canvas.isScrollEnabled = false
        canvas.overrideUserInterfaceStyle = .light
        canvas.delegate = self
        canvas.tag = index
        canvas.isUserInteractionEnabled = annotating
        canvas.drawingGestureRecognizer.isEnabled = annotating
        toolPicker.addObserver(canvas)
        canvases[index] = canvas
        return canvas
    }

    func pdfView(_ pdfView: PDFView, willDisplayOverlayView overlayView: UIView, for page: PDFPage) {
        guard let canvas = overlayView as? PKCanvasView, let document = pdfView.document else { return }
        let index = document.index(for: page)
        if let annotation = loadAnnotation(index: index) {
            let (drawing, size) = annotation
            // Se la tela ha ora una dimensione diversa, il disegno viene
            // scalato per restare allineato alla pagina.
            let bounds = overlayView.bounds.size
            if size.width > 0, bounds.width > 0, abs(bounds.width - size.width) > 0.5 {
                let scale = bounds.width / size.width
                canvas.drawing = drawing.transformed(using: CGAffineTransform(scaleX: scale, y: scale))
            } else {
                canvas.drawing = drawing
            }
        }
        if annotating, index == document.index(for: pdfView.currentPage ?? page) {
            toolPicker.setVisible(true, forFirstResponder: canvas)
            canvas.becomeFirstResponder()
        }
    }

    func pdfView(_ pdfView: PDFView, willEndDisplayingOverlayView overlayView: UIView, for page: PDFPage) {
        guard let canvas = overlayView as? PKCanvasView else { return }
        save(canvas: canvas, index: canvas.tag)
        canvases.removeValue(forKey: canvas.tag)
    }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        dirtyPages.insert(canvasView.tag)
    }

    // MARK: - Persistenza

    private func drawingURL(_ index: Int) -> URL { annotationsDirectory.appendingPathComponent("page-\(index).drawing") }
    private func metadataURL(_ index: Int) -> URL { annotationsDirectory.appendingPathComponent("page-\(index).json") }

    private func save(canvas: PKCanvasView, index: Int) {
        guard dirtyPages.contains(index) else { return }
        dirtyPages.remove(index)
        do {
            try fileStore.writeAtomically(canvas.drawing.dataRepresentation(), to: drawingURL(index))
            let metadata = CanvasMetadata(width: canvas.bounds.width, height: canvas.bounds.height)
            try fileStore.writeAtomically(try JSONEncoder().encode(metadata), to: metadataURL(index))
            material.updatedAt = Date()
        } catch {
            dirtyPages.insert(index)
            logger.error("Annotazione non salvata: \(error.localizedDescription, privacy: .public)")
        }
    }

    @objc func saveAll() {
        for (index, canvas) in canvases { save(canvas: canvas, index: index) }
    }

    private func loadAnnotation(index: Int) -> (PKDrawing, CGSize)? {
        guard let data = try? Data(contentsOf: drawingURL(index)), let drawing = try? PKDrawing(data: data) else { return nil }
        var size = CGSize.zero
        if let metaData = try? Data(contentsOf: metadataURL(index)), let metadata = try? JSONDecoder().decode(CanvasMetadata.self, from: metaData) {
            size = CGSize(width: metadata.width, height: metadata.height)
        }
        return (drawing, size)
    }

    func loadAllAnnotations(pageCount: Int) -> [Int: (drawing: PKDrawing, canvasSize: CGSize)] {
        var result: [Int: (drawing: PKDrawing, canvasSize: CGSize)] = [:]
        for index in 0..<pageCount {
            if let annotation = loadAnnotation(index: index), !annotation.0.strokes.isEmpty {
                result[index] = (annotation.0, annotation.1)
            }
        }
        return result
    }
}
