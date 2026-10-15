import AVFoundation
import SwiftData
import SwiftUI

struct RecordingDetailView: View {
    @Bindable var recording: AudioRecording
    @Environment(AppServices.self) private var services
    @Environment(PlaybackService.self) private var playback
    @Environment(RecordingService.self) private var recorder
    @Environment(JobRunner.self) private var jobRunner
    @Environment(\.dismiss) private var dismiss
    @Query private var jobs: [ProcessingJob]
    @State private var generateKind: GenerateSheet.Kind?
    @State private var renaming = false
    @State private var confirmDelete = false
    @State private var shareURL: ExportedFile?
    @State private var openNotebook: Notebook?
    @State private var loadError: String?

    init(recording: AudioRecording) {
        self.recording = recording
        let id = recording.id
        _jobs = Query(filter: #Predicate<ProcessingJob> { $0.recordingID == id }, sort: \ProcessingJob.createdAt, order: .reverse)
    }

    private var isActiveRecording: Bool { recorder.activeRecordingID == recording.id }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(recording.title).font(.title2.bold())
                        Spacer()
                        if recording.status != .ready {
                            StatusBadge(text: recording.status.displayName, color: recording.status == .damaged ? .red : .orange)
                        }
                    }
                    HStack(spacing: 8) {
                        if let subject = recording.subject {
                            SubjectIcon(subject: subject, size: 20)
                            Text(subject.name)
                        }
                        Text(Format.date(recording.recordedAt, time: true))
                        Text("·")
                        Text(Format.spokenDuration(recording.duration))
                        if recording.byteSize > 0 {
                            Text("·")
                            Text(Format.bytes(recording.byteSize))
                        }
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    if let input = recording.inputDescription, let profile = recording.profileName {
                        Text("\(profile) · \(input)").font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 6)
            }

            if isActiveRecording {
                Section {
                    Label("Registrazione in corso: l'audio sarà disponibile dopo lo Stop.", systemImage: "record.circle")
                        .foregroundStyle(.red)
                }
            } else if recording.status == .damaged {
                Section {
                    Label("Il file audio non è disponibile o è danneggiato.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            } else {
                Section("Riproduzione") {
                    PlayerControls(recordingID: recording.id)
                        .task { await loadIntoPlayer() }
                }
            }

            if !jobs.isEmpty {
                Section("Elaborazioni") {
                    ForEach(jobs.prefix(3)) { job in
                        JobRow(job: job)
                    }
                }
            }

            Section("Trascrizioni e sbobinature") {
                ForEach(recording.transcripts.sorted { $0.createdAt > $1.createdAt }) { transcript in
                    NavigationLink {
                        TranscriptView(transcript: transcript, recording: recording)
                    } label: {
                        Label {
                            VStack(alignment: .leading) {
                                Text("Trascrizione del \(Format.date(transcript.createdAt, time: true))")
                                Text("\(transcript.providerID) · \(transcript.model) · \(transcript.segments.count) segmenti").font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "text.quote")
                        }
                    }
                }
                ForEach(recording.documents.sorted { $0.createdAt > $1.createdAt }) { document in
                    NavigationLink {
                        DocumentEditorView(document: document)
                    } label: {
                        DocumentRow(document: document, showSubject: false)
                    }
                }
                if !isActiveRecording && recording.status != .damaged {
                    Button {
                        generateKind = .full
                    } label: {
                        Label("Trascrivi e crea sbobinatura", systemImage: "sparkles")
                    }
                    Button {
                        generateKind = .transcriptionOnly
                    } label: {
                        Label("Solo trascrizione", systemImage: "text.quote")
                    }
                    if recording.latestTranscript != nil {
                        Button {
                            generateKind = .documentOnly
                        } label: {
                            Label("Nuova sbobinatura dalla trascrizione esistente", systemImage: "doc.badge.plus")
                        }
                    }
                }
            }

            if let notebook = recording.notebook {
                Section("Appunti collegati") {
                    Button {
                        openNotebook = notebook
                    } label: {
                        Label(notebook.title, systemImage: "book")
                    }
                    if !recording.pageMarks.isEmpty {
                        ForEach(recording.pageMarks.sorted { $0.time < $1.time }.prefix(50)) { mark in
                            Button {
                                playback.seek(to: mark.time)
                                playback.play()
                            } label: {
                                HStack {
                                    Text(Format.duration(mark.time)).monospacedDigit().foregroundStyle(.tint)
                                    Text(mark.kind == .edited ? "Scrittura a pagina \(mark.pageIndex + 1)" : "Aperta pagina \(mark.pageIndex + 1)")
                                        .foregroundStyle(.primary)
                                }
                            }
                        }
                    }
                }
            }

            Section("Note") {
                TextField("Note sulla lezione", text: $recording.notes, axis: .vertical)
                    .lineLimit(2...6)
            }
        }
        .navigationTitle(recording.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Rinomina", systemImage: "pencil") { renaming = true }
                    MoveToSubjectMenu(current: recording.subject) { services.content.move(recording, to: $0) }
                    Button("Condividi audio", systemImage: "square.and.arrow.up") {
                        if let url = services.maintenance.playableURL(for: recording) { shareURL = ExportedFile(url: url) }
                    }
                    .disabled(services.maintenance.playableURL(for: recording) == nil)
                    Divider()
                    Button("Elimina…", systemImage: "trash", role: .destructive) { confirmDelete = true }
                        .disabled(isActiveRecording)
                } label: {
                    Label("Altro", systemImage: "ellipsis.circle")
                }
            }
        }
        .sheet(item: $generateKind) { kind in
            GenerateSheet(recording: recording, kind: kind)
        }
        .sheet(item: $shareURL) { file in ShareSheet(items: [file.url]) }
        .fullScreenCover(item: $openNotebook) { notebook in NotebookEditorView(notebook: notebook) }
        .renameAlert(isPresented: $renaming, initial: recording.title) { title in
            recording.title = title
            services.content.save()
        }
        .confirmationDialog("Eliminare la registrazione?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Elimina solo l'audio e le trascrizioni", role: .destructive) { delete(documents: false) }
            if !recording.documents.isEmpty {
                Button("Elimina anche le sbobinature", role: .destructive) { delete(documents: true) }
            }
            Button("Annulla", role: .cancel) {}
        } message: {
            Text("L'audio verrà eliminato definitivamente dal dispositivo.")
        }
        .alert("Audio non disponibile", isPresented: Binding(get: { loadError != nil }, set: { if !$0 { loadError = nil } })) {
            Button("OK") { loadError = nil }
        } message: {
            Text(loadError ?? "")
        }
    }

    private func loadIntoPlayer() async {
        if let url = services.maintenance.playableURL(for: recording) {
            playback.load(recordingID: recording.id, title: recording.title, asset: AVURLAsset(url: url), knownDuration: recording.duration)
        } else if let composition = await services.maintenance.compositionForSegments(of: recording) {
            playback.load(recordingID: recording.id, title: recording.title, asset: composition, knownDuration: recording.duration)
        } else if recording.status != .finalizing {
            loadError = "Nessun file audio trovato per questa registrazione."
        }
    }

    private func delete(documents: Bool) {
        if playback.currentRecordingID == recording.id { playback.stop() }
        services.content.delete(recording, deleteDocuments: documents)
        dismiss()
    }
}

/// Controlli di riproduzione con barra temporale.
struct PlayerControls: View {
    let recordingID: UUID
    @Environment(PlaybackService.self) private var playback
    @State private var scrubbing = false
    @State private var scrubValue: Double = 0

    private var isCurrent: Bool { playback.currentRecordingID == recordingID }

    var body: some View {
        VStack(spacing: 10) {
            Slider(value: Binding(get: { scrubbing ? scrubValue : (isCurrent ? playback.currentTime : 0) }, set: { scrubValue = $0 }),
                   in: 0...max(playback.duration, 1)) { editing in
                scrubbing = editing
                if !editing { playback.seek(to: scrubValue) }
            }
            .disabled(!isCurrent)
            HStack {
                Text(Format.duration(scrubbing ? scrubValue : (isCurrent ? playback.currentTime : 0))).monospacedDigit()
                Spacer()
                Button { playback.skip(by: -15) } label: { Image(systemName: "gobackward.15").font(.title2) }
                    .accessibilityLabel("Indietro di 15 secondi")
                Button { playback.togglePlay() } label: {
                    Image(systemName: playback.isPlaying && isCurrent ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 44))
                }
                .accessibilityLabel(playback.isPlaying ? "Pausa" : "Riproduci")
                .padding(.horizontal, 20)
                Button { playback.skip(by: 15) } label: { Image(systemName: "goforward.15").font(.title2) }
                    .accessibilityLabel("Avanti di 15 secondi")
                Spacer()
                Menu {
                    ForEach(PlaybackService.rates, id: \.self) { rate in
                        Button(String(format: "%gx", rate)) { playback.setRate(rate) }
                    }
                } label: {
                    Text(String(format: "%gx", playback.rate)).monospacedDigit().frame(minWidth: 44)
                }
                Text(Format.duration(playback.duration)).monospacedDigit()
            }
            .buttonStyle(.borderless)
            .disabled(!isCurrent)
        }
        .padding(.vertical, 6)
        .onAppear { playback.startObservingTime() }
        .onDisappear { playback.stopObservingTime() }
    }
}
