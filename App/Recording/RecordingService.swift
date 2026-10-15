import AVFoundation
import Observation
import SwiftData
import UIKit
import UserNotifications
import os

/// Servizio di registrazione delle lezioni, separato dal ciclo di vita delle
/// viste: l'editor dei quaderni, la libreria e le altre schermate possono
/// comparire e scomparire senza influire sull'acquisizione.
///
/// La durata mostrata deriva dai campioni effettivamente acquisiti, non da
/// timer. L'interfaccia la legge solo quando è visibile (TimelineView).
@MainActor
@Observable
final class RecordingService {
    enum State: Equatable {
        case idle
        case starting
        case recording
        case paused(PauseReason)
        case stopping

        var isActive: Bool {
            switch self {
            case .idle: return false
            default: return true
            }
        }
    }

    enum PauseReason: Equatable {
        case user
        case interruption
        case error(String)

        var message: String {
            switch self {
            case .user: return "In pausa"
            case .interruption: return "In pausa per un'interruzione (es. chiamata)"
            case .error(let message): return message
            }
        }
    }

    enum StartError: Error, LocalizedError {
        case permissionDenied
        case insufficientStorage(available: Int64)
        case alreadyRecording
        case session(String)

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return "L'accesso al microfono non è consentito. Abilitalo in Impostazioni › Privacy › Microfono."
            case .insufficientStorage(let available):
                return "Spazio insufficiente per registrare (\(ByteCountFormatter.string(fromByteCount: available, countStyle: .file)) liberi)."
            case .alreadyRecording:
                return "È già in corso una registrazione."
            case .session(let message):
                return "Configurazione audio non riuscita: \(message)"
            }
        }
    }

    struct InputOption: Identifiable, Hashable {
        let id: String
        let name: String
        let portType: String
        let dataSources: [DataSourceOption]
    }

    struct DataSourceOption: Identifiable, Hashable {
        let id: Int
        let name: String
    }

    private(set) var state: State = .idle
    private(set) var activeRecordingID: UUID?
    private(set) var activeTitle = ""
    private(set) var activeSubjectID: UUID?
    private(set) var activeNotebookID: UUID?
    private(set) var startedAt: Date?
    private(set) var inputName = ""
    private(set) var lastError: String?
    /// Ultima registrazione conclusa (per proporre la trascrizione).
    private(set) var lastFinishedRecordingID: UUID?

    private let fileStore: FileStore
    private let modelContainer: ModelContainer
    private let settings: AppSettings
    private let capture = AudioCaptureEngine()
    private let manifestWriter: ManifestWriter
    @ObservationIgnored private var manifest: RecordingManifest?
    @ObservationIgnored private var writer: SegmentedAudioWriter?
    @ObservationIgnored private var profile = RecordingProfile.profile(for: .classroom)
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var lastMarkedPage: (id: UUID, time: TimeInterval, kind: PageMarkKind)?
    @ObservationIgnored private var markPersistTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "QuadernoAI", category: "RecordingService")
    /// Callback per avviare il consolidamento a fine registrazione.
    @ObservationIgnored var onRecordingFinished: ((UUID) -> Void)?

    /// Margine minimo di spazio libero per iniziare (≈ 3 ore a 96 kbps + DB).
    static let minimumFreeSpace: Int64 = 200 * 1024 * 1024

    init(fileStore: FileStore, modelContainer: ModelContainer, settings: AppSettings) {
        self.fileStore = fileStore
        self.modelContainer = modelContainer
        self.settings = settings
        self.manifestWriter = ManifestWriter(fileStore: fileStore)
        capture.onWriteError = { [weak self] error in
            Task { @MainActor in self?.handleWriteFailure(error) }
        }
        registerObservers()
    }

    // MARK: - Lettura per l'interfaccia (chiamare solo da viste visibili)

    var elapsed: TimeInterval {
        capture.analyzer.snapshot().capturedDuration
    }

    var signal: SignalAnalyzer.Snapshot {
        capture.analyzer.snapshot()
    }

    var isRecordingOrPaused: Bool { state.isActive }

    // MARK: - Avvio

    func start(subject: Subject?, notebook: Notebook?, title: String? = nil) async throws {
        guard state == .idle else { throw StartError.alreadyRecording }
        state = .starting
        lastError = nil
        do {
            guard await Self.requestPermission() else { throw StartError.permissionDenied }
            let available = fileStore.availableCapacity()
            guard available > Self.minimumFreeSpace else { throw StartError.insufficientStorage(available: available) }

            profile = RecordingProfile.profile(for: settings.recordingProfile)
            try configureSession()

            let context = modelContainer.mainContext
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "it_IT")
            formatter.dateFormat = "d MMMM yyyy, HH:mm"
            let defaultTitle = "Lezione del \(formatter.string(from: Date()))"
            let recording = AudioRecording(title: title?.isEmpty == false ? title! : defaultTitle, source: .recorded, status: .recording)
            recording.subject = subject
            recording.notebook = notebook
            recording.profileName = profile.displayName
            recording.inputDescription = currentInputName()
            context.insert(recording)
            try context.save()

            let directory = fileStore.recordingDirectory(recording.id)
            let encoding = EncodingSettings(bitrate: settings.recordingBitrate, segmentDuration: max(60, settings.segmentMinutes * 60))
            let writer = SegmentedAudioWriter(directory: directory, encoding: encoding)
            writer.onSegmentClosed = { [weak self] segment in
                Task { @MainActor in self?.segmentClosed(segment) }
            }
            writer.onSegmentOpened = { [weak self] segment in
                Task { @MainActor in self?.segmentOpened(segment) }
            }
            self.writer = writer
            capture.analyzer.reset()
            capture.resetWriteFailure()
            capture.attach(writer: writer)
            capture.setGain(decibels: profile.appliesSoftwareGain ? settings.experimentalGainDB : 0)

            manifest = RecordingManifest(recordingID: recording.id, subjectID: subject?.id, notebookID: notebook?.id, title: recording.title, startedAt: Date(), updatedAt: Date(), status: .recording, profile: profile.id.rawValue, bitrate: encoding.bitrate, inputDescription: recording.inputDescription, segments: [], marks: [], interruptions: [])
            manifestWriter.persistSynchronously(manifest!)

            try capture.start(voiceProcessing: profile.voiceProcessing)

            activeRecordingID = recording.id
            activeTitle = recording.title
            activeSubjectID = subject?.id
            activeNotebookID = notebook?.id
            startedAt = Date()
            inputName = currentInputName()
            state = .recording
            if settings.notifyOnInterruption { Self.requestNotificationPermission() }
            logger.info("Registrazione avviata")
        } catch {
            state = .idle
            capture.detachWriter()
            writer = nil
            if let id = manifest?.recordingID {
                discardEmptyRecording(id)
            }
            manifest = nil
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            throw error
        }
    }

    static func requestPermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied: return false
        default: return await AVAudioApplication.requestRecordPermission()
        }
    }

    private func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        do {
            var options: AVAudioSession.CategoryOptions = [.defaultToSpeaker, .allowBluetoothA2DP]
            if let preferred = preferredInput(), preferred.portType == .bluetoothHFP {
                options.insert(.allowBluetooth)
            }
            try session.setCategory(.playAndRecord, mode: profile.sessionMode, options: options)
            try? session.setPreferredSampleRate(48_000)
            // Buffer di I/O ampio: meno risvegli della CPU, minor consumo.
            try? session.setPreferredIOBufferDuration(0.093)
            try session.setActive(true)
            if let preferred = preferredInput() {
                try? session.setPreferredInput(preferred)
                if settings.preferredDataSourceID >= 0,
                   let source = preferred.dataSources?.first(where: { $0.dataSourceID.intValue == settings.preferredDataSourceID }) {
                    try? preferred.setPreferredDataSource(source)
                }
            }
        } catch {
            throw StartError.session(error.localizedDescription)
        }
    }

    private func preferredInput() -> AVAudioSessionPortDescription? {
        guard !settings.preferredInputUID.isEmpty else { return nil }
        return AVAudioSession.sharedInstance().availableInputs?.first { $0.uid == settings.preferredInputUID }
    }

    func availableInputs() -> [InputOption] {
        let session = AVAudioSession.sharedInstance()
        if session.category != .playAndRecord && session.category != .record {
            try? session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
        }
        return (session.availableInputs ?? []).map { port in
            InputOption(id: port.uid, name: port.portName, portType: port.portType.rawValue,
                        dataSources: (port.dataSources ?? []).map { DataSourceOption(id: $0.dataSourceID.intValue, name: $0.dataSourceName) })
        }
    }

    private func currentInputName() -> String {
        AVAudioSession.sharedInstance().currentRoute.inputs.first?.portName ?? "Microfono integrato"
    }

    // MARK: - Pausa / ripresa / stop

    func pause() {
        guard state == .recording else { return }
        capture.stopAndCloseSegment()
        state = .paused(.user)
        manifest?.status = .paused
        persistManifest()
    }

    func resume() {
        guard case .paused = state else { return }
        do {
            try configureSession()
            capture.resetWriteFailure()
            try capture.start(voiceProcessing: profile.voiceProcessing)
            state = .recording
            manifest?.status = .recording
            persistManifest()
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            state = .paused(.error(lastError ?? "Ripresa non riuscita"))
        }
    }

    /// Ferma la registrazione, salva i segmenti e avvia l'unione in un unico
    /// file. Restituisce l'identificativo della registrazione.
    @discardableResult
    func stop() async -> UUID? {
        guard state.isActive, let recordingID = activeRecordingID else { return nil }
        state = .stopping
        capture.stopAndCloseSegment()
        let segments = capture.finishedSegments()
        capture.detachWriter()
        manifest?.segments = segments
        manifest?.status = .finished
        manifest?.updatedAt = Date()
        if let manifest { manifestWriter.persistSynchronously(manifest) }
        markPersistTask?.cancel()

        // Aggiornamento del database: segmenti, segnalibri di pagina, durata.
        let context = modelContainer.mainContext
        if let recording = fetchRecording(recordingID, in: context) {
            apply(manifest: manifest, segments: segments, to: recording, context: context)
            recording.status = .finalizing
            try? context.save()
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        lastFinishedRecordingID = recordingID
        resetActiveState()
        onRecordingFinished?(recordingID)
        return recordingID
    }

    private func resetActiveState() {
        state = .idle
        activeRecordingID = nil
        activeTitle = ""
        activeSubjectID = nil
        activeNotebookID = nil
        startedAt = nil
        manifest = nil
        writer = nil
        lastMarkedPage = nil
    }

    private func apply(manifest: RecordingManifest?, segments: [SegmentedAudioWriter.Segment], to recording: AudioRecording, context: ModelContext) {
        for existing in recording.segments { context.delete(existing) }
        var offset: TimeInterval = 0
        for segment in segments {
            let model = AudioSegment(index: segment.index, fileName: segment.fileName, startOffset: offset, duration: segment.duration)
            model.recording = recording
            context.insert(model)
            offset += segment.duration
        }
        recording.duration = offset
        recording.byteSize = segments.reduce(0) { $0 + fileStore.size(of: fileStore.recordingFileURL(recordingID: recording.id, fileName: $1.fileName)) }
        if let marks = manifest?.marks {
            let existing = Set(recording.pageMarks.map { "\($0.pageID)-\($0.time)" })
            for mark in marks where !existing.contains("\(mark.pageID)-\(mark.time)") {
                let model = PageMark(pageID: mark.pageID, pageIndex: mark.pageIndex, time: mark.time, kind: PageMarkKind(rawValue: mark.kind) ?? .visited)
                model.recording = recording
                context.insert(model)
            }
        }
    }

    private func fetchRecording(_ id: UUID, in context: ModelContext) -> AudioRecording? {
        let descriptor = FetchDescriptor<AudioRecording>(predicate: #Predicate { $0.id == id })
        return try? context.fetch(descriptor).first
    }

    private func discardEmptyRecording(_ id: UUID) {
        let context = modelContainer.mainContext
        if let recording = fetchRecording(id, in: context), recording.segments.isEmpty {
            context.delete(recording)
            try? context.save()
        }
        fileStore.removeItemIfExists(fileStore.recordingsDirectory.appendingPathComponent(id.uuidString))
    }

    // MARK: - Segnalibri di pagina (sincronizzazione audio-appunti)

    /// Registra la visita o la modifica di una pagina del quaderno durante la
    /// registrazione. I segnalibri vengono salvati nel manifest (scrittura
    /// differita) e nel database allo Stop, senza scritture continue.
    func markPage(pageID: UUID, pageIndex: Int, kind: PageMarkKind) {
        guard state == .recording, manifest != nil else { return }
        let time = elapsed
        if let last = lastMarkedPage, last.id == pageID {
            // Pagina già segnata: una nuova visita non aggiunge nulla e una
            // modifica viene registrata al più una volta al minuto.
            if kind == .visited { return }
            if last.kind == .edited && time - last.time < 60 { return }
        }
        lastMarkedPage = (pageID, time, kind)
        manifest?.marks.append(RecordingManifest.Mark(pageID: pageID, pageIndex: pageIndex, time: time, kind: kind.rawValue))
        markPersistTask?.cancel()
        markPersistTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            self?.persistManifest()
        }
    }

    // MARK: - Eventi del writer

    private func segmentClosed(_ segment: SegmentedAudioWriter.Segment) {
        guard var manifest else { return }
        if let index = manifest.segments.firstIndex(where: { $0.index == segment.index }) {
            manifest.segments[index] = segment
        } else {
            manifest.segments.append(segment)
        }
        self.manifest = manifest
        persistManifest()
        // Controllo periodico dello spazio libero a ogni rotazione.
        if state == .recording, fileStore.availableCapacity() < 50 * 1024 * 1024 {
            handleWriteFailure(StartError.insufficientStorage(available: fileStore.availableCapacity()))
        }
    }

    private func segmentOpened(_ segment: SegmentedAudioWriter.Segment) {
        guard var manifest else { return }
        if !manifest.segments.contains(where: { $0.index == segment.index }) {
            manifest.segments.append(segment)
            self.manifest = manifest
            persistManifest()
        }
    }

    private func persistManifest() {
        guard var manifest else { return }
        manifest.updatedAt = Date()
        self.manifest = manifest
        manifestWriter.persist(manifest)
    }

    private func handleWriteFailure(_ error: Error) {
        guard state.isActive else { return }
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        lastError = "La registrazione è stata fermata per proteggere l'audio già acquisito: \(message)"
        logger.error("Registrazione fermata per errore di scrittura")
        notifyIfBackground(title: "Registrazione fermata", body: "Errore di scrittura o spazio esaurito. L'audio acquisito fino a ora è stato salvato.")
        Task { await stop() }
    }

    // MARK: - Interruzioni e cambi di dispositivo

    private func registerObservers() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
            let info = notification.userInfo
            let typeValue = info?[AVAudioSessionInterruptionTypeKey] as? UInt
            let optionsValue = info?[AVAudioSessionInterruptionOptionKey] as? UInt
            MainActor.assumeIsolated { self?.handleInterruption(typeValue: typeValue, optionsValue: optionsValue) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] notification in
            let reasonValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            MainActor.assumeIsolated { self?.handleRouteChange(reasonValue: reasonValue) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleMediaServicesReset() }
        })
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, (notification.object as AnyObject?) === self.capture.engine else { return }
                self.handleEngineConfigurationChange()
            }
        })
    }

    private func handleInterruption(typeValue: UInt?, optionsValue: UInt?) {
        guard let typeValue, let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
        switch type {
        case .began:
            guard state == .recording else { return }
            // Il sistema ha già fermato l'audio: si finalizza il segmento.
            capture.stopAndCloseSegment()
            state = .paused(.interruption)
            manifest?.status = .paused
            manifest?.interruptions.append(.init(time: elapsed, reason: "interruzione di sistema", date: Date()))
            persistManifest()
            notifyIfBackground(title: "Registrazione in pausa", body: "Un'interruzione (es. una chiamata) ha messo in pausa la registrazione di \(activeTitle).")
        case .ended:
            guard state == .paused(.interruption) else { return }
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue ?? 0)
            if settings.autoResumeAfterInterruption && options.contains(.shouldResume) {
                resume()
                if state == .recording {
                    notifyIfBackground(title: "Registrazione ripresa", body: "La registrazione di \(activeTitle) è ripresa.")
                }
            }
        @unknown default:
            break
        }
    }

    private func handleRouteChange(reasonValue: UInt?) {
        guard state.isActive else { return }
        inputName = currentInputName()
        if let reasonValue, let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue), reason == .oldDeviceUnavailable || reason == .newDeviceAvailable {
            manifest?.interruptions.append(.init(time: elapsed, reason: "cambio dispositivo di ingresso: \(inputName)", date: Date()))
            persistManifest()
        }
    }

    /// Il motore si ferma quando cambia la configurazione hardware (es.
    /// collegamento di un microfono USB): si chiude il segmento e si riparte
    /// con il nuovo formato, in un nuovo segmento.
    private func handleEngineConfigurationChange() {
        guard state == .recording else { return }
        logger.notice("Configurazione audio cambiata: riavvio dell'acquisizione")
        capture.stopAndCloseSegment()
        do {
            try capture.start(voiceProcessing: profile.voiceProcessing)
            inputName = currentInputName()
        } catch {
            state = .paused(.error("Il dispositivo di ingresso è cambiato e l'acquisizione non è ripartita. Tocca Riprendi."))
            manifest?.status = .paused
            persistManifest()
            notifyIfBackground(title: "Registrazione in pausa", body: "Il microfono è cambiato. Apri Quaderno AI per riprendere.")
        }
    }

    private func handleMediaServicesReset() {
        guard state.isActive else { return }
        logger.error("Reset dei servizi audio di sistema")
        let wasRecording = state == .recording
        capture.stopAndCloseSegment()
        capture.rebuildEngine()
        if let writer { capture.attach(writer: writer) }
        if wasRecording {
            do {
                try configureSession()
                try capture.start(voiceProcessing: profile.voiceProcessing)
            } catch {
                state = .paused(.error("I servizi audio di sistema si sono riavviati. Tocca Riprendi."))
            }
        }
    }

    // MARK: - Notifiche locali

    static func requestNotificationPermission() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    private func notifyIfBackground(title: String, body: String) {
        guard settings.notifyOnInterruption, UIApplication.shared.applicationState != .active else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
