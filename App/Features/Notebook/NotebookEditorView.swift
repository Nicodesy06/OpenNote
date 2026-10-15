import PencilKit
import PhotosUI
import SwiftData
import SwiftUI

/// Riferimento al controller UIKit per i comandi della barra strumenti.
@MainActor
final class NotebookControllerReference {
    weak var controller: NotebookCanvasController?
}

/// Editor a schermo intero di un quaderno. La registrazione, se attiva,
/// continua indipendentemente da questa vista.
struct NotebookEditorView: View {
    @Bindable var notebook: Notebook
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(AppServices.self) private var services
    @Environment(RecordingService.self) private var recorder
    @EnvironmentObject private var settings: AppSettings
    @State private var reference = NotebookControllerReference()
    @State private var currentIndex = 0
    @State private var mode = NotebookEditorMode.ink
    @State private var canUndo = false
    @State private var canRedo = false
    @State private var showPages = false
    @State private var showStartRecording = false
    @State private var photoItem: PhotosPickerItem?
    @State private var exported: ExportedFile?
    @State private var isExporting = false
    @State private var errorMessage: String?
    @State private var postRecordingID: UUID?
    @State private var generateFor: AudioRecording?
    @State private var renaming = false

    var body: some View {
        NavigationStack {
            NotebookCanvasRepresentable(notebook: notebook, reference: reference, initialIndex: notebook.lastOpenedPageIndex, fingerDrawing: settings.fingerDrawing) { index, page in
                currentIndex = index
                recorder.markPage(pageID: page.id, pageIndex: index, kind: .visited)
            } onEdited: { page in
                recorder.markPage(pageID: page.id, pageIndex: page.index, kind: .edited)
            } onUndoState: { undo, redo in
                canUndo = undo
                canRedo = redo
            } onError: { message in
                errorMessage = message
            }
            .ignoresSafeArea(edges: .bottom)
            .overlay(alignment: .bottom) { pageControls }
            .safeAreaInset(edge: .top, spacing: 0) {
                if recorder.state.isActive {
                    RecordingBanner(compact: true)
                        .padding(.horizontal)
                        .padding(.vertical, 4)
                }
            }
            .navigationTitle(notebook.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
        }
        .onAppear { services.isEditorPresented = true }
        .onDisappear {
            reference.controller?.saveNow()
            try? modelContext.save()
            services.isEditorPresented = false
        }
        .onChange(of: settings.fingerDrawing) { _, value in reference.controller?.fingerDrawing = value }
        .onChange(of: mode) { _, value in reference.controller?.setMode(value) }
        .onChange(of: photoItem) { _, item in loadPhoto(item) }
        .onChange(of: recorder.lastFinishedRecordingID) { _, id in
            if id != nil { postRecordingID = id }
        }
        .sheet(isPresented: $showPages) {
            PagesSheet(notebook: notebook, currentIndex: currentIndex) { index in
                reference.controller?.showPage(at: index)
            } onChanged: {
                reference.controller?.reloadCurrentPage()
            }
        }
        .sheet(isPresented: $showStartRecording) {
            StartRecordingSheet(subject: notebook.subject, notebook: notebook)
        }
        .sheet(item: $exported) { file in ShareSheet(items: [file.url]) }
        .sheet(item: $generateFor) { recording in GenerateSheet(recording: recording) }
        .alert("Registrazione salvata", isPresented: Binding(get: { postRecordingID != nil }, set: { if !$0 { postRecordingID = nil } })) {
            Button("Trascrivi e crea sbobinatura") {
                if let id = postRecordingID {
                    generateFor = try? modelContext.fetch(FetchDescriptor<AudioRecording>(predicate: #Predicate { $0.id == id })).first
                }
                postRecordingID = nil
            }
            Button("Più tardi", role: .cancel) { postRecordingID = nil }
        } message: {
            Text("La registrazione è collegata a questo quaderno, con i riferimenti alle pagine visitate durante la lezione.")
        }
        .alert("Attenzione", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .renameAlert(isPresented: $renaming, initial: notebook.title) { title in
            notebook.title = title
            try? modelContext.save()
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button {
                dismiss()
            } label: {
                Label("Chiudi", systemImage: "chevron.down")
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Picker("Modalità", selection: $mode) {
                ForEach(NotebookEditorMode.allCases) { mode in
                    Label(mode.title, systemImage: mode.systemImage).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 220)

            Button {
                reference.controller?.undo()
            } label: {
                Label("Annulla", systemImage: "arrow.uturn.backward")
            }
            .disabled(!canUndo)
            Button {
                reference.controller?.redo()
            } label: {
                Label("Ripristina", systemImage: "arrow.uturn.forward")
            }
            .disabled(!canRedo)

            PhotosPicker(selection: $photoItem, matching: .images) {
                Label("Inserisci immagine", systemImage: "photo.badge.plus")
            }

            Button {
                showPages = true
            } label: {
                Label("Pagine", systemImage: "square.grid.2x2")
            }

            if !recorder.state.isActive {
                Button {
                    showStartRecording = true
                } label: {
                    Label("Registra lezione", systemImage: "record.circle")
                }
                .tint(.red)
            }

            Menu {
                Menu {
                    ForEach(PageTemplate.allCases) { template in
                        Button {
                            reference.controller?.setTemplate(template)
                        } label: {
                            Label(template.displayName, systemImage: template.symbol)
                        }
                    }
                } label: {
                    Label("Modello pagina", systemImage: "doc.plaintext")
                }
                Toggle(isOn: $settings.fingerDrawing) {
                    Label("Disegna con il dito", systemImage: "hand.draw")
                }
                Button {
                    renaming = true
                } label: {
                    Label("Rinomina quaderno", systemImage: "pencil")
                }
                Button {
                    exportPDF()
                } label: {
                    Label("Esporta PDF", systemImage: "square.and.arrow.up")
                }
                .disabled(isExporting)
            } label: {
                Label("Altro", systemImage: "ellipsis.circle")
            }
        }
    }

    private var pageControls: some View {
        HStack(spacing: 16) {
            Button {
                reference.controller?.previousPage()
            } label: {
                Image(systemName: "chevron.left").frame(width: 32, height: 32)
            }
            .disabled(currentIndex == 0)
            .accessibilityLabel("Pagina precedente")
            Text("\(currentIndex + 1) di \(notebook.pages.count)")
                .font(.callout.monospacedDigit())
                .frame(minWidth: 70)
            Button {
                if currentIndex + 1 >= notebook.pages.count {
                    services.content.insertPage(in: notebook, at: notebook.pages.count)
                }
                reference.controller?.nextPage()
            } label: {
                Image(systemName: currentIndex + 1 >= notebook.pages.count ? "plus" : "chevron.right").frame(width: 32, height: 32)
            }
            .accessibilityLabel(currentIndex + 1 >= notebook.pages.count ? "Nuova pagina" : "Pagina successiva")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .padding(.bottom, 16)
    }

    private func loadPhoto(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task {
            if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                reference.controller?.insertImage(image)
                mode = .arrange
            } else {
                errorMessage = "Immagine non caricata."
            }
            photoItem = nil
        }
    }

    private func exportPDF() {
        reference.controller?.saveNow()
        isExporting = true
        let pages = notebook.orderedPages
        let store = services.drawingStore
        let fileStore = services.fileStore
        let notebookID = notebook.id
        let title = notebook.title
        Task {
            var input: [(template: PageTemplate, drawing: PKDrawing, elements: [PDFExporter.PageElementSnapshot])] = []
            for page in pages {
                let path = page.drawing?.relativePath ?? DrawingStore.relativePath(notebookID: notebookID, pageID: page.id)
                let drawing = await store.load(relativePath: path)
                let elements = page.elements.map { PDFExporter.PageElementSnapshot(kind: $0.kind, frame: $0.frame, text: $0.text, fontSize: $0.fontSize, imagePath: $0.imageRelativePath, zIndex: $0.zIndex) }
                input.append((page.template, drawing, elements))
            }
            let data = PDFExporter.exportNotebook(pages: input, pageSize: NotebookCanvasController.pageSize) { path in
                UIImage(contentsOfFile: fileStore.pageImageURL(relativePath: path).path)
            }
            let url = fileStore.newExportURL(fileName: "\(title).pdf")
            do {
                try data.write(to: url, options: .atomic)
                exported = ExportedFile(url: url)
            } catch {
                errorMessage = "Esportazione non riuscita: \(error.localizedDescription)"
            }
            isExporting = false
        }
    }
}

struct NotebookCanvasRepresentable: UIViewControllerRepresentable {
    let notebook: Notebook
    let reference: NotebookControllerReference
    let initialIndex: Int
    let fingerDrawing: Bool
    let onPageChanged: (Int, NotebookPage) -> Void
    let onEdited: (NotebookPage) -> Void
    let onUndoState: (Bool, Bool) -> Void
    let onError: (String) -> Void
    @Environment(\.modelContext) private var modelContext
    @Environment(AppServices.self) private var services

    func makeUIViewController(context: Context) -> NotebookCanvasController {
        let controller = NotebookCanvasController(notebook: notebook, modelContext: modelContext, drawingStore: services.drawingStore, fileStore: services.fileStore, initialIndex: initialIndex)
        controller.fingerDrawing = fingerDrawing
        controller.onPageChanged = onPageChanged
        controller.onDrawingEdited = onEdited
        controller.onUndoStateChanged = onUndoState
        controller.onSaveError = onError
        reference.controller = controller
        return controller
    }

    func updateUIViewController(_ controller: NotebookCanvasController, context: Context) {
        if controller.fingerDrawing != fingerDrawing { controller.fingerDrawing = fingerDrawing }
    }

    static func dismantleUIViewController(_ controller: NotebookCanvasController, coordinator: ()) {
        controller.saveNow()
    }
}

/// Gestione delle pagine: miniature, riordino, inserimento, duplicazione,
/// eliminazione e modello.
struct PagesSheet: View {
    @Bindable var notebook: Notebook
    let currentIndex: Int
    let onSelect: (Int) -> Void
    let onChanged: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(AppServices.self) private var services
    @State private var thumbnails: [UUID: UIImage] = [:]
    @State private var deleting: NotebookPage?

    var body: some View {
        NavigationStack {
            List {
                ForEach(notebook.orderedPages) { page in
                    HStack(spacing: 16) {
                        thumbnail(for: page)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Pagina \(page.index + 1)").font(.headline)
                            Text(page.template.displayName).font(.caption).foregroundStyle(.secondary)
                            if page.index == currentIndex {
                                StatusBadge(text: "Aperta", color: .accentColor)
                            }
                        }
                        Spacer()
                        Menu {
                            Button("Inserisci pagina dopo", systemImage: "plus") {
                                services.content.insertPage(in: notebook, at: page.index + 1)
                                onChanged()
                            }
                            Button("Duplica", systemImage: "plus.square.on.square") {
                                services.content.duplicatePage(page)
                                onChanged()
                            }
                            Menu("Modello") {
                                ForEach(PageTemplate.allCases) { template in
                                    Button(template.displayName) {
                                        page.template = template
                                        services.content.save()
                                        onChanged()
                                    }
                                }
                            }
                            Divider()
                            Button("Elimina…", systemImage: "trash", role: .destructive) { deleting = page }
                                .disabled(notebook.pages.count <= 1)
                        } label: {
                            Image(systemName: "ellipsis.circle").font(.title3)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        onSelect(page.index)
                        dismiss()
                    }
                    .task { await loadThumbnail(page) }
                }
                .onMove { source, destination in
                    services.content.movePage(in: notebook, from: source, to: destination)
                    onChanged()
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Pagine")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Fine") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button("Nuova pagina", systemImage: "plus") {
                        services.content.insertPage(in: notebook, at: notebook.pages.count)
                        onChanged()
                    }
                }
            }
            .confirmationDialog("Eliminare la pagina?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                Button("Elimina pagina", role: .destructive) {
                    if let deleting { services.content.deletePage(deleting) }
                    deleting = nil
                    onChanged()
                }
            } message: {
                Text("Il contenuto della pagina verrà eliminato definitivamente.")
            }
        }
    }

    @ViewBuilder
    private func thumbnail(for page: NotebookPage) -> some View {
        ZStack {
            Rectangle().fill(.white)
            if let image = thumbnails[page.id] {
                Image(uiImage: image).resizable().scaledToFit()
            }
        }
        .frame(width: 66, height: 94)
        .overlay(Rectangle().stroke(Color.secondary.opacity(0.3)))
        .accessibilityHidden(true)
    }

    private func loadThumbnail(_ page: NotebookPage) async {
        guard thumbnails[page.id] == nil, let notebookID = page.notebook?.id else { return }
        let path = page.drawing?.relativePath ?? DrawingStore.relativePath(notebookID: notebookID, pageID: page.id)
        let drawing = await services.drawingStore.load(relativePath: path)
        let template = page.template
        let image = await Task.detached(priority: .utility) { () -> UIImage in
            let size = NotebookCanvasController.pageSize
            let scale: CGFloat = 0.2
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: size.width * scale, height: size.height * scale))
            var ink = UIImage()
            UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                ink = drawing.image(from: CGRect(origin: .zero, size: size), scale: scale * 2)
            }
            return renderer.image { context in
                UIColor.white.setFill()
                context.fill(CGRect(origin: .zero, size: renderer.format.bounds.size))
                PageTemplateRenderer.draw(template, in: context.cgContext, size: size, scale: scale)
                ink.draw(in: CGRect(origin: .zero, size: CGSize(width: size.width * scale, height: size.height * scale)))
            }
        }.value
        thumbnails[page.id] = image
    }
}
