import SwiftData
import SwiftUI

struct SubjectDetailView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case notebooks, recordings, documents, materials, glossary, settings
        var id: String { rawValue }
        var title: String {
            switch self {
            case .notebooks: return "Quaderni"
            case .recordings: return "Registrazioni"
            case .documents: return "Sbobinature"
            case .materials: return "PDF"
            case .glossary: return "Glossario"
            case .settings: return "AI"
            }
        }
        var systemImage: String {
            switch self {
            case .notebooks: return "book"
            case .recordings: return "waveform"
            case .documents: return "doc.text"
            case .materials: return "doc.richtext"
            case .glossary: return "character.book.closed"
            case .settings: return "sparkles"
            }
        }
    }

    enum SortOrder: String, CaseIterable, Identifiable {
        case newest, oldest, title
        var id: String { rawValue }
        var title: String {
            switch self {
            case .newest: return "Più recenti"
            case .oldest: return "Meno recenti"
            case .title: return "Titolo"
            }
        }
    }

    @Bindable var subject: Subject
    @Environment(AppServices.self) private var services
    @Environment(RecordingService.self) private var recorder
    @SceneStorage("subjectTab") private var tabRaw = Tab.notebooks.rawValue
    @State private var sortOrder = SortOrder.newest
    @State private var editingSubject = false
    @State private var startRecording = false
    @State private var creatingNotebook = false
    @State private var importKind: ImportKind?
    @State private var activeImportKind: ImportKind = .audio

    enum ImportKind { case audio, pdf }
    @State private var errorMessage: String?

    private var tab: Tab { Tab(rawValue: tabRaw) ?? .notebooks }

    var body: some View {
        VStack(spacing: 0) {
            header
            Picker("Sezione", selection: $tabRaw) {
                ForEach(Tab.allCases) { tab in
                    Label(tab.title, systemImage: tab.systemImage).tag(tab.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(subject.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Picker("Ordina", selection: $sortOrder) {
                        ForEach(SortOrder.allCases) { Text($0.title).tag($0) }
                    }
                } label: {
                    Label("Ordina", systemImage: "arrow.up.arrow.down")
                }
                Menu {
                    Button("Nuovo quaderno", systemImage: "book.closed") { creatingNotebook = true }
                    Button("Registra lezione", systemImage: "record.circle") { startRecording = true }
                        .disabled(recorder.state.isActive)
                    Button("Importa audio", systemImage: "waveform.badge.plus") { beginImport(.audio) }
                    Button("Importa PDF", systemImage: "doc.badge.plus") { beginImport(.pdf) }
                } label: {
                    Label("Aggiungi", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $editingSubject) { SubjectEditorSheet(subject: subject) }
        .sheet(isPresented: $startRecording) { StartRecordingSheet(subject: subject, notebook: nil) }
        .sheet(isPresented: $creatingNotebook) { NotebookCreationSheet(subject: subject) }
        .fileImporter(isPresented: Binding(get: { importKind != nil }, set: { if !$0 { importKind = nil } }), allowedContentTypes: activeImportKind == .pdf ? [.pdf] : ImportService.audioTypes, allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            handleImport(urls, kind: activeImportKind)
        }
        .alert("Errore", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            SubjectIcon(subject: subject, size: 56)
            VStack(alignment: .leading, spacing: 4) {
                Text(subject.name).font(.title.bold())
                Text("\(subject.notebooks.count) quaderni · \(subject.recordings.count) registrazioni · \(subject.documents.count) sbobinature")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                startRecording = true
            } label: {
                Label("Registra", systemImage: "record.circle")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(recorder.state.isActive)
            Button {
                editingSubject = true
            } label: {
                Label("Modifica", systemImage: "pencil")
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .notebooks:
            NotebooksGrid(notebooks: sorted(subject.notebooks, date: \.updatedAt, title: \.title)) { creatingNotebook = true }
        case .recordings:
            RecordingsList(recordings: sorted(subject.recordings, date: \.recordedAt, title: \.title)) { startRecording = true } onImport: { beginImport(.audio) }
        case .documents:
            DocumentsList(documents: sorted(subject.documents, date: \.updatedAt, title: \.title))
        case .materials:
            MaterialsList(materials: sorted(subject.materials, date: \.importedAt, title: \.title)) { beginImport(.pdf) }
        case .glossary:
            GlossaryView(subject: subject)
        case .settings:
            SubjectAISettingsView(subject: subject)
        }
    }

    private func beginImport(_ kind: ImportKind) {
        activeImportKind = kind
        importKind = kind
    }

    private func handleImport(_ urls: [URL], kind: ImportKind) {
        switch kind {
        case .pdf:
            for url in urls {
                do {
                    _ = try services.importer.importPDF(from: url, subject: subject)
                } catch {
                    errorMessage = error.readableMessage
                }
            }
            tabRaw = Tab.materials.rawValue
        case .audio:
            Task {
                for url in urls {
                    do {
                        _ = try await services.importer.importAudio(from: url, subject: subject)
                    } catch {
                        errorMessage = error.readableMessage
                    }
                }
                tabRaw = Tab.recordings.rawValue
            }
        }
    }

    private func sorted<T>(_ items: [T], date: KeyPath<T, Date>, title: KeyPath<T, String>) -> [T] {
        switch sortOrder {
        case .newest: return items.sorted { $0[keyPath: date] > $1[keyPath: date] }
        case .oldest: return items.sorted { $0[keyPath: date] < $1[keyPath: date] }
        case .title: return items.sorted { $0[keyPath: title].localizedStandardCompare($1[keyPath: title]) == .orderedAscending }
        }
    }
}

/// Sposta un contenuto in un'altra materia.
struct MoveToSubjectMenu: View {
    let current: Subject?
    let action: (Subject?) -> Void
    @Query(filter: #Predicate<Subject> { $0.archivedAt == nil }, sort: \Subject.name) private var subjects: [Subject]

    var body: some View {
        Menu {
            ForEach(subjects.filter { $0.id != current?.id }) { subject in
                Button(subject.name) { action(subject) }
            }
        } label: {
            Label("Sposta in…", systemImage: "folder")
        }
    }
}

/// Rinomina generica.
struct RenameAlert: ViewModifier {
    @Binding var isPresented: Bool
    let title: String
    let initial: String
    let onSave: (String) -> Void
    @State private var text = ""

    func body(content: Content) -> some View {
        content
            .alert(title, isPresented: $isPresented) {
                TextField("Titolo", text: $text)
                Button("Annulla", role: .cancel) {}
                Button("Salva") {
                    let trimmed = text.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty { onSave(trimmed) }
                }
            }
            .onChange(of: isPresented) { _, presented in
                if presented { text = initial }
            }
    }
}

extension View {
    func renameAlert(isPresented: Binding<Bool>, title: String = "Rinomina", initial: String, onSave: @escaping (String) -> Void) -> some View {
        modifier(RenameAlert(isPresented: isPresented, title: title, initial: initial, onSave: onSave))
    }
}
