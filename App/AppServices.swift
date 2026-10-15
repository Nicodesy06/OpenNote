import Foundation
import Observation
import SwiftData
import UIKit
import os
import QuadernoOnDevice

/// Contenitore dei servizi dell'app, creato una sola volta all'avvio.
@MainActor
@Observable
final class AppServices {
    /// Riferimento per l'AppDelegate (BGTaskScheduler, sessioni in background).
    static var shared: AppServices?

    let fileStore: FileStore
    let drawingStore: DrawingStore
    let modelContainer: ModelContainer
    let settings: AppSettings
    let keychain: KeychainStore
    /// Download e stato dei modelli di trascrizione sul dispositivo.
    let onDeviceModels: OnDeviceModelStore
    let recording: RecordingService
    let playback: PlaybackService
    let maintenance: RecordingMaintenance
    let network: NetworkMonitor
    let jobs: JobRunner
    let content: ContentManager
    let importer: ImportService
    /// Messaggio da mostrare se all'avvio è stato necessario ricreare il
    /// database (il precedente viene conservato, non cancellato).
    var startupNotice: String?
    /// File ricevuti con "Apri con" in attesa di assegnazione a una materia.
    var pendingIncomingFiles: [URL] = []
    /// `true` mentre l'editor di un quaderno è a schermo intero (mostra il
    /// proprio indicatore di registrazione e il proprio invito a trascrivere).
    var isEditorPresented = false

    private let logger = Logger(subsystem: "QuadernoAI", category: "AppServices")
    @ObservationIgnored private var didStart = false

    init(root: URL = FileStore.defaultRoot(), inMemory: Bool = false) {
        let fileStore = FileStore(root: root)
        self.fileStore = fileStore
        self.drawingStore = DrawingStore(fileStore: fileStore)
        let settings = AppSettings()
        self.settings = settings
        self.keychain = KeychainStore()
        let onDeviceModels = OnDeviceModelStore()
        self.onDeviceModels = onDeviceModels
        // Su avviso di memoria si liberano i modelli caricati (centinaia di MB):
        // verranno ricaricati dal disco al prossimo chunk.
        NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { _ in
            Task { await onDeviceModels.unloadAll() }
        }

        var notice: String?
        let container: ModelContainer
        if inMemory {
            container = try! AppModelContainer.makeInMemory()
        } else {
            do {
                container = try AppModelContainer.make(storeURL: fileStore.storeURL)
            } catch {
                // Database illeggibile: viene spostato da parte (mai eliminato)
                // e se ne crea uno nuovo. Le registrazioni vengono ricostruite
                // dai manifest su disco al primo avvio.
                let backup = fileStore.storeURL.deletingLastPathComponent().appendingPathComponent("Library-\(Int(Date().timeIntervalSince1970)).broken")
                try? FileManager.default.moveItem(at: fileStore.storeURL.deletingLastPathComponent(), to: backup)
                fileStore.ensureDirectory(fileStore.storeURL.deletingLastPathComponent())
                notice = "Il database dell'app non era leggibile ed è stato ricreato. La copia precedente è conservata; le registrazioni presenti sul dispositivo vengono recuperate automaticamente."
                container = (try? AppModelContainer.make(storeURL: fileStore.storeURL)) ?? (try! AppModelContainer.makeInMemory())
            }
        }
        self.modelContainer = container
        self.startupNotice = notice

        let maintenance = RecordingMaintenance(fileStore: fileStore, modelContainer: container)
        self.maintenance = maintenance
        let network = NetworkMonitor()
        self.network = network
        self.recording = RecordingService(fileStore: fileStore, modelContainer: container, settings: settings)
        self.playback = PlaybackService()
        self.jobs = JobRunner(modelContainer: container, fileStore: fileStore, settings: settings, keychain: keychain, maintenance: maintenance, network: network)
        self.content = ContentManager(fileStore: fileStore, drawingStore: drawingStore, modelContainer: container)
        self.importer = ImportService(fileStore: fileStore, modelContainer: container)

        let recordingService = recording
        playback.isRecordingActive = { recordingService.state.isActive }
        recording.onRecordingFinished = { id in
            Task { @MainActor in
                await maintenance.finalize(recordingID: id)
            }
        }
        network.onReconnect = { [weak jobs = self.jobs] in jobs?.processQueue() }
    }

    /// Operazioni di avvio: pulizia, recupero registrazioni, ripresa lavori.
    func startup() async {
        guard !didStart else { return }
        didStart = true
        fileStore.cleanTemporaryFiles()
        if !recording.state.isActive {
            await maintenance.recoverInterruptedRecordings()
        }
        jobs.restoreAfterLaunch()
    }

    func handleIncoming(url: URL) {
        guard ImportService.isAudio(url) || ImportService.isPDF(url) else { return }
        // I file aperti da altre app vengono copiati subito in una cartella
        // temporanea, perché l'URL potrebbe non restare valido.
        fileStore.ensureDirectory(fileStore.importsDirectory)
        let destination = fileStore.importsDirectory.appendingPathComponent(url.lastPathComponent)
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            try fileStore.copyFile(from: url, to: destination)
            pendingIncomingFiles.append(destination)
        } catch {
            logger.error("File in arrivo non copiato: \(error.localizedDescription, privacy: .public)")
        }
    }
}
