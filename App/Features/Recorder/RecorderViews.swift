import AVFoundation
import SwiftData
import SwiftUI

/// Indicatore discreto e persistente della registrazione in corso: durata,
/// stato, qualità del segnale, pausa e stop. La durata è letta solo mentre
/// l'indicatore è visibile (TimelineView si sospende in background).
struct RecordingBanner: View {
    var compact = false
    @Environment(RecordingService.self) private var recorder
    @State private var confirmStop = false

    var body: some View {
        HStack(spacing: 12) {
            statusDot
            VStack(alignment: .leading, spacing: 1) {
                Text(statusTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isPaused ? .orange : .red)
                if !compact {
                    Text(recorder.activeTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text(Format.duration(recorder.elapsed))
                    .font(.body.monospacedDigit().weight(.medium))
                    .contentTransition(.numericText())
            }
            TimelineView(.periodic(from: .now, by: 2)) { _ in
                if let message = recorder.signal.quality.message {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.yellow)
                        .help(message)
                        .accessibilityLabel(message)
                }
            }
            Spacer(minLength: 8)
            if case .paused(let reason) = recorder.state, !compact {
                Text(reason.message).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Button {
                if isPaused { recorder.resume() } else { recorder.pause() }
            } label: {
                Image(systemName: isPaused ? "play.fill" : "pause.fill")
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.bordered)
            .clipShape(Circle())
            .accessibilityLabel(isPaused ? "Riprendi registrazione" : "Metti in pausa")
            .disabled(recorder.state == .starting || recorder.state == .stopping)
            Button {
                confirmStop = true
            } label: {
                Label("Stop", systemImage: "stop.fill")
                    .font(.callout.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(recorder.state == .stopping)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.red.opacity(0.25)))
        .confirmationDialog("Terminare la registrazione?", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("Termina e salva", role: .destructive) {
                Task { await recorder.stop() }
            }
            Button("Continua a registrare", role: .cancel) {}
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Registrazione in corso: \(recorder.activeTitle)")
    }

    private var isPaused: Bool {
        if case .paused = recorder.state { return true }
        return false
    }

    private var statusTitle: String {
        switch recorder.state {
        case .starting: return "Avvio…"
        case .recording: return "REC"
        case .paused: return "In pausa"
        case .stopping: return "Salvataggio…"
        case .idle: return ""
        }
    }

    private var statusDot: some View {
        Circle()
            .fill(isPaused ? Color.orange : Color.red)
            .frame(width: 10, height: 10)
            .opacity(recorder.state == .recording ? 1 : 0.6)
    }
}

/// Avvio di una registrazione: materia, quaderno collegato, titolo, profilo
/// e microfono.
struct StartRecordingSheet: View {
    let subject: Subject?
    let notebook: Notebook?
    @Environment(\.dismiss) private var dismiss
    @Environment(RecordingService.self) private var recorder
    @EnvironmentObject private var settings: AppSettings
    @Query(filter: #Predicate<Subject> { $0.archivedAt == nil }, sort: \Subject.name) private var subjects: [Subject]
    @State private var selectedSubjectID: UUID?
    @State private var title = ""
    @State private var inputs: [RecordingService.InputOption] = []
    @State private var isStarting = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Titolo (facoltativo)", text: $title)
                    if subject == nil {
                        Picker("Materia", selection: $selectedSubjectID) {
                            Text("Nessuna").tag(UUID?.none)
                            ForEach(subjects) { Text($0.name).tag(Optional($0.id)) }
                        }
                    } else if let subject {
                        LabeledContent("Materia", value: subject.name)
                    }
                    if let notebook {
                        LabeledContent("Quaderno collegato", value: notebook.title)
                    }
                } footer: {
                    if notebook != nil {
                        Text("Potrai continuare a scrivere: le pagine visitate e modificate verranno collegate ai punti della registrazione.")
                    }
                }
                Section {
                    Picker("Profilo", selection: $settings.recordingProfile) {
                        ForEach(RecordingProfileID.allCases) { id in
                            Text(RecordingProfile.profile(for: id).displayName).tag(id)
                        }
                    }
                    Text(RecordingProfile.profile(for: settings.recordingProfile).summary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Picker("Microfono", selection: $settings.preferredInputUID) {
                        Text("Automatico (sistema)").tag("")
                        ForEach(inputs) { input in
                            Text(input.name).tag(input.id)
                        }
                    }
                } header: {
                    Text("Audio")
                } footer: {
                    Text("In aule grandi un microfono esterno vicino al docente migliora molto la qualità: nessuna elaborazione può recuperare parole non acquisite.")
                }
                Section {
                    LabeledContent("Formato", value: "AAC mono, \(settings.recordingBitrate / 1000) kbps")
                    LabeledContent("Spazio per 3 ore", value: Format.bytes(EncodingSettings(bitrate: settings.recordingBitrate, segmentDuration: 180).bytesPerHour * 3))
                } footer: {
                    Text("La registrazione continua a schermo bloccato e passando ad altre app. Si ferma solo con Stop, se chiudi forzatamente l'app o se il sistema la interrompe (in tal caso l'audio già acquisito viene salvato).")
                }
                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Registra lezione")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annulla") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        start()
                    } label: {
                        if isStarting { ProgressView() } else { Label("Avvia", systemImage: "record.circle") }
                    }
                    .disabled(isStarting || recorder.state.isActive)
                }
            }
            .onAppear {
                inputs = recorder.availableInputs()
                selectedSubjectID = subject?.id
            }
        }
    }

    private func start() {
        isStarting = true
        errorMessage = nil
        let chosenSubject = subject ?? subjects.first { $0.id == selectedSubjectID }
        Task {
            do {
                try await recorder.start(subject: chosenSubject, notebook: notebook, title: title.trimmingCharacters(in: .whitespaces))
                dismiss()
            } catch {
                errorMessage = error.readableMessage
            }
            isStarting = false
        }
    }
}

/// Barra del livello del segnale (solo nelle viste di prova/configurazione).
struct LevelMeterView: View {
    let rmsDB: Float
    let peakDB: Float

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.15))
                Capsule()
                    .fill(LinearGradient(colors: [.green, .green, .yellow, .red], startPoint: .leading, endPoint: .trailing))
                    .frame(width: width * normalized(rmsDB))
                Rectangle()
                    .fill(Color.primary.opacity(0.7))
                    .frame(width: 2)
                    .offset(x: width * normalized(peakDB) - 1)
            }
        }
        .frame(height: 10)
        .accessibilityLabel("Livello \(Int(rmsDB)) dB")
    }

    private func normalized(_ db: Float) -> CGFloat {
        CGFloat(min(1, max(0, (db + 60) / 60)))
    }
}

/// Registrazione di prova di 10 secondi con lo stesso profilo, per
/// verificare livello e qualità prima della lezione.
@MainActor
@Observable
final class TestRecordingController {
    enum Phase: Equatable { case idle, recording, ready, playing, failed(String) }

    private(set) var phase: Phase = .idle
    private(set) var snapshot = SignalAnalyzer.Snapshot(rmsDB: -160, peakDB: -160, quality: .unknown, capturedDuration: 0)
    private let engine = AudioCaptureEngine()
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var directory: URL?
    @ObservationIgnored private var fileURL: URL?

    func start(profileID: RecordingProfileID, gainDB: Double, bitrate: Int) async {
        guard await RecordingService.requestPermission() else {
            phase = .failed("Accesso al microfono negato.")
            return
        }
        let profile = RecordingProfile.profile(for: profileID)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: profile.sessionMode, options: [.defaultToSpeaker])
            try session.setActive(true)
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("test-recording-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            self.directory = directory
            let writer = SegmentedAudioWriter(directory: directory, encoding: EncodingSettings(bitrate: bitrate, segmentDuration: 60))
            engine.analyzer.reset()
            engine.attach(writer: writer)
            engine.setGain(decibels: profile.appliesSoftwareGain ? gainDB : 0)
            try engine.start(voiceProcessing: profile.voiceProcessing)
            phase = .recording
            for _ in 0..<100 {
                try await Task.sleep(nanoseconds: 100_000_000)
                snapshot = engine.analyzer.snapshot()
                if phase != .recording { break }
            }
            engine.stopAndCloseSegment()
            let segments = engine.finishedSegments()
            engine.detachWriter()
            if let first = segments.first {
                fileURL = directory.appendingPathComponent(first.fileName)
                phase = .ready
            } else {
                phase = .failed("Nessun audio acquisito.")
            }
        } catch {
            engine.stopAndCloseSegment()
            phase = .failed(error.readableMessage)
        }
    }

    func stopEarly() {
        if phase == .recording { phase = .ready }
    }

    func play() {
        guard let fileURL else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            player = try AVAudioPlayer(contentsOf: fileURL)
            player?.play()
            phase = .playing
            Task {
                try? await Task.sleep(nanoseconds: UInt64((player?.duration ?? 0) * 1_000_000_000))
                if phase == .playing { phase = .ready }
            }
        } catch {
            phase = .failed(error.readableMessage)
        }
    }

    func cleanup() {
        player?.stop()
        if phase == .recording { engine.stopAndCloseSegment() }
        if let directory { try? FileManager.default.removeItem(at: directory) }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

struct TestRecordingView: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(RecordingService.self) private var recorder
    @State private var controller = TestRecordingController()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if controller.phase == .recording {
                TimelineView(.animation(minimumInterval: 0.1)) { _ in
                    LevelMeterView(rmsDB: controller.snapshot.rmsDB, peakDB: controller.snapshot.peakDB)
                }
                Text(String(format: "Livello: %.0f dBFS (picco %.0f)", controller.snapshot.rmsDB, controller.snapshot.peakDB))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if let message = controller.snapshot.quality.message, controller.phase != .idle {
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
            } else if controller.snapshot.quality == .good {
                Label("Livello del segnale adeguato", systemImage: "checkmark.circle").foregroundStyle(.green).font(.callout)
            }
            HStack {
                switch controller.phase {
                case .idle, .failed:
                    Button("Registrazione di prova (10 s)", systemImage: "mic") {
                        Task { await controller.start(profileID: settings.recordingProfile, gainDB: settings.experimentalGainDB, bitrate: settings.recordingBitrate) }
                    }
                    .disabled(recorder.state.isActive)
                case .recording:
                    Button("Ferma", systemImage: "stop.fill") { controller.stopEarly() }
                case .ready, .playing:
                    Button("Ascolta", systemImage: "play.fill") { controller.play() }
                        .disabled(controller.phase == .playing)
                    Button("Ripeti", systemImage: "arrow.clockwise") {
                        Task { await controller.start(profileID: settings.recordingProfile, gainDB: settings.experimentalGainDB, bitrate: settings.recordingBitrate) }
                    }
                }
            }
            .buttonStyle(.bordered)
            if case .failed(let message) = controller.phase {
                Text(message).foregroundStyle(.red).font(.caption)
            }
            if recorder.state.isActive {
                Text("Non disponibile durante una registrazione.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .onDisappear { controller.cleanup() }
    }
}
