import SwiftData
import SwiftUI

// MARK: - Quaderni

struct NotebooksGrid: View {
    let notebooks: [Notebook]
    let onCreate: () -> Void
    @Environment(AppServices.self) private var services
    @State private var openNotebook: Notebook?
    @State private var renaming: Notebook?
    @State private var deleting: Notebook?

    private let columns = [GridItem(.adaptive(minimum: 160, maximum: 200), spacing: 24)]

    var body: some View {
        Group {
            if notebooks.isEmpty {
                EmptyStateView(title: "Nessun quaderno", systemImage: "book.closed", message: "Crea un quaderno per prendere appunti con Apple Pencil, anche mentre registri la lezione.", actionTitle: "Nuovo quaderno", action: onCreate)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 28) {
                        ForEach(notebooks) { notebook in
                            Button {
                                openNotebook = notebook
                            } label: {
                                NotebookCover(notebook: notebook)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Rinomina", systemImage: "pencil") { renaming = notebook }
                                MoveToSubjectMenu(current: notebook.subject) { services.content.move(notebook, to: $0) }
                                Divider()
                                Button("Elimina…", systemImage: "trash", role: .destructive) { deleting = notebook }
                            }
                        }
                    }
                    .padding(24)
                }
            }
        }
        .fullScreenCover(item: $openNotebook) { notebook in
            NotebookEditorView(notebook: notebook)
        }
        .renameAlert(isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }), initial: renaming?.title ?? "") { title in
            renaming?.title = title
            services.content.save()
        }
        .confirmationDialog("Eliminare il quaderno?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Elimina quaderno", role: .destructive) {
                if let deleting { services.content.delete(deleting) }
                deleting = nil
            }
        } message: {
            Text("Tutte le pagine e i disegni di «\(deleting?.title ?? "")» verranno eliminati definitivamente. Le registrazioni collegate restano.")
        }
    }
}

struct NotebookCover: View {
    let notebook: Notebook

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(hex: notebook.coverColorHex).gradient)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(.black.opacity(0.12)).frame(width: 10)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .shadow(color: .black.opacity(0.15), radius: 6, y: 4)
                Text(notebook.title)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(3)
                    .padding(14)
                    .padding(.leading, 8)
            }
            .aspectRatio(0.72, contentMode: .fit)
            .hoverEffect(.lift)
            Text("\(notebook.pages.count) \(notebook.pages.count == 1 ? "pagina" : "pagine") · \(Format.relative(notebook.updatedAt))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Quaderno \(notebook.title)")
    }
}

/// Riga che apre un quaderno a schermo intero (liste recenti e ricerca).
struct NotebookOpenRow: View {
    let notebook: Notebook
    @State private var open = false

    var body: some View {
        Button {
            open = true
        } label: {
            HStack {
                RoundedRectangle(cornerRadius: 4).fill(Color(hex: notebook.coverColorHex)).frame(width: 24, height: 32)
                VStack(alignment: .leading) {
                    Text(notebook.title).foregroundStyle(.primary)
                    Text(notebook.subject?.name ?? "Senza materia").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .fullScreenCover(isPresented: $open) { NotebookEditorView(notebook: notebook) }
    }
}

struct NotebookCreationSheet: View {
    let subject: Subject?
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var colorHex = SubjectStyle.colors[0]
    @State private var template = PageTemplate.lined

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Titolo (es. Quaderno delle lezioni)", text: $title)
                }
                Section("Copertina") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
                        ForEach(SubjectStyle.colors, id: \.self) { hex in
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color(hex: hex))
                                .frame(width: 34, height: 46)
                                .overlay { if hex == colorHex { Image(systemName: "checkmark").foregroundStyle(.white) } }
                                .onTapGesture { colorHex = hex }
                        }
                    }
                }
                Section("Pagine") {
                    Picker("Modello", selection: $template) {
                        ForEach(PageTemplate.allCases) { Label($0.displayName, systemImage: $0.symbol).tag($0) }
                    }
                    .pickerStyle(.inline)
                }
            }
            .navigationTitle("Nuovo quaderno")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annulla") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Crea") {
                        let name = title.trimmingCharacters(in: .whitespaces)
                        services.content.createNotebook(in: subject, title: name.isEmpty ? "Quaderno" : name, colorHex: colorHex, template: template)
                        dismiss()
                    }
                }
            }
            .onAppear { colorHex = subject?.colorHex ?? colorHex }
        }
    }
}

// MARK: - Registrazioni

struct RecordingsList: View {
    let recordings: [AudioRecording]
    let onRecord: () -> Void
    let onImport: () -> Void

    var body: some View {
        if recordings.isEmpty {
            EmptyStateView(title: "Nessuna registrazione", systemImage: "waveform", message: "Registra una lezione o importa un file audio esistente (M4A, MP3, WAV, AAC, MP4).", actionTitle: "Registra lezione", action: onRecord)
                .toolbar {
                    ToolbarItem(placement: .secondaryAction) { Button("Importa audio", action: onImport) }
                }
        } else {
            List(recordings) { recording in
                NavigationLink {
                    RecordingDetailView(recording: recording)
                } label: {
                    RecordingRow(recording: recording, showSubject: false)
                }
            }
            .listStyle(.plain)
        }
    }
}

struct RecordingRow: View {
    let recording: AudioRecording
    let showSubject: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: recording.source == .imported ? "waveform.badge.plus" : "waveform")
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(recording.title).font(.body.weight(.medium)).lineLimit(1)
                HStack(spacing: 6) {
                    if showSubject, let subject = recording.subject {
                        Text(subject.name)
                        Text("·")
                    }
                    Text(Format.date(recording.recordedAt, time: true))
                    Text("·")
                    Text(Format.duration(recording.duration))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if recording.status != .ready {
                StatusBadge(text: recording.status.displayName, color: recording.status == .damaged ? .red : .orange)
            }
            if recording.latestTranscript != nil {
                Image(systemName: "text.quote").foregroundStyle(.secondary).accessibilityLabel("Trascritta")
            }
            if !recording.documents.isEmpty {
                Image(systemName: "doc.text.fill").foregroundStyle(.secondary).accessibilityLabel("Sbobinatura disponibile")
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Sbobinature

struct DocumentsList: View {
    let documents: [GeneratedDocument]
    @Environment(AppServices.self) private var services
    @State private var deleting: GeneratedDocument?

    var body: some View {
        if documents.isEmpty {
            EmptyStateView(title: "Nessuna sbobinatura", systemImage: "doc.text", message: "Apri una registrazione e scegli «Trascrivi e crea sbobinatura».")
        } else {
            List {
                ForEach(documents) { document in
                    NavigationLink {
                        DocumentEditorView(document: document)
                    } label: {
                        DocumentRow(document: document, showSubject: false)
                    }
                    .contextMenu {
                        MoveToSubjectMenu(current: document.subject) { services.content.move(document, to: $0) }
                        Button("Elimina…", systemImage: "trash", role: .destructive) { deleting = document }
                    }
                }
            }
            .listStyle(.plain)
            .confirmationDialog("Eliminare la sbobinatura?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                Button("Elimina", role: .destructive) {
                    if let deleting { services.content.delete(deleting) }
                    deleting = nil
                }
            } message: {
                Text("Il documento e tutte le sue versioni verranno eliminati. La registrazione e la trascrizione restano.")
            }
        }
    }
}

struct DocumentRow: View {
    let document: GeneratedDocument
    let showSubject: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: document.mode == .riassunto ? "list.bullet.rectangle" : "doc.text")
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(document.title).font(.body.weight(.medium)).lineLimit(1)
                HStack(spacing: 6) {
                    if showSubject, let subject = document.subject {
                        Text(subject.name)
                        Text("·")
                    }
                    Text(document.mode.displayName)
                    Text("·")
                    Text(Format.date(document.updatedAt))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if document.failedSectionCount > 0 {
                StatusBadge(text: "\(document.failedSectionCount) da rigenerare", systemImage: "exclamationmark.triangle", color: .red)
            } else if document.issueCount > 0 {
                StatusBadge(text: "\(document.issueCount) da verificare", systemImage: "exclamationmark.bubble", color: .orange)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - PDF

struct MaterialsList: View {
    let materials: [PDFMaterial]
    let onImport: () -> Void
    @Environment(AppServices.self) private var services
    @State private var open: PDFMaterial?
    @State private var deleting: PDFMaterial?
    @State private var renaming: PDFMaterial?

    var body: some View {
        Group {
            if materials.isEmpty {
                EmptyStateView(title: "Nessun PDF", systemImage: "doc.richtext", message: "Importa slide e manuali per leggerli e annotarli con Apple Pencil.", actionTitle: "Importa PDF", action: onImport)
            } else {
                List {
                    ForEach(materials) { material in
                        Button {
                            open = material
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "doc.richtext").font(.title3).foregroundStyle(.tint).frame(width: 32)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(material.title).foregroundStyle(.primary)
                                    Text("\(material.kind.displayName) · \(material.pageCount) pagine").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .contextMenu {
                            Button("Rinomina", systemImage: "pencil") { renaming = material }
                            Picker("Tipo", selection: Binding(get: { material.kind }, set: { material.kind = $0; services.content.save() })) {
                                ForEach(MaterialKind.allCases) { Text($0.displayName).tag($0) }
                            }
                            MoveToSubjectMenu(current: material.subject) { services.content.move(material, to: $0) }
                            Button("Elimina…", systemImage: "trash", role: .destructive) { deleting = material }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .fullScreenCover(item: $open) { material in
            PDFMaterialView(material: material)
        }
        .renameAlert(isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }), initial: renaming?.title ?? "") { title in
            renaming?.title = title
            services.content.save()
        }
        .confirmationDialog("Eliminare il PDF?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Elimina", role: .destructive) {
                if let deleting { services.content.delete(deleting) }
                deleting = nil
            }
        } message: {
            Text("Il file e le annotazioni verranno eliminati.")
        }
    }
}
