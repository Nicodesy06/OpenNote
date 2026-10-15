import PencilKit
import SwiftData
import UIKit
import os

/// Modalità dell'editor.
enum NotebookEditorMode: String, CaseIterable, Identifiable {
    case ink
    case text
    case arrange

    var id: String { rawValue }
    var title: String {
        switch self {
        case .ink: return "Penna"
        case .text: return "Testo"
        case .arrange: return "Elementi"
        }
    }
    var systemImage: String {
        switch self {
        case .ink: return "pencil.tip"
        case .text: return "character.textbox"
        case .arrange: return "hand.point.up.left"
        }
    }
}

/// Editor di una pagina del quaderno basato su PencilKit.
///
/// Composizione della pagina (dal basso verso l'alto):
/// 1. carta e modello (righe/quadretti/puntini), vettoriale;
/// 2. elementi (testo digitato e immagini), in coordinate di pagina;
/// 3. inchiostro PencilKit (`PKCanvasView`), dati vettoriali.
///
/// Una sola pagina alla volta è caricata in memoria; il salvataggio dei
/// tratti è differito e avviene fuori dal main thread.
final class NotebookCanvasController: UIViewController, PKCanvasViewDelegate, PKToolPickerObserver {
    /// Dimensione logica della pagina (proporzioni A4).
    static let pageSize = CGSize(width: 768, height: 1086)

    let notebook: Notebook
    private let modelContext: ModelContext
    private let drawingStore: DrawingStore
    private let fileStore: FileStore
    private let logger = Logger(subsystem: "QuadernoAI", category: "NotebookEditor")

    private let canvasView = PKCanvasView()
    private let backgroundLayerView = PageBackgroundView()
    private let elementsContainer = UIView()
    private let toolPicker = PKToolPicker()

    private(set) var currentIndex = 0
    private var currentPage: NotebookPage?
    private var isLoadingPage = false
    private var saveWorkItem: DispatchWorkItem?
    private var drawingDirty = false
    private var didSetInitialZoom = false
    private(set) var mode: NotebookEditorMode = .ink
    private var selectedElementID: UUID?

    var onPageChanged: ((Int, NotebookPage) -> Void)?
    var onDrawingEdited: ((NotebookPage) -> Void)?
    var onUndoStateChanged: ((Bool, Bool) -> Void)?
    var onSaveError: ((String) -> Void)?

    var fingerDrawing = false {
        didSet { canvasView.drawingPolicy = fingerDrawing ? .anyInput : .pencilOnly }
    }

    init(notebook: Notebook, modelContext: ModelContext, drawingStore: DrawingStore, fileStore: FileStore, initialIndex: Int) {
        self.notebook = notebook
        self.modelContext = modelContext
        self.drawingStore = drawingStore
        self.fileStore = fileStore
        self.currentIndex = initialIndex
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) non supportato") }

    // MARK: - Ciclo di vita

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .secondarySystemBackground

        canvasView.delegate = self
        canvasView.backgroundColor = .clear
        canvasView.isOpaque = false
        canvasView.drawingPolicy = fingerDrawing ? .anyInput : .pencilOnly
        canvasView.alwaysBounceVertical = true
        canvasView.contentInsetAdjustmentBehavior = .never
        canvasView.minimumZoomScale = 0.5
        canvasView.maximumZoomScale = 4
        // L'inchiostro è sempre su carta bianca: aspetto chiaro anche in
        // modalità scura, così i colori restano quelli scelti.
        canvasView.overrideUserInterfaceStyle = .light
        canvasView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(canvasView)
        NSLayoutConstraint.activate([
            canvasView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            canvasView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            canvasView.topAnchor.constraint(equalTo: view.topAnchor),
            canvasView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        backgroundLayerView.isUserInteractionEnabled = false
        canvasView.insertSubview(backgroundLayerView, at: 0)

        elementsContainer.bounds = CGRect(origin: .zero, size: Self.pageSize)
        elementsContainer.layer.anchorPoint = .zero
        elementsContainer.layer.position = .zero
        elementsContainer.isUserInteractionEnabled = false
        canvasView.insertSubview(elementsContainer, aboveSubview: backgroundLayerView)
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleElementsTap(_:)))
        elementsContainer.addGestureRecognizer(tap)

        toolPicker.addObserver(canvasView)
        toolPicker.addObserver(self)
        toolPicker.setVisible(true, forFirstResponder: canvasView)

        NotificationCenter.default.addObserver(self, selector: #selector(saveNow), name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(undoStateChanged), name: .NSUndoManagerDidCloseUndoGroup, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(undoStateChanged), name: .NSUndoManagerDidUndoChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(undoStateChanged), name: .NSUndoManagerDidRedoChange, object: nil)

        let pages = notebook.orderedPages
        if pages.isEmpty {
            let page = NotebookPage(index: 0, template: notebook.defaultTemplate)
            page.notebook = notebook
            modelContext.insert(page)
            try? modelContext.save()
        }
        showPage(at: min(currentIndex, max(0, notebook.orderedPages.count - 1)))
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if mode == .ink { canvasView.becomeFirstResponder() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        saveNow()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard canvasView.bounds.width > 0 else { return }
        let fit = fitScale()
        canvasView.minimumZoomScale = fit * 0.5
        canvasView.maximumZoomScale = fit * 4
        if !didSetInitialZoom {
            didSetInitialZoom = true
            canvasView.zoomScale = fit
        }
        updateLayoutForZoom()
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: nil) { _ in
            self.canvasView.zoomScale = self.fitScale()
            self.updateLayoutForZoom()
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func fitScale() -> CGFloat {
        let available = canvasView.bounds.width - 48
        return max(0.3, available / Self.pageSize.width)
    }

    /// Adegua contenuto, sfondo ed elementi allo zoom corrente.
    private func updateLayoutForZoom() {
        let zoom = canvasView.zoomScale
        let scaledSize = CGSize(width: Self.pageSize.width * zoom, height: Self.pageSize.height * zoom)
        canvasView.contentSize = scaledSize
        let horizontalInset = max(24, (canvasView.bounds.width - scaledSize.width) / 2)
        canvasView.contentInset = UIEdgeInsets(top: 24, left: horizontalInset, bottom: 120, right: horizontalInset)
        backgroundLayerView.frame = CGRect(origin: .zero, size: scaledSize)
        backgroundLayerView.zoom = zoom
        // Con anchorPoint in alto a sinistra, la posizione resta l'origine
        // della pagina e la trasformazione scala gli elementi con lo zoom.
        elementsContainer.transform = CGAffineTransform(scaleX: zoom, y: zoom)
        elementsContainer.layer.position = .zero
    }

    // MARK: - Pagine

    var pageCount: Int { notebook.pages.count }

    func showPage(at index: Int) {
        let pages = notebook.orderedPages
        guard pages.indices.contains(index) else { return }
        saveNow()
        let page = pages[index]
        currentIndex = index
        currentPage = page
        notebook.lastOpenedPageIndex = index
        backgroundLayerView.template = page.template
        rebuildElementViews()
        isLoadingPage = true
        let path = page.drawing?.relativePath ?? DrawingStore.relativePath(notebookID: notebook.id, pageID: page.id)
        let pageID = page.id
        Task { @MainActor in
            let drawing = await drawingStore.load(relativePath: path)
            // L'utente potrebbe aver già cambiato pagina.
            guard self.currentPage?.id == pageID else { return }
            self.canvasView.drawing = drawing
            self.canvasView.undoManager?.removeAllActions()
            self.isLoadingPage = false
            self.undoStateChanged()
        }
        onPageChanged?(index, page)
    }

    func nextPage() {
        if currentIndex + 1 < notebook.pages.count {
            showPage(at: currentIndex + 1)
        }
    }

    func previousPage() {
        if currentIndex > 0 { showPage(at: currentIndex - 1) }
    }

    func setTemplate(_ template: PageTemplate) {
        guard let currentPage else { return }
        currentPage.template = template
        currentPage.updatedAt = Date()
        backgroundLayerView.template = template
        try? modelContext.save()
    }

    func reloadCurrentPage() {
        showPage(at: min(currentIndex, max(0, notebook.pages.count - 1)))
    }

    // MARK: - Salvataggio

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard !isLoadingPage, let page = currentPage else { return }
        drawingDirty = true
        onDrawingEdited?(page)
        scheduleSave()
    }

    private func scheduleSave() {
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: item)
    }

    /// Salva il disegno della pagina corrente (se modificato).
    @objc func saveNow() {
        saveWorkItem?.cancel()
        saveWorkItem = nil
        guard drawingDirty, let page = currentPage else { return }
        drawingDirty = false
        let drawing = canvasView.drawing
        let path = page.drawing?.relativePath ?? DrawingStore.relativePath(notebookID: notebook.id, pageID: page.id)
        if page.drawing == nil {
            let data = DrawingData(relativePath: path)
            data.page = page
            modelContext.insert(data)
            page.drawing = data
        }
        drawingStore.save(drawing, relativePath: path) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let info):
                page.drawing?.byteCount = info.bytes
                page.drawing?.strokeCount = info.strokes
                page.drawing?.updatedAt = Date()
                page.updatedAt = Date()
                self.notebook.updatedAt = Date()
            case .failure(let error):
                self.drawingDirty = true
                self.onSaveError?("Salvataggio della pagina non riuscito: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Undo / redo

    func undo() {
        canvasView.undoManager?.undo()
        undoStateChanged()
    }

    func redo() {
        canvasView.undoManager?.redo()
        undoStateChanged()
    }

    @objc private func undoStateChanged() {
        let manager = canvasView.undoManager
        onUndoStateChanged?(manager?.canUndo ?? false, manager?.canRedo ?? false)
    }

    // MARK: - Modalità

    func setMode(_ newMode: NotebookEditorMode) {
        mode = newMode
        switch newMode {
        case .ink:
            selectedElementID = nil
            view.endEditing(true)
            canvasView.drawingGestureRecognizer.isEnabled = true
            elementsContainer.isUserInteractionEnabled = false
            canvasView.insertSubview(elementsContainer, aboveSubview: backgroundLayerView)
            toolPicker.setVisible(true, forFirstResponder: canvasView)
            canvasView.becomeFirstResponder()
        case .text, .arrange:
            canvasView.drawingGestureRecognizer.isEnabled = false
            elementsContainer.isUserInteractionEnabled = true
            canvasView.bringSubviewToFront(elementsContainer)
            toolPicker.setVisible(false, forFirstResponder: canvasView)
        }
        for case let elementView as PageElementView in elementsContainer.subviews {
            elementView.isArranging = newMode == .arrange
            elementView.isTextEditable = newMode != .ink
        }
    }

    // MARK: - Elementi (testo e immagini)

    private func rebuildElementViews() {
        elementsContainer.subviews.forEach { $0.removeFromSuperview() }
        guard let page = currentPage else { return }
        for element in page.elements.sorted(by: { $0.zIndex < $1.zIndex }) {
            elementsContainer.addSubview(makeView(for: element))
        }
    }

    private func makeView(for element: PageElement) -> PageElementView {
        var image: UIImage?
        if element.kind == .image, let path = element.imageRelativePath {
            image = UIImage(contentsOfFile: fileStore.pageImageURL(relativePath: path).path)
        }
        let view = PageElementView(element: element, image: image)
        view.isArranging = mode == .arrange
        view.isTextEditable = mode != .ink
        view.onChange = { [weak self] in
            element.page?.updatedAt = Date()
            self?.notebook.updatedAt = Date()
        }
        view.onDelete = { [weak self, weak view] in
            guard let self else { return }
            if let path = element.imageRelativePath { self.fileStore.removeItemIfExists(self.fileStore.pageImageURL(relativePath: path)) }
            view?.removeFromSuperview()
            self.modelContext.delete(element)
            try? self.modelContext.save()
        }
        return view
    }

    @objc private func handleElementsTap(_ recognizer: UITapGestureRecognizer) {
        guard mode == .text, let page = currentPage else { return }
        let location = recognizer.location(in: elementsContainer)
        // Tocco su un elemento esistente: lo gestisce l'elemento stesso.
        if elementsContainer.subviews.contains(where: { $0.frame.contains(location) }) { return }
        let width: CGFloat = 320
        let frame = CGRect(x: min(location.x, Self.pageSize.width - width - 16), y: location.y - 20, width: width, height: 60)
        let element = PageElement(kind: .text, frame: frame)
        element.zIndex = (page.elements.map(\.zIndex).max() ?? 0) + 1
        element.page = page
        modelContext.insert(element)
        try? modelContext.save()
        let view = makeView(for: element)
        elementsContainer.addSubview(view)
        view.beginEditing()
    }

    /// Inserisce un'immagine al centro della pagina visibile.
    func insertImage(_ image: UIImage) {
        guard let page = currentPage else { return }
        let resized = Self.downscaled(image, maxDimension: 2000)
        guard let data = resized.jpegData(compressionQuality: 0.85) else { return }
        let path = "\(notebook.id.uuidString)/\(UUID().uuidString).jpg"
        do {
            try fileStore.writeAtomically(data, to: fileStore.pageImageURL(relativePath: path))
        } catch {
            onSaveError?("Immagine non salvata: \(error.localizedDescription)")
            return
        }
        let maxWidth = Self.pageSize.width * 0.6
        let scale = min(1, maxWidth / max(resized.size.width, 1))
        let size = CGSize(width: resized.size.width * scale, height: resized.size.height * scale)
        let visible = canvasView.convert(canvasView.bounds, to: elementsContainer).intersection(CGRect(origin: .zero, size: Self.pageSize))
        let center = visible.isNull ? CGPoint(x: Self.pageSize.width / 2, y: Self.pageSize.height / 3) : CGPoint(x: visible.midX, y: visible.midY)
        let element = PageElement(kind: .image, frame: CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height))
        element.imageRelativePath = path
        element.zIndex = (page.elements.map(\.zIndex).max() ?? 0) + 1
        element.page = page
        modelContext.insert(element)
        try? modelContext.save()
        elementsContainer.addSubview(makeView(for: element))
        setMode(.arrange)
    }

    static func downscaled(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let largest = max(image.size.width, image.size.height)
        guard largest > maxDimension else { return image }
        let scale = maxDimension / largest
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
    }

    // MARK: - UIScrollViewDelegate

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        updateLayoutForZoom()
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        // Testo e immagini ri-rasterizzati alla nuova scala per restare nitidi.
        let screenScale = self.view.window?.screen.scale ?? 2
        for case let elementView as PageElementView in elementsContainer.subviews {
            elementView.updateRenderingScale(scale * screenScale)
        }
    }
}

/// Carta e modello della pagina, ridisegnati allo zoom corrente per restare
/// nitidi (nessun bitmap scalato).
final class PageBackgroundView: UIView {
    private let shapeLayer = CAShapeLayer()
    private let marginLayer = CAShapeLayer()

    var template: PageTemplate = .lined { didSet { setNeedsLayout() } }
    var zoom: CGFloat = 1 { didSet { if oldValue != zoom { setNeedsLayout() } } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .white
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.12
        layer.shadowRadius = 10
        layer.shadowOffset = CGSize(width: 0, height: 4)
        layer.addSublayer(shapeLayer)
        layer.addSublayer(marginLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let size = NotebookCanvasController.pageSize
        let path = PageTemplateRenderer.path(for: template, size: size, scale: zoom)
        shapeLayer.frame = bounds
        shapeLayer.path = path.cgPath
        if template == .dotted {
            shapeLayer.fillColor = PageTemplateRenderer.lineColor.withAlphaComponent(0.9).cgColor
            shapeLayer.strokeColor = nil
        } else {
            shapeLayer.fillColor = nil
            shapeLayer.strokeColor = PageTemplateRenderer.lineColor.cgColor
            shapeLayer.lineWidth = max(0.5, 0.6 * zoom)
        }
        if template == .lined {
            let margin = UIBezierPath()
            margin.move(to: CGPoint(x: 72 * zoom, y: 0))
            margin.addLine(to: CGPoint(x: 72 * zoom, y: bounds.height))
            marginLayer.path = margin.cgPath
            marginLayer.strokeColor = PageTemplateRenderer.marginColor.cgColor
            marginLayer.lineWidth = max(0.5, 0.8 * zoom)
            marginLayer.isHidden = false
        } else {
            marginLayer.isHidden = true
        }
        layer.shadowPath = UIBezierPath(rect: bounds).cgPath
        CATransaction.commit()
    }
}
