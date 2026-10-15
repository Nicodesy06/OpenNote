import AVFoundation
import PhotosUI
import SwiftData
import SwiftUI
import QuadernoCore

/// Editor della sbobinatura: lettura, modifica per sezioni, verifica,
/// rigenerazione mirata, versioni, confronto con audio e trascrizione,
/// esportazione. Le modifiche manuali non vengono mai sovrascritte in
/// silenzio: ogni rigenerazione salva prima una versione.
struct DocumentEditorView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case read, edit, compare
        var id: String { rawValue }
        var title: String {
            switch self {
            case .read: return "Leggi"
            case .edit: return "Modifica"
            case .compare: return "Confronta"
            }
        }
    }

    @Bindable var document: GeneratedDocument
    @Environment(AppServices.self) private var services
    @Environment(PlaybackService.self) private var playback
    @Environment(JobRunner.self) private var jobRunner
    @Environment(\.modelContext) private var modelContext
    @State private var mode = Mode.read
    @State private var selectedSectionID: UUID?
    @State private var editText = ""
    @State private var editingHeader = false
    /// Destinazione del testo attualmente nell'editor (sezione o intestazione):
    /// il salvataggio scrive sempre qui, anche se nel frattempo cambia la selezione.
    @State private var editingTargetID: UUID?
    @State private var editingTargetIsHeader = false
    @State private var dirtySinceVersion = false
    @State private var saveTask: Task<Void, Never>?
    @State private var commands = MarkdownEditorCommands()
    @State private var showInspector = true
    @State private var rendered = NSAttributedString()
    @State private var exported: ExportedFile?
    @State private var showVersions = false
    @State private var regenerateTarget: GeneratedSection?
    @State private var regenerating: UUID?
    @State private var regenerationPreview = ""
    @State private var errorMessage: String?
    @State private var photoItem: PhotosPickerItem?
    @State private var transcript: Transcript?

    private var selectedSection: GeneratedSection? {
        document.orderedSections.first { $0.id == selectedSectionID }
    }

    var body: some View {
        HStack(spacing: 0) {
            sectionList
                .frame(width: 270)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(document.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .inspector(isPresented: $showInspector) {
            inspector
                .inspectorColumnWidth(min: 280, ideal: 320, max: 400)
        }
        .safeAreaInset(edge: .bottom) {
            if let recording = document.recording, mode != .edit, services.maintenance.playableURL(for: recording) != nil || !recording.segments.isEmpty {
                PlayerControls(recordingID: recording.id)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .background(.bar)
                    .task { await loadPlayer(recording) }
            }
        }
        .task(id: renderKey) { render() }
        .task { loadTranscript() }
        .onAppear {
            if selectedSectionID == nil { selectedSectionID = document.orderedSections.first?.id }
            loadEditText()
        }
        .onDisappear {
            flushEdits()
            snapshotIfNeeded(reason: "Modifiche manuali")
        }
        .onChange(of: selectedSectionID) { _, _ in
            flushEdits()
            loadEditText()
        }
        .onChange(of: photoItem) { _, item in insertPhoto(item) }
        .onChange(of: mode) { oldMode, newMode in
            if oldMode == .edit { flushEdits() }
            if newMode == .edit { loadEditText() }
        }
        .sheet(item: $exported) { file in ShareSheet(items: [file.url]) }
        .sheet(isPresented: $showVersions) { VersionsSheet(document: document) }
        .sheet(item: $regenerateTarget) { section in
            RegenerateSheet(section: section) { instructions in
                regenerate(section, instructions: instructions)
            }
        }
        .alert("Errore", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var renderKey: String {
        "\(document.updatedAt.timeIntervalSince1970)-\(document.sections.count)-\(mode.rawValue)"
    }

    // MARK: - Sezioni

    private var sectionList: some View {
        List(selection: $selectedSectionID) {
            Section("Sezioni") {
                ForEach(document.orderedSections) { section in
                    HStack(spacing: 8) {
                        sectionStatusIcon(section)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(section.title).lineLimit(2)
                            Text("\(TranscriptFormatter.timestamp(section.timeStart)) – \(TranscriptFormatter.timestamp(section.timeEnd))")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        if regenerating == section.id {
                            Spacer()
                            ProgressView()
                        }
                    }
                    .tag(section.id)
                }
            }
            if let outline = document.outline, !outline.normalizationNotes.isEmpty {
                Section("Note sulla struttura") {
                    ForEach(outline.normalizationNotes, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private func sectionStatusIcon(_ section: GeneratedSection) -> some View {
        if section.state == .failed {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red).accessibilityLabel("Non generata")
        } else if section.isUserEdited {
            Image(systemName: "pencil.circle.fill").foregroundStyle(.blue).accessibilityLabel("Modificata")
        } else {
            switch section.verification.status {
            case .noIssuesFound: Image(systemName: "checkmark.seal").foregroundStyle(.green).accessibilityLabel("Nessun problema rilevato")
            case .issuesFound, .repairedNeedsReview: Image(systemName: "exclamationmark.bubble").foregroundStyle(.orange).accessibilityLabel("Da verificare")
            case .notVerified, .failed: Image(systemName: "questionmark.circle").foregroundStyle(.secondary).accessibilityLabel("Non verificata")
            }
        }
    }

    // MARK: - Contenuto

    @ViewBuilder
    private var content: some View {
        switch mode {
        case .read:
            RenderedTextView(attributedText: rendered) { range in seek(toSegment: range.lowerBound) }
        case .edit:
            VStack(spacing: 0) {
                formattingBar
                Divider()
                MarkdownEditorView(text: $editText, commands: commands) { flushEdits() }
                    .onChange(of: editText) { _, _ in scheduleSave() }
            }
        case .compare:
            CompareView(document: document, transcript: transcript, selectedSectionID: $selectedSectionID) { time in
                playback.seek(to: time)
                playback.play()
            }
        }
    }

    private var formattingBar: some View {
        HStack(spacing: 4) {
            Toggle(isOn: $editingHeader) { Text("Intestazione") }
                .toggleStyle(.button)
                .onChange(of: editingHeader) { _, _ in
                    flushEdits()
                    loadEditText()
                }
            Divider().frame(height: 22)
            Group {
                Button { commands.toggleLinePrefix("### ") } label: { Text("Titolo").font(.callout.weight(.semibold)) }
                Button { commands.wrapSelection(prefix: "**", suffix: "**") } label: { Image(systemName: "bold") }
                    .accessibilityLabel("Grassetto")
                Button { commands.wrapSelection(prefix: "*", suffix: "*") } label: { Image(systemName: "italic") }
                    .accessibilityLabel("Corsivo")
                Button { commands.toggleLinePrefix("- ") } label: { Image(systemName: "list.bullet") }
                    .accessibilityLabel("Elenco puntato")
                Button { commands.toggleLinePrefix("1. ") } label: { Image(systemName: "list.number") }
                    .accessibilityLabel("Elenco numerato")
                Button { commands.wrapSelection(prefix: "[[incerto: ", suffix: "]]") } label: { Image(systemName: "questionmark.square.dashed") }
                    .accessibilityLabel("Segna come incerto")
                PhotosPicker(selection: $photoItem, matching: .images) { Image(systemName: "photo") }
                    .accessibilityLabel("Inserisci immagine")
                Button { commands.showFind() } label: { Image(systemName: "magnifyingglass") }
                    .accessibilityLabel("Cerca e sostituisci")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 6)
            Spacer()
            if let section = selectedSection, section.isUserEdited, !editingHeader {
                StatusBadge(text: "Modificata a mano", systemImage: "pencil", color: .blue)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .disabled(selectedSection == nil && !editingHeader)
    }

    // MARK: - Ispettore

    @ViewBuilder
    private var inspector: some View {
        if let section = selectedSection {
            List {
                Section {
                    Text(section.title).font(.headline)
                    LabeledContent("Audio", value: "\(TranscriptFormatter.timestamp(section.timeStart)) – \(TranscriptFormatter.timestamp(section.timeEnd))")
                    Button("Ascolta dall'inizio della sezione", systemImage: "play.circle") {
                        playback.seek(to: section.timeStart)
                        playback.play()
                    }
                    .disabled(document.recording == nil)
                }
                if section.state == .failed {
                    Section("Errore") {
                        Text(section.errorMessage ?? "Sezione non generata").foregroundStyle(.red)
                    }
                }
                let verification = section.verification
                Section {
                    LabeledContent("Esito", value: statusText(verification.status))
                    if verification.sourceWordCount > 0 {
                        LabeledContent("Parole (testo / trascrizione)", value: "\(verification.outputWordCount) / \(verification.sourceWordCount)")
                    }
                    ForEach(verification.issues) { issue in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Circle().fill(severityColor(issue.severity)).frame(width: 8, height: 8)
                                Text(issue.type.displayName).font(.subheadline.weight(.semibold))
                                if issue.repairAttempted { StatusBadge(text: "Correzione tentata", color: .blue) }
                            }
                            Text(issue.description).font(.callout)
                            if !issue.excerpt.isEmpty {
                                Text("«\(issue.excerpt)»").font(.caption).foregroundStyle(.secondary)
                            }
                            if let first = issue.sourceSegments.first, document.recording != nil {
                                Button("Ascolta il passaggio", systemImage: "play") { seek(toSegment: first) }
                                    .font(.caption)
                                    .buttonStyle(.borderless)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    ForEach(verification.unverifiable, id: \.self) { note in
                        Label(note, systemImage: "questionmark.circle").font(.caption).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Controllo di completezza")
                } footer: {
                    Text("Il controllo automatico confronta il testo con la trascrizione, ma non garantisce l'assenza di omissioni o errori: ricontrolla i passaggi importanti sull'audio.")
                }
                Section {
                    Button {
                        regenerateTarget = section
                    } label: {
                        Label(regenerating == section.id ? "Rigenerazione in corso…" : "Rigenera questa sezione", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(regenerating != nil)
                    if regenerating == section.id, !regenerationPreview.isEmpty {
                        Text(regenerationPreview).font(.caption).foregroundStyle(.secondary).lineLimit(10)
                    }
                } footer: {
                    Text(section.isUserEdited ? "Questa sezione contiene modifiche manuali: prima di rigenerarla viene salvata una versione del documento." : "Le altre sezioni, comprese quelle modificate a mano, restano invariate.")
                }
            }
        } else {
            EmptyStateView(title: "Nessuna sezione", systemImage: "sidebar.right", message: "Seleziona una sezione per vederne verifica e opzioni.")
        }
    }

    private func statusText(_ status: VerificationStatus) -> String {
        switch status {
        case .noIssuesFound: return "Nessun problema rilevato"
        case .issuesFound: return "Problemi da verificare"
        case .repairedNeedsReview: return "Corretta automaticamente, da ricontrollare"
        case .notVerified: return "Non verificata"
        case .failed: return "Sezione non generata"
        }
    }

    private func severityColor(_ severity: VerificationSeverity) -> Color {
        switch severity {
        case .high: return .red
        case .medium: return .orange
        case .low: return .yellow
        }
    }

    // MARK: - Barra strumenti

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("Modalità", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 280)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Button("PDF", systemImage: "doc.richtext") { export(.pdf) }
                Button("Word (.docx)", systemImage: "doc.text") { export(.docx) }
                Button("Markdown", systemImage: "number") { export(.markdown) }
                Button("Testo semplice", systemImage: "doc.plaintext") { export(.text) }
            } label: {
                Label("Esporta", systemImage: "square.and.arrow.up")
            }
            Button {
                flushEdits()
                showVersions = true
            } label: {
                Label("Versioni", systemImage: "clock.arrow.circlepath")
            }
            Button {
                showInspector.toggle()
            } label: {
                Label("Verifica", systemImage: "sidebar.right")
            }
        }
    }

    // MARK: - Modifica e salvataggio

    private func loadEditText() {
        editingTargetIsHeader = editingHeader
        editingTargetID = editingHeader ? nil : selectedSectionID
        if editingHeader {
            editText = document.headerMarkdown
        } else {
            editText = selectedSection?.markdown ?? ""
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            saveTask = nil
            flushEdits()
        }
    }

    private func flushEdits() {
        saveTask?.cancel()
        if editingTargetIsHeader {
            guard document.headerMarkdown != editText else { return }
            document.headerMarkdown = editText
        } else {
            guard let targetID = editingTargetID,
                  let section = document.sections.first(where: { $0.id == targetID }),
                  section.markdown != editText else { return }
            section.markdown = editText
            section.isUserEdited = true
            section.updatedAt = Date()
            if let title = EditorialNormalizer.sectionTitle(of: editText), !title.isEmpty { section.title = title }
        }
        document.updatedAt = Date()
        dirtySinceVersion = true
        document.refreshSearchText()
        try? modelContext.save()
    }

    private func snapshotIfNeeded(reason: String) {
        guard dirtySinceVersion else { return }
        let version = DocumentVersion(reason: reason, snapshot: DocumentSnapshot(document: document))
        version.document = document
        modelContext.insert(version)
        try? modelContext.save()
        dirtySinceVersion = false
    }

    private func insertPhoto(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task {
            defer { photoItem = nil }
            guard let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) else { return }
            let resized = NotebookCanvasController.downscaled(image, maxDimension: 1800)
            guard let jpeg = resized.jpegData(compressionQuality: 0.85) else { return }
            let relative = "\(document.id.uuidString)/\(UUID().uuidString).jpg"
            do {
                try services.fileStore.writeAtomically(jpeg, to: services.fileStore.documentImageURL(relativePath: relative))
                commands.insert("\n\n![Immagine](\(relative))\n\n")
            } catch {
                errorMessage = "Immagine non salvata: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Lettura e audio

    private func render() {
        guard mode == .read else { return }
        var renderer = MarkdownRenderer()
        let fileStore = services.fileStore
        renderer.imageResolver = { path in UIImage(contentsOfFile: fileStore.documentImageURL(relativePath: path).path) }
        rendered = renderer.render(document.markdown)
    }

    private func loadTranscript() {
        guard let transcriptID = document.transcriptID else { return }
        transcript = try? modelContext.fetch(FetchDescriptor<Transcript>(predicate: #Predicate { $0.id == transcriptID })).first
    }

    private func loadPlayer(_ recording: AudioRecording) async {
        if let url = services.maintenance.playableURL(for: recording) {
            playback.load(recordingID: recording.id, title: recording.title, asset: AVURLAsset(url: url), knownDuration: recording.duration)
        } else if let composition = await services.maintenance.compositionForSegments(of: recording) {
            playback.load(recordingID: recording.id, title: recording.title, asset: composition, knownDuration: recording.duration)
        }
    }

    private func seek(toSegment index: Int) {
        guard let segment = transcript?.orderedSegments.first(where: { $0.index == index }) else { return }
        playback.seek(to: segment.start)
        playback.play()
    }

    // MARK: - Rigenerazione

    private func regenerate(_ section: GeneratedSection, instructions: String?) {
        flushEdits()
        regenerating = section.id
        regenerationPreview = ""
        Task {
            do {
                try await jobRunner.regenerate(section: section, in: document, instructions: instructions) { text in
                    regenerationPreview = String(text.suffix(800))
                }
                loadEditText()
            } catch {
                errorMessage = AIServiceError.from(error, provider: "AI").userMessage
            }
            regenerating = nil
        }
    }

    // MARK: - Esportazione

    enum ExportKind { case pdf, docx, markdown, text }

    private func export(_ kind: ExportKind) {
        flushEdits()
        let fileStore = services.fileStore
        let name = FileStore.sanitizedFileName(document.title)
        let markdown = document.markdown
        do {
            let url: URL
            switch kind {
            case .pdf:
                url = fileStore.newExportURL(fileName: name + ".pdf")
                let data = PDFExporter.exportDocument(markdown: markdown, title: document.title) { path in
                    UIImage(contentsOfFile: fileStore.documentImageURL(relativePath: path).path)
                }
                try data.write(to: url, options: .atomic)
            case .docx:
                url = fileStore.newExportURL(fileName: name + ".docx")
                let exporter = DocxExporter(title: document.title) { path in
                    let imageURL = fileStore.documentImageURL(relativePath: path)
                    guard let data = try? Data(contentsOf: imageURL), let image = UIImage(data: data) else { return nil }
                    return DocxImage(data: data, fileExtension: imageURL.pathExtension, pixelWidth: Int(image.size.width * image.scale), pixelHeight: Int(image.size.height * image.scale))
                }
                try exporter.export(markdown: markdown).write(to: url, options: .atomic)
            case .markdown:
                url = fileStore.newExportURL(fileName: name + ".md")
                try SourceMarkers.stripForExport(markdown).write(to: url, atomically: true, encoding: .utf8)
            case .text:
                url = fileStore.newExportURL(fileName: name + ".txt")
                try MarkdownParser.plainText(MarkdownParser.parse(markdown)).write(to: url, atomically: true, encoding: .utf8)
            }
            exported = ExportedFile(url: url)
        } catch {
            errorMessage = "Esportazione non riuscita: \(error.localizedDescription)"
        }
    }
}

/// Indicazioni facoltative per la rigenerazione di una sezione.
struct RegenerateSheet: View {
    let section: GeneratedSection
    let onConfirm: (String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var instructions = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(section.title).font(.headline)
                    if section.isUserEdited {
                        Label("La sezione contiene modifiche manuali. Verrà salvata una versione del documento prima di sostituirla: potrai ripristinarla dalle Versioni.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
                Section {
                    TextEditor(text: $instructions).frame(minHeight: 100)
                } header: {
                    Text("Indicazioni (facoltative)")
                } footer: {
                    Text("Es.: «Sviluppa meglio l'esempio del Padiglione di Barcellona», «Usa un elenco per le cinque caratteristiche». Le indicazioni non autorizzano ad aggiungere contenuti non presenti nella lezione.")
                }
            }
            .navigationTitle("Rigenera sezione")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annulla") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Rigenera") {
                        let trimmed = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
                        onConfirm(trimmed.isEmpty ? nil : trimmed)
                        dismiss()
                    }
                }
            }
        }
    }
}

/// Versioni del documento con ripristino (che a sua volta salva la
/// versione corrente).
struct VersionsSheet: View {
    @Bindable var document: GeneratedDocument
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var preview: DocumentVersion?

    var body: some View {
        NavigationStack {
            List {
                ForEach(document.versions.sorted { $0.createdAt > $1.createdAt }) { version in
                    Button {
                        preview = version
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(version.reason).foregroundStyle(.primary)
                            Text(Format.date(version.createdAt, time: true)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .overlay {
                if document.versions.isEmpty {
                    EmptyStateView(title: "Nessuna versione", systemImage: "clock", message: "Le versioni vengono create a ogni generazione, prima di ogni rigenerazione e dopo le modifiche manuali.")
                }
            }
            .navigationTitle("Versioni")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fine") { dismiss() } } }
            .sheet(item: $preview) { version in
                VersionPreview(version: version) { restore(version) }
            }
        }
    }

    private func restore(_ version: DocumentVersion) {
        guard let snapshot = version.snapshot else { return }
        let backup = DocumentVersion(reason: "Prima del ripristino della versione del \(Format.date(version.createdAt, time: true))", snapshot: DocumentSnapshot(document: document))
        backup.document = document
        modelContext.insert(backup)
        document.title = snapshot.title
        document.headerMarkdown = snapshot.headerMarkdown
        for saved in snapshot.sections {
            if let section = document.sections.first(where: { $0.id == saved.id }) {
                section.title = saved.title
                section.markdown = saved.markdown
                section.isUserEdited = saved.isUserEdited
                section.updatedAt = Date()
            }
        }
        document.updatedAt = Date()
        document.refreshSearchText()
        try? modelContext.save()
        dismiss()
    }
}

private struct VersionPreview: View {
    let version: DocumentVersion
    let onRestore: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                if let snapshot = version.snapshot {
                    Text(SourceMarkers.stripForExport(([snapshot.headerMarkdown] + snapshot.sections.sorted { $0.order < $1.order }.map(\.markdown)).joined(separator: "\n\n")))
                        .font(.body)
                        .padding(24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
            .navigationTitle(version.reason)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Chiudi") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Ripristina") {
                        onRestore()
                        dismiss()
                    }
                }
            }
        }
    }
}

/// Confronto: trascrizione originale (con tempi) accanto alla sezione
/// della sbobinatura; i riferimenti portano al punto dell'audio.
struct CompareView: View {
    let document: GeneratedDocument
    let transcript: Transcript?
    @Binding var selectedSectionID: UUID?
    let onSeek: (TimeInterval) -> Void
    @State private var highlighted: ClosedRange<Int>?

    private var section: GeneratedSection? {
        document.orderedSections.first { $0.id == selectedSectionID } ?? document.orderedSections.first
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Trascrizione").font(.headline).padding()
                Divider()
                if let transcript, let section {
                    ScrollViewReader { proxy in
                        List(transcript.orderedSegments.filter { $0.index >= section.segmentStart && $0.index <= section.segmentEnd }) { segment in
                            Button {
                                onSeek(segment.start)
                            } label: {
                                HStack(alignment: .top) {
                                    Text(TranscriptFormatter.timestamp(segment.start)).font(.caption.monospacedDigit()).foregroundStyle(.tint)
                                    Text(segment.text).font(.callout).foregroundStyle(.primary)
                                }
                            }
                            .listRowBackground(highlighted?.contains(segment.index) == true ? Color.yellow.opacity(0.2) : nil)
                            .id(segment.index)
                        }
                        .listStyle(.plain)
                        .onChange(of: highlighted) { _, range in
                            if let range { withAnimation { proxy.scrollTo(range.lowerBound, anchor: .top) } }
                        }
                    }
                } else {
                    EmptyStateView(title: "Trascrizione non disponibile", systemImage: "text.quote", message: "La trascrizione originale di questo documento non è più presente.")
                }
            }
            .frame(maxWidth: .infinity)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                Text("Sbobinatura").font(.headline).padding()
                Divider()
                if let section {
                    RenderedTextView(attributedText: MarkdownRenderer().render(section.markdown)) { range in
                        highlighted = range
                        if let segment = transcript?.orderedSegments.first(where: { $0.index == range.lowerBound }) {
                            onSeek(segment.start)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
    }
}
