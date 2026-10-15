import SwiftData
import SwiftUI

struct HomeView: View {
    @Binding var selection: SidebarItem?
    @Environment(AppServices.self) private var services
    @Environment(RecordingService.self) private var recorder
    @Query(filter: #Predicate<Subject> { $0.archivedAt == nil }, sort: [SortDescriptor(\Subject.sortIndex), SortDescriptor(\Subject.name)]) private var subjects: [Subject]
    @Query(sort: \AudioRecording.createdAt, order: .reverse) private var recordings: [AudioRecording]
    @Query(sort: \GeneratedDocument.updatedAt, order: .reverse) private var documents: [GeneratedDocument]
    @State private var creatingSubject = false
    @State private var startRecording = false
    @State private var importingAudio = false
    @State private var importError: String?

    private let columns = [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 16)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                quickActions
                if subjects.isEmpty {
                    EmptyStateView(title: "Crea la tua prima materia", systemImage: "books.vertical", message: "Le materie raccolgono quaderni, registrazioni, sbobinature e PDF di ogni corso.", actionTitle: "Nuova materia") {
                        creatingSubject = true
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Materie").font(.title2.bold())
                        LazyVGrid(columns: columns, spacing: 16) {
                            ForEach(subjects) { subject in
                                Button {
                                    selection = .subject(subject.id)
                                } label: {
                                    SubjectCard(subject: subject)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    recentSection
                }
            }
            .padding(24)
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Home")
        .sheet(isPresented: $creatingSubject) {
            SubjectEditorSheet(subject: nil) { created in
                if let created { selection = .subject(created.id) }
            }
        }
        .sheet(isPresented: $startRecording) {
            StartRecordingSheet(subject: nil, notebook: nil)
        }
        .fileImporter(isPresented: $importingAudio, allowedContentTypes: ImportService.audioTypes, allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            Task {
                do {
                    _ = try await services.importer.importAudio(from: url, subject: nil)
                } catch {
                    importError = error.readableMessage
                }
            }
        }
        .alert("Importazione non riuscita", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK") { importError = nil }
        } message: {
            Text(importError ?? "")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(greeting)
                .font(.largeTitle.bold())
            Text("Registra, scrivi e lascia che l'AI prepari la sbobinatura.")
                .foregroundStyle(.secondary)
        }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<13: return "Buongiorno"
        case 13..<18: return "Buon pomeriggio"
        default: return "Buonasera"
        }
    }

    private var quickActions: some View {
        HStack(spacing: 12) {
            QuickActionButton(title: recorder.state.isActive ? "Registrazione in corso" : "Registra lezione", systemImage: "record.circle", tint: .red) {
                startRecording = true
            }
            .disabled(recorder.state.isActive)
            QuickActionButton(title: "Importa audio", systemImage: "square.and.arrow.down", tint: .blue) {
                importingAudio = true
            }
            QuickActionButton(title: "Nuova materia", systemImage: "folder.badge.plus", tint: .indigo) {
                creatingSubject = true
            }
        }
    }

    @ViewBuilder
    private var recentSection: some View {
        let recentRecordings = Array(recordings.prefix(5))
        let recentDocuments = Array(documents.prefix(5))
        if !recentRecordings.isEmpty || !recentDocuments.isEmpty {
            HStack(alignment: .top, spacing: 16) {
                if !recentRecordings.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Ultime registrazioni").font(.headline)
                        ForEach(recentRecordings) { recording in
                            NavigationLink {
                                RecordingDetailView(recording: recording)
                            } label: {
                                RecordingRow(recording: recording, showSubject: true)
                            }
                            .buttonStyle(.plain)
                            Divider()
                        }
                    }
                    .padding()
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                if !recentDocuments.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Ultime sbobinature").font(.headline)
                        ForEach(recentDocuments) { document in
                            NavigationLink {
                                DocumentEditorView(document: document)
                            } label: {
                                DocumentRow(document: document, showSubject: true)
                            }
                            .buttonStyle(.plain)
                            Divider()
                        }
                    }
                    .padding()
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
        }
    }
}

struct QuickActionButton: View {
    let title: String
    let systemImage: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
    }
}

struct SubjectCard: View {
    let subject: Subject

    var body: some View {
        let color = Color(hex: subject.colorHex)
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                SubjectIcon(subject: subject, size: 40)
                Spacer()
                if subject.recordings.contains(where: { $0.status == .recording }) {
                    Image(systemName: "record.circle.fill").foregroundStyle(.red)
                }
            }
            Text(subject.name)
                .font(.title3.weight(.semibold))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            HStack(spacing: 14) {
                Label("\(subject.notebooks.count)", systemImage: "book")
                Label("\(subject.recordings.count)", systemImage: "waveform")
                Label("\(subject.documents.count)", systemImage: "doc.text")
                Label("\(subject.materials.count)", systemImage: "doc.richtext")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.background.secondary)
                .overlay(alignment: .topTrailing) {
                    Circle().fill(color.opacity(0.12)).frame(width: 120, height: 120).offset(x: 40, y: -50)
                }
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .contentShape(RoundedRectangle(cornerRadius: 20))
        .hoverEffect(.lift)
        .accessibilityElement(children: .combine)
    }
}
