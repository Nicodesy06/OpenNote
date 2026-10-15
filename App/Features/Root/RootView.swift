import SwiftData
import SwiftUI

enum SidebarItem: Hashable {
    case home
    case recent
    case jobs
    case archive
    case subject(UUID)
}

/// Struttura principale: Libreria → Materia → contenuti, con indicatore di
/// registrazione sempre visibile.
struct RootView: View {
    @Environment(AppServices.self) private var services
    @Environment(RecordingService.self) private var recorder
    @Environment(\.modelContext) private var modelContext
    @State private var selection: SidebarItem? = .home
    @State private var showSettings = false
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var generateFor: AudioRecording?
    @State private var postRecordingID: UUID?
    @State private var showStartupNotice = false

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(selection: $selection, showSettings: $showSettings)
        } detail: {
            NavigationStack {
                detail
            }
            .id(selection)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if recorder.state.isActive && !services.isEditorPresented {
                RecordingBanner()
                    .padding(.horizontal)
                    .padding(.top, 4)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: recorder.state.isActive)
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(item: $generateFor) { recording in
            GenerateSheet(recording: recording)
        }
        .sheet(isPresented: Binding(get: { !services.pendingIncomingFiles.isEmpty }, set: { if !$0 { services.pendingIncomingFiles.removeAll() } })) {
            IncomingFilesSheet()
        }
        .onChange(of: recorder.lastFinishedRecordingID) { _, id in
            guard let id, !services.isEditorPresented else { return }
            postRecordingID = id
        }
        .alert("Registrazione salvata", isPresented: Binding(get: { postRecordingID != nil }, set: { if !$0 { postRecordingID = nil } })) {
            Button("Trascrivi e crea sbobinatura") {
                if let id = postRecordingID { generateFor = fetchRecording(id) }
                postRecordingID = nil
            }
            Button("Più tardi", role: .cancel) { postRecordingID = nil }
        } message: {
            Text("L'audio è salvato sul dispositivo. Vuoi trascriverlo e creare la sbobinatura?")
        }
        .alert("Avviso", isPresented: $showStartupNotice) {
            Button("OK") { services.startupNotice = nil }
        } message: {
            Text(services.startupNotice ?? "")
        }
        .onAppear { showStartupNotice = services.startupNotice != nil }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .home, .none:
            HomeView(selection: $selection)
        case .recent:
            RecentView()
        case .jobs:
            JobsView()
        case .archive:
            ArchiveView()
        case .subject(let id):
            SubjectDetailContainer(subjectID: id)
        }
    }

    private func fetchRecording(_ id: UUID) -> AudioRecording? {
        try? modelContext.fetch(FetchDescriptor<AudioRecording>(predicate: #Predicate { $0.id == id })).first
    }
}

/// Carica la materia selezionata (o mostra uno stato vuoto se eliminata).
struct SubjectDetailContainer: View {
    let subjectID: UUID
    @Query private var subjects: [Subject]

    init(subjectID: UUID) {
        self.subjectID = subjectID
        _subjects = Query(filter: #Predicate<Subject> { $0.id == subjectID })
    }

    var body: some View {
        if let subject = subjects.first {
            SubjectDetailView(subject: subject)
        } else {
            EmptyStateView(title: "Materia non trovata", systemImage: "questionmark.folder", message: "La materia potrebbe essere stata eliminata.")
        }
    }
}
