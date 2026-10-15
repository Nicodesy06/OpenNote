import SwiftData
import SwiftUI

struct SidebarView: View {
    @Binding var selection: SidebarItem?
    @Binding var showSettings: Bool
    @Environment(AppServices.self) private var services
    @Environment(JobRunner.self) private var jobRunner
    @Query(filter: #Predicate<Subject> { $0.archivedAt == nil }, sort: [SortDescriptor(\Subject.sortIndex), SortDescriptor(\Subject.name)]) private var subjects: [Subject]
    @Query private var jobs: [ProcessingJob]
    @State private var editingSubject: Subject?
    @State private var creatingSubject = false
    @State private var subjectToDelete: Subject?
    @State private var searchText = ""

    private var activeJobCount: Int {
        jobs.filter { !$0.state.isTerminal && $0.state != .failed }.count
    }

    var body: some View {
        List(selection: $selection) {
            if !searchText.isEmpty {
                Section {
                    NavigationLink {
                        SearchResultsView(query: searchText)
                    } label: {
                        Label("Cerca «\(searchText)»", systemImage: "magnifyingglass")
                    }
                }
            }
            Section("Libreria") {
                Label("Home", systemImage: "house").tag(SidebarItem.home)
                Label("Recenti", systemImage: "clock").tag(SidebarItem.recent)
                Label {
                    HStack {
                        Text("Elaborazioni AI")
                        Spacer()
                        if activeJobCount > 0 {
                            Text("\(activeJobCount)")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(.tint.opacity(0.15), in: Capsule())
                        }
                    }
                } icon: {
                    Image(systemName: jobRunner.runningJobID != nil ? "sparkles" : "tray.full")
                        .symbolEffect(.pulse, isActive: jobRunner.runningJobID != nil)
                }
                .tag(SidebarItem.jobs)
            }
            Section("Materie") {
                ForEach(subjects) { subject in
                    Label {
                        Text(subject.name)
                    } icon: {
                        SubjectIcon(subject: subject, size: 24)
                    }
                    .tag(SidebarItem.subject(subject.id))
                    .contextMenu {
                        Button("Modifica", systemImage: "pencil") { editingSubject = subject }
                        Button("Archivia", systemImage: "archivebox") { services.content.archive(subject, archived: true) }
                        Divider()
                        Button("Elimina…", systemImage: "trash", role: .destructive) { subjectToDelete = subject }
                    }
                }
                .onMove { source, destination in
                    var ordered = subjects
                    ordered.move(fromOffsets: source, toOffset: destination)
                    for (index, subject) in ordered.enumerated() { subject.sortIndex = index }
                    services.content.save()
                }
                Button {
                    creatingSubject = true
                } label: {
                    Label("Nuova materia", systemImage: "plus.circle")
                }
            }
            Section {
                Label("Archivio", systemImage: "archivebox").tag(SidebarItem.archive)
                Button {
                    showSettings = true
                } label: {
                    Label("Impostazioni", systemImage: "gearshape")
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Quaderno AI")
        .searchable(text: $searchText, placement: .sidebar, prompt: "Cerca in tutto")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    creatingSubject = true
                } label: {
                    Label("Nuova materia", systemImage: "folder.badge.plus")
                }
            }
        }
        .sheet(isPresented: $creatingSubject) {
            SubjectEditorSheet(subject: nil) { created in
                if let created { selection = .subject(created.id) }
            }
        }
        .sheet(item: $editingSubject) { subject in
            SubjectEditorSheet(subject: subject)
        }
        .confirmationDialog("Eliminare la materia?", isPresented: Binding(get: { subjectToDelete != nil }, set: { if !$0 { subjectToDelete = nil } }), titleVisibility: .visible) {
            Button("Elimina materia e tutti i contenuti", role: .destructive) {
                if let subject = subjectToDelete {
                    if selection == .subject(subject.id) { selection = .home }
                    services.content.delete(subject)
                }
                subjectToDelete = nil
            }
            Button("Archivia invece", systemImage: "archivebox") {
                if let subject = subjectToDelete { services.content.archive(subject, archived: true) }
                subjectToDelete = nil
            }
            Button("Annulla", role: .cancel) { subjectToDelete = nil }
        } message: {
            Text("Verranno eliminati definitivamente quaderni, registrazioni, sbobinature e PDF di «\(subjectToDelete?.name ?? "")». L'operazione non è reversibile: se vuoi solo nasconderla, archiviala.")
        }
    }
}
