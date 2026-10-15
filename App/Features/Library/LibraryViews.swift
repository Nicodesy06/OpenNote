import SwiftData
import SwiftUI

/// Creazione e modifica di una materia.
struct SubjectEditorSheet: View {
    let subject: Subject?
    var onDone: ((Subject?) -> Void)?
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var colorHex = SubjectStyle.colors[0]
    @State private var iconName = SubjectStyle.icons[0]

    init(subject: Subject?, onDone: ((Subject?) -> Void)? = nil) {
        self.subject = subject
        self.onDone = onDone
        _name = State(initialValue: subject?.name ?? "")
        _colorHex = State(initialValue: subject?.colorHex ?? SubjectStyle.colors.randomElement() ?? "#3B6FD8")
        _iconName = State(initialValue: subject?.iconName ?? "book.closed")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 16) {
                        Image(systemName: iconName)
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 60, height: 60)
                            .background(Color(hex: colorHex).gradient, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        TextField("Nome della materia", text: $name)
                            .font(.title3)
                            .textInputAutocapitalization(.words)
                            .submitLabel(.done)
                    }
                    .padding(.vertical, 6)
                }
                Section("Colore") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
                        ForEach(SubjectStyle.colors, id: \.self) { hex in
                            Circle()
                                .fill(Color(hex: hex))
                                .frame(width: 36, height: 36)
                                .overlay {
                                    if hex == colorHex {
                                        Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.white)
                                    }
                                }
                                .onTapGesture { colorHex = hex }
                                .accessibilityLabel("Colore \(hex)")
                                .accessibilityAddTraits(hex == colorHex ? .isSelected : [])
                        }
                    }
                    .padding(.vertical, 6)
                }
                Section("Icona") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
                        ForEach(SubjectStyle.icons, id: \.self) { icon in
                            Image(systemName: icon)
                                .font(.title3)
                                .frame(width: 44, height: 44)
                                .background(icon == iconName ? Color(hex: colorHex).opacity(0.2) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                                .foregroundStyle(icon == iconName ? Color(hex: colorHex) : .primary)
                                .onTapGesture { iconName = icon }
                                .accessibilityLabel(icon)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
            .navigationTitle(subject == nil ? "Nuova materia" : "Modifica materia")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(subject == nil ? "Crea" : "Salva") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if let subject {
            subject.name = trimmed
            subject.colorHex = colorHex
            subject.iconName = iconName
            subject.updatedAt = Date()
            services.content.save()
            onDone?(subject)
        } else {
            let created = services.content.createSubject(name: trimmed, colorHex: colorHex, iconName: iconName)
            onDone?(created)
        }
        dismiss()
    }
}

/// Contenuti recenti di tutte le materie.
struct RecentView: View {
    @Query(sort: \AudioRecording.createdAt, order: .reverse) private var recordings: [AudioRecording]
    @Query(sort: \GeneratedDocument.updatedAt, order: .reverse) private var documents: [GeneratedDocument]
    @Query(sort: \Notebook.updatedAt, order: .reverse) private var notebooks: [Notebook]

    var body: some View {
        List {
            Section("Sbobinature") {
                if documents.isEmpty { Text("Nessuna sbobinatura").foregroundStyle(.secondary) }
                ForEach(documents.prefix(15)) { document in
                    NavigationLink { DocumentEditorView(document: document) } label: { DocumentRow(document: document, showSubject: true) }
                }
            }
            Section("Registrazioni") {
                if recordings.isEmpty { Text("Nessuna registrazione").foregroundStyle(.secondary) }
                ForEach(recordings.prefix(15)) { recording in
                    NavigationLink { RecordingDetailView(recording: recording) } label: { RecordingRow(recording: recording, showSubject: true) }
                }
            }
            Section("Quaderni") {
                if notebooks.isEmpty { Text("Nessun quaderno").foregroundStyle(.secondary) }
                ForEach(notebooks.prefix(15)) { notebook in
                    NotebookOpenRow(notebook: notebook)
                }
            }
        }
        .navigationTitle("Recenti")
    }
}

/// Materie archiviate: nulla viene perso, si possono ripristinare.
struct ArchiveView: View {
    @Environment(AppServices.self) private var services
    @Query(filter: #Predicate<Subject> { $0.archivedAt != nil }, sort: \Subject.name) private var archived: [Subject]

    var body: some View {
        Group {
            if archived.isEmpty {
                EmptyStateView(title: "Archivio vuoto", systemImage: "archivebox", message: "Le materie archiviate restano integre e compaiono qui.")
            } else {
                List {
                    ForEach(archived) { subject in
                        HStack {
                            SubjectIcon(subject: subject)
                            VStack(alignment: .leading) {
                                Text(subject.name)
                                if let date = subject.archivedAt {
                                    Text("Archiviata \(Format.relative(date))").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Button("Ripristina") { services.content.archive(subject, archived: false) }
                                .buttonStyle(.bordered)
                        }
                    }
                }
            }
        }
        .navigationTitle("Archivio")
    }
}

/// Ricerca per titolo e contenuto testuale (trascrizioni e sbobinature).
struct SearchResultsView: View {
    let query: String
    @Environment(\.modelContext) private var modelContext
    @State private var subjects: [Subject] = []
    @State private var notebooks: [Notebook] = []
    @State private var recordings: [AudioRecording] = []
    @State private var transcripts: [Transcript] = []
    @State private var documents: [GeneratedDocument] = []
    @State private var materials: [PDFMaterial] = []

    var body: some View {
        List {
            if !subjects.isEmpty {
                Section("Materie") {
                    ForEach(subjects) { subject in
                        Label { Text(subject.name) } icon: { SubjectIcon(subject: subject, size: 24) }
                    }
                }
            }
            if !documents.isEmpty {
                Section("Sbobinature") {
                    ForEach(documents) { document in
                        NavigationLink { DocumentEditorView(document: document) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                DocumentRow(document: document, showSubject: true)
                                SnippetText(text: document.searchText, query: query)
                            }
                        }
                    }
                }
            }
            if !transcripts.isEmpty {
                Section("Trascrizioni") {
                    ForEach(transcripts) { transcript in
                        if let recording = transcript.recording {
                            NavigationLink { TranscriptView(transcript: transcript, recording: recording) } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(recording.title).font(.headline)
                                    SnippetText(text: transcript.searchText, query: query)
                                }
                            }
                        }
                    }
                }
            }
            if !recordings.isEmpty {
                Section("Registrazioni") {
                    ForEach(recordings) { recording in
                        NavigationLink { RecordingDetailView(recording: recording) } label: { RecordingRow(recording: recording, showSubject: true) }
                    }
                }
            }
            if !notebooks.isEmpty {
                Section("Quaderni") {
                    ForEach(notebooks) { NotebookOpenRow(notebook: $0) }
                }
            }
            if !materials.isEmpty {
                Section("PDF") {
                    ForEach(materials) { material in
                        Label(material.title, systemImage: "doc.richtext")
                    }
                }
            }
            if subjects.isEmpty && notebooks.isEmpty && recordings.isEmpty && transcripts.isEmpty && documents.isEmpty && materials.isEmpty {
                Text("Nessun risultato per «\(query)»").foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Risultati")
        .task(id: query) { search() }
    }

    private func search() {
        let text = query
        subjects = (try? modelContext.fetch(FetchDescriptor<Subject>(predicate: #Predicate { $0.name.localizedStandardContains(text) }))) ?? []
        notebooks = (try? modelContext.fetch(FetchDescriptor<Notebook>(predicate: #Predicate { $0.title.localizedStandardContains(text) }))) ?? []
        recordings = (try? modelContext.fetch(FetchDescriptor<AudioRecording>(predicate: #Predicate { $0.title.localizedStandardContains(text) || $0.notes.localizedStandardContains(text) }))) ?? []
        transcripts = (try? modelContext.fetch(FetchDescriptor<Transcript>(predicate: #Predicate { $0.searchText.localizedStandardContains(text) }))) ?? []
        documents = (try? modelContext.fetch(FetchDescriptor<GeneratedDocument>(predicate: #Predicate { $0.title.localizedStandardContains(text) || $0.searchText.localizedStandardContains(text) }))) ?? []
        materials = (try? modelContext.fetch(FetchDescriptor<PDFMaterial>(predicate: #Predicate { $0.title.localizedStandardContains(text) }))) ?? []
    }
}

/// Estratto di testo attorno alla prima occorrenza della ricerca.
struct SnippetText: View {
    let text: String
    let query: String

    var body: some View {
        if let range = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) {
            let start = text.index(range.lowerBound, offsetBy: -60, limitedBy: text.startIndex) ?? text.startIndex
            let end = text.index(range.upperBound, offsetBy: 100, limitedBy: text.endIndex) ?? text.endIndex
            Text("…" + text[start..<end] + "…")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }
}

/// Assegnazione a una materia dei file ricevuti con "Apri con".
struct IncomingFilesSheet: View {
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    @Query(filter: #Predicate<Subject> { $0.archivedAt == nil }, sort: \Subject.name) private var subjects: [Subject]
    @State private var subjectID: UUID?
    @State private var importing = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("File ricevuti") {
                    ForEach(services.pendingIncomingFiles, id: \.self) { url in
                        Label(url.lastPathComponent, systemImage: ImportService.isPDF(url) ? "doc.richtext" : "waveform")
                    }
                }
                Section("Materia") {
                    Picker("Materia", selection: $subjectID) {
                        Text("Nessuna").tag(UUID?.none)
                        ForEach(subjects) { subject in
                            Text(subject.name).tag(Optional(subject.id))
                        }
                    }
                }
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
            .navigationTitle("Importa")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla") {
                        services.pendingIncomingFiles.removeAll()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Importa") { importAll() }.disabled(importing)
                }
            }
        }
    }

    private func importAll() {
        importing = true
        let subject = subjects.first { $0.id == subjectID }
        Task {
            for url in services.pendingIncomingFiles {
                do {
                    if ImportService.isPDF(url) {
                        _ = try services.importer.importPDF(from: url, subject: subject)
                    } else {
                        _ = try await services.importer.importAudio(from: url, subject: subject)
                    }
                    services.fileStore.removeItemIfExists(url)
                } catch {
                    errorMessage = error.readableMessage
                }
            }
            importing = false
            if errorMessage == nil {
                services.pendingIncomingFiles.removeAll()
                dismiss()
            }
        }
    }
}
