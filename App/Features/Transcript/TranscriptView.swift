import AVFoundation
import SwiftData
import SwiftUI
import QuadernoCore

/// Trascrizione originale con tempi: tocca un segmento per ascoltarlo,
/// modificane il testo, controlla la diagnostica della ricomposizione.
struct TranscriptView: View {
    @Bindable var transcript: Transcript
    let recording: AudioRecording
    @Environment(AppServices.self) private var services
    @Environment(PlaybackService.self) private var playback
    @State private var searchText = ""
    @State private var editing: TranscriptSegment?
    @State private var generate = false
    @State private var exported: ExportedFile?
    @State private var showReport = false

    private var segments: [TranscriptSegment] {
        let ordered = transcript.orderedSegments
        guard !searchText.isEmpty else { return ordered }
        return ordered.filter { $0.text.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        List {
            Section {
                PlayerControls(recordingID: recording.id)
                    .task { await loadPlayer() }
                if transcript.precision != .exact {
                    Label("I tempi sono approssimati (il modello non restituisce timestamp per frase): il salto all'audio porta vicino al punto, non esattamente.", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let report = transcript.report, !report.unresolvedOverlapChunks.isEmpty || !report.emptyChunks.isEmpty || !report.removedSuspectPhrases.isEmpty {
                    Button {
                        showReport = true
                    } label: {
                        Label("Diagnostica della trascrizione", systemImage: "stethoscope")
                    }
                }
            }
            Section("\(transcript.segments.count) segmenti · \(transcript.providerID) \(transcript.model)") {
                ForEach(segments) { segment in
                    SegmentRow(segment: segment, isPlaying: isPlaying(segment)) {
                        playback.seek(to: segment.start)
                        playback.play()
                    } onEdit: {
                        editing = segment
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $searchText, prompt: "Cerca nella trascrizione")
        .navigationTitle("Trascrizione")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Crea sbobinatura", systemImage: "sparkles") { generate = true }
                Menu {
                    Button("Testo semplice (.txt)", systemImage: "doc.plaintext") { export(format: .text) }
                    Button("Con tempi (.txt)", systemImage: "clock") { export(format: .timed) }
                    Button("Word (.docx)", systemImage: "doc.richtext") { export(format: .docx) }
                } label: {
                    Label("Esporta", systemImage: "square.and.arrow.up")
                }
            }
        }
        .sheet(item: $editing) { segment in
            SegmentEditor(segment: segment) {
                transcript.isEdited = true
                transcript.refreshSearchText()
                services.content.save()
            }
        }
        .sheet(isPresented: $generate) { GenerateSheet(recording: recording, kind: .documentOnly) }
        .sheet(item: $exported) { file in ShareSheet(items: [file.url]) }
        .sheet(isPresented: $showReport) { TranscriptReportView(report: transcript.report) }
    }

    private func isPlaying(_ segment: TranscriptSegment) -> Bool {
        playback.currentRecordingID == recording.id && playback.currentTime >= segment.start && playback.currentTime < segment.end
    }

    private func loadPlayer() async {
        if let url = services.maintenance.playableURL(for: recording) {
            playback.load(recordingID: recording.id, title: recording.title, asset: AVURLAsset(url: url), knownDuration: recording.duration)
        } else if let composition = await services.maintenance.compositionForSegments(of: recording) {
            playback.load(recordingID: recording.id, title: recording.title, asset: composition, knownDuration: recording.duration)
        }
    }

    enum ExportFormat { case text, timed, docx }

    private func export(format: ExportFormat) {
        let ordered = transcript.orderedSegments
        let base = FileStore.sanitizedFileName("Trascrizione - \(recording.title)")
        do {
            switch format {
            case .text:
                let url = services.fileStore.newExportURL(fileName: base + ".txt")
                try ordered.map(\.text).joined(separator: "\n\n").write(to: url, atomically: true, encoding: .utf8)
                exported = ExportedFile(url: url)
            case .timed:
                let url = services.fileStore.newExportURL(fileName: base + " (tempi).txt")
                let text = ordered.map { "[\(TranscriptFormatter.timestamp($0.start))]\($0.speaker.map { " \($0):" } ?? "") \($0.text)" }.joined(separator: "\n")
                try text.write(to: url, atomically: true, encoding: .utf8)
                exported = ExportedFile(url: url)
            case .docx:
                let markdown = "# Trascrizione — \(recording.title)\n\n" + ordered.map { "**\(TranscriptFormatter.timestamp($0.start))** \($0.text)" }.joined(separator: "\n\n")
                let data = DocxExporter(title: recording.title).export(markdown: markdown)
                let url = services.fileStore.newExportURL(fileName: base + ".docx")
                try data.write(to: url, options: .atomic)
                exported = ExportedFile(url: url)
            }
        } catch {
            // L'errore è raro (spazio esaurito): nessun file da condividere.
        }
    }
}

private struct SegmentRow: View {
    let segment: TranscriptSegment
    let isPlaying: Bool
    let onPlay: () -> Void
    let onEdit: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: onPlay) {
                Text(TranscriptFormatter.timestamp(segment.start))
                    .font(.caption.monospacedDigit())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(isPlaying ? Color.accentColor : Color.accentColor.opacity(0.12), in: Capsule())
                    .foregroundStyle(isPlaying ? .white : .accentColor)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Ascolta da \(TranscriptFormatter.timestamp(segment.start))")
            VStack(alignment: .leading, spacing: 4) {
                if let speaker = segment.speaker {
                    Text(speaker).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                Text(segment.text)
                    .font(.body)
                    .textSelection(.enabled)
                if segment.isEdited {
                    Text("Modificato").font(.caption2).foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button("Ascolta da qui", systemImage: "play") { onPlay() }
            Button("Modifica testo", systemImage: "pencil") { onEdit() }
        }
    }
}

private struct SegmentEditor: View {
    @Bindable var segment: TranscriptSegment
    let onSave: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Testo") {
                    TextEditor(text: $text).frame(minHeight: 160)
                }
                if segment.isEdited {
                    Section("Originale del provider") {
                        Text(segment.originalText).foregroundStyle(.secondary)
                        Button("Ripristina l'originale") { text = segment.originalText }
                    }
                }
            }
            .navigationTitle("Segmento \(TranscriptFormatter.timestamp(segment.start))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annulla") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Salva") {
                        segment.text = text
                        onSave()
                        dismiss()
                    }
                }
            }
            .onAppear { text = segment.text }
        }
    }
}

struct TranscriptReportView: View {
    let report: TranscriptMergeReport?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let report {
                    Section {
                        LabeledContent("Parti elaborate", value: "\(report.chunkCount)")
                        LabeledContent("Copertura", value: report.isComplete ? "Completa" : "Incompleta")
                    }
                    if !report.unresolvedOverlapChunks.isEmpty {
                        Section {
                            Text("Al confine delle parti \(report.unresolvedOverlapChunks.map { "\($0)" }.joined(separator: ", ")) potrebbero esserci alcune parole ripetute: la sovrapposizione non è stata riconosciuta automaticamente.")
                        } header: { Text("Possibili ripetizioni") }
                    }
                    if !report.emptyChunks.isEmpty {
                        Section {
                            Text("Le parti \(report.emptyChunks.map { "\($0)" }.joined(separator: ", ")) non contengono parlato riconosciuto (silenzio, pausa o audio troppo debole).")
                        } header: { Text("Parti senza testo") }
                    }
                    if !report.removedSuspectPhrases.isEmpty {
                        Section {
                            ForEach(report.removedSuspectPhrases, id: \.self) { Text($0) }
                        } header: {
                            Text("Frasi rimosse")
                        } footer: {
                            Text("Frasi tipiche generate dai modelli su silenzio o rumore (es. crediti di sottotitoli), rimosse perché non pronunciate a lezione.")
                        }
                    }
                } else {
                    Text("Diagnostica non disponibile.")
                }
            }
            .navigationTitle("Diagnostica")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fine") { dismiss() } } }
        }
    }
}
