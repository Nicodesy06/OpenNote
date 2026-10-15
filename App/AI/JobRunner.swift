import BackgroundTasks
import Foundation
import Observation
import SwiftData
import UIKit
import os
import QuadernoCore

/// Coda persistente dei lavori AI (trascrizione e sbobinatura).
///
/// - Un lavoro alla volta, nell'ordine di creazione.
/// - Stati espliciti salvati nel database; il completamento avviene solo dopo
///   aver salvato davvero i risultati.
/// - Ogni chunk trascritto e ogni sezione generata sono salvati in checkpoint
///   su disco: un'interruzione (rete, sospensione, chiusura) non obbliga a
///   ripartire da capo.
/// - Senza rete i lavori passano "in attesa" e riprendono al ritorno della
///   connessione; gli errori transitori vengono ritentati con backoff.
/// - iPadOS non consente esecuzione illimitata in background: si usa il tempo
///   extra concesso dal sistema, gli upload in background per l'audio e, alla
///   scadenza, il lavoro riprende alla riapertura dell'app o in un
///   BGProcessingTask. Per elaborazioni garantite ad app chiusa serve il
///   backend gestito.
@MainActor
@Observable
final class JobRunner {
    static let backgroundTaskIdentifier = (Bundle.main.bundleIdentifier ?? "it.quadernoai.app") + ".jobs.resume"

    private(set) var runningJobID: UUID?
    private(set) var liveText = ""

    @ObservationIgnored private let modelContainer: ModelContainer
    @ObservationIgnored private let fileStore: FileStore
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let keychain: KeychainStore
    @ObservationIgnored private let maintenance: RecordingMaintenance
    @ObservationIgnored private let network: NetworkMonitor
    @ObservationIgnored private var currentTask: Task<Void, Never>?
    @ObservationIgnored private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored private var expiredInBackground = false
    @ObservationIgnored private let logger = Logger(subsystem: "QuadernoAI", category: "JobRunner")
    @ObservationIgnored private var lastSave = Date.distantPast

    init(modelContainer: ModelContainer, fileStore: FileStore, settings: AppSettings, keychain: KeychainStore, maintenance: RecordingMaintenance, network: NetworkMonitor) {
        self.modelContainer = modelContainer
        self.fileStore = fileStore
        self.settings = settings
        self.keychain = keychain
        self.maintenance = maintenance
        self.network = network
    }

    private var context: ModelContext { modelContainer.mainContext }

    private var factory: ProviderFactory {
        ProviderFactory(settings: settings, keychain: keychain, transport: ProviderFactory.sharedTransport)
    }

    // MARK: - Creazione

    /// Crea un lavoro, evitando duplicati per la stessa registrazione.
    @discardableResult
    func enqueue(kind: ProcessingJobKind, recording: AudioRecording, mode: SbobinaturaMode, transcriptID: UUID? = nil, consent: Bool, estimatedCost: Double?) -> ProcessingJob {
        let recordingID = recording.id
        let existing = (try? context.fetch(FetchDescriptor<ProcessingJob>(predicate: #Predicate { $0.recordingID == recordingID }))) ?? []
        if let duplicate = existing.first(where: { !$0.state.isTerminal && $0.state != .failed && $0.kind == kind }) {
            processQueue()
            return duplicate
        }
        let job = ProcessingJob(
            kind: kind,
            recordingID: recording.id,
            subjectID: recording.subject?.id,
            mode: mode,
            transcriptionProviderID: settings.transcriptionProvider.rawValue,
            transcriptionModel: settings.currentTranscriptionModel,
            generationProviderID: settings.generationProvider.rawValue,
            generationModel: settings.currentGenerationModel
        )
        job.transcriptID = transcriptID
        job.consentGivenAt = consent ? Date() : nil
        job.estimatedCostUSD = estimatedCost
        context.insert(job)
        try? context.save()
        processQueue()
        return job
    }

    func retry(_ job: ProcessingJob) {
        job.errorMessage = nil
        job.nextAttemptAt = nil
        job.state = .pending
        try? context.save()
        processQueue()
    }

    func cancel(_ job: ProcessingJob) {
        if runningJobID == job.id {
            currentTask?.cancel()
        }
        job.state = .cancelled
        try? context.save()
        cleanup(job)
    }

    func delete(_ job: ProcessingJob) {
        if runningJobID == job.id { currentTask?.cancel() }
        cleanup(job)
        context.delete(job)
        try? context.save()
    }

    // MARK: - Ciclo della coda

    /// All'avvio: i lavori rimasti "attivi" (app chiusa durante
    /// l'elaborazione) tornano in attesa e riprendono dai checkpoint.
    func restoreAfterLaunch() {
        let jobs = (try? context.fetch(FetchDescriptor<ProcessingJob>())) ?? []
        for job in jobs where job.state.isActive {
            job.stateRaw = ProcessingJobState.waiting.rawValue
            job.stepDescription = "Ripresa dopo la chiusura dell'app"
        }
        try? context.save()
        processQueue()
    }

    func processQueue() {
        guard currentTask == nil else { return }
        guard let job = nextJob() else { return }
        if requiresNetwork(job) && !network.isConnected {
            job.state = .waiting
            job.stepDescription = "In attesa della connessione"
            try? context.save()
            scheduleBackgroundProcessing()
            return
        }
        runningJobID = job.id
        liveText = ""
        beginBackgroundTime()
        currentTask = Task { [weak self] in
            guard let self else { return }
            await self.run(job)
            self.currentTask = nil
            self.runningJobID = nil
            self.liveText = ""
            self.endBackgroundTime()
            self.processQueue()
        }
    }

    private func nextJob() -> ProcessingJob? {
        let jobs = (try? context.fetch(FetchDescriptor<ProcessingJob>(sortBy: [SortDescriptor(\.createdAt)]))) ?? []
        let now = Date()
        return jobs.first { job in
            (job.state == .pending || job.state == .waiting) && (job.nextAttemptAt ?? .distantPast) <= now
        }
    }

    private func requiresNetwork(_ job: ProcessingJob) -> Bool {
        if job.includesGeneration { return true }
        return job.transcriptionProviderID != AppleSpeechTranscriptionProvider().id
    }

    // MARK: - Esecuzione

    private func run(_ job: ProcessingJob) async {
        do {
            guard job.consentGivenAt != nil || !requiresNetwork(job) else {
                throw AIServiceError.unsupported("Manca il consenso all'invio dei dati al provider cloud.")
            }
            let recordingID = job.recordingID
            guard let recording = try context.fetch(FetchDescriptor<AudioRecording>(predicate: #Predicate { $0.id == recordingID })).first else {
                throw AIServiceError.notFound(message: "La registrazione non esiste più.")
            }
            job.attemptCount += 1
            job.errorMessage = nil
            if job.transcriptionProviderID == AppSettings.TranscriptionProviderChoice.backend.rawValue {
                try await runOnBackend(job, recording: recording)
            } else {
                var transcript: Transcript?
                if job.includesTranscription {
                    transcript = try await transcribe(job, recording: recording)
                } else if let transcriptID = job.transcriptID {
                    transcript = try context.fetch(FetchDescriptor<Transcript>(predicate: #Predicate { $0.id == transcriptID })).first
                } else {
                    transcript = recording.latestTranscript
                }
                if job.includesGeneration {
                    guard let transcript else { throw AIServiceError.notFound(message: "Nessuna trascrizione disponibile per la sbobinatura.") }
                    try await generate(job, recording: recording, transcript: transcript)
                }
            }
            job.progress = 1
            job.stepDescription = "Completato"
            job.state = .completed
            try? context.save()
            cleanup(job)
            logger.info("Lavoro completato")
        } catch {
            handleFailure(error, job: job)
        }
    }

    private func handleFailure(_ error: Error, job: ProcessingJob) {
        if job.state == .cancelled { return }
        if expiredInBackground || error is CancellationError || (error as? AIServiceError) == .cancelled {
            // Tempo in background esaurito: si riprenderà dai checkpoint.
            job.state = .waiting
            job.stepDescription = "Riprenderà alla riapertura dell'app"
            expiredInBackground = false
            try? context.save()
            scheduleBackgroundProcessing()
            return
        }
        let (message, retryable) = describe(error)
        job.errorMessage = message
        if retryable && job.attemptCount < 6 {
            let delay = RetryPolicy(baseDelay: 30, maxDelay: 30 * 60).delay(forAttempt: job.attemptCount)
            job.nextAttemptAt = Date().addingTimeInterval(delay)
            job.state = .waiting
            job.stepDescription = "Nuovo tentativo automatico tra \(Int(delay / 60) + 1) min"
            scheduleRetry(after: delay)
        } else {
            job.state = .failed
            job.stepDescription = "Non riuscito"
        }
        try? context.save()
        logger.error("Lavoro non riuscito (ritentabile: \(retryable))")
    }

    private func describe(_ error: Error) -> (String, Bool) {
        if let error = error as? TranscriptionPipelineError {
            switch error {
            case .chunksFailed(let failures):
                let first = failures.sorted { $0.key < $1.key }.first?.value
                let retryable = failures.values.allSatisfy(\.isRetryable)
                return ("\(failures.count) parti dell'audio non sono state trascritte: \(first?.userMessage ?? "errore"). Le parti già trascritte sono salvate.", retryable)
            case .incompleteCoverage:
                return ("La trascrizione non copre l'intera registrazione: alcune parti non sono state elaborate.", false)
            case .sourceMissing:
                return ("Il file audio non è disponibile.", false)
            }
        }
        if let error = error as? SbobinaturaError {
            switch error {
            case .emptyTranscript: return ("La trascrizione è vuota: niente da rielaborare.", false)
            case .allSectionsFailed(let message): return ("Nessuna sezione generata: \(message)", false)
            case .sectionNotFound: return ("Sezione non trovata.", false)
            }
        }
        if let error = error as? AIServiceError { return (error.userMessage, error.isRetryable) }
        if let error = error as? LocalizedError, let description = error.errorDescription { return (description, false) }
        return (error.localizedDescription, false)
    }

    private func update(_ job: ProcessingJob, state: ProcessingJobState? = nil, progress: Double? = nil, step: String? = nil) {
        if let state { job.state = state }
        if let progress { job.progress = progress }
        if let step { job.stepDescription = step }
        // Salvataggi diradati: lo stato in memoria aggiorna già l'interfaccia.
        if Date().timeIntervalSince(lastSave) > 5 || state != nil {
            try? context.save()
            lastSave = Date()
        }
    }

    // MARK: Trascrizione

    private func transcribe(_ job: ProcessingJob, recording: AudioRecording) async throws -> Transcript {
        update(job, state: .preparing, progress: 0.01, step: "Preparazione dell'audio")
        if maintenance.playableURL(for: recording) == nil {
            await maintenance.finalize(recordingID: recording.id)
        }
        guard let audioURL = maintenance.playableURL(for: recording) else {
            throw TranscriptionPipelineError.sourceMissing
        }
        let jobDirectory = fileStore.jobDirectory(job.id)
        let checkpoints = jobDirectory.appendingPathComponent("transcription", isDirectory: true)
        let provider = try factory.transcriptionProvider(id: job.transcriptionProviderID, model: job.transcriptionModel, checkpointDirectory: checkpoints)
        let subject = recording.subject
        let options = TranscriptionOptions(
            languages: subject?.transcriptionLanguages ?? ["it"],
            prompt: "Lezione universitaria" + (subject.map { " di \($0.name)" } ?? "") + ": \(recording.title).",
            keywords: subject?.glossaryTerms ?? [],
            diarize: provider.capabilities.supportsDiarization
        )
        let pipeline = TranscriptionPipeline(
            provider: provider,
            extractor: AVAudioChunkExtractor(),
            store: FileTranscriptionCheckpointStore(directory: checkpoints),
            workingDirectory: jobDirectory.appendingPathComponent("chunks", isDirectory: true),
            targetChunkDuration: settings.transcriptionChunkMinutes * 60,
            maxConcurrentUploads: provider.capabilities.requiresNetwork ? 2 : 1
        )
        let fingerprint = "\(audioURL.lastPathComponent)-\(fileStore.size(of: audioURL))-\(Int(recording.duration))"
        let generationShare = job.includesGeneration ? 0.35 : 0.95
        update(job, state: .transcribing, step: "Trascrizione")
        let merged = try await pipeline.run(source: audioURL, sourceFingerprint: fingerprint, duration: recording.duration, options: options) { [weak self] progress in
            Task { @MainActor in
                guard let self else { return }
                let detail: String
                switch progress.phase {
                case .planning: detail = "Suddivisione dell'audio"
                case .extracting, .uploading: detail = "Trascrizione: \(progress.completedChunks) di \(progress.totalChunks) parti"
                case .merging: detail = "Ricomposizione della trascrizione"
                case .completed: detail = "Trascrizione completata"
                }
                self.update(job, progress: 0.02 + progress.fraction * generationShare, step: detail)
            }
        }
        try Task.checkCancellation()

        let transcript = Transcript(providerID: provider.id, model: provider.model, precision: merged.report.precision)
        transcript.languageCodes = merged.detectedLanguages
        transcript.reportJSON = try? JSONEncoder().encode(merged.report)
        transcript.recording = recording
        context.insert(transcript)
        for dto in merged.segments {
            let segment = TranscriptSegment(dto: dto)
            segment.transcript = transcript
            context.insert(segment)
        }
        transcript.searchText = merged.fullText
        try context.save()
        job.transcriptID = transcript.id
        update(job, progress: 0.02 + generationShare, step: "Trascrizione salvata")
        return transcript
    }

    // MARK: Sbobinatura

    private func generate(_ job: ProcessingJob, recording: AudioRecording, transcript: Transcript) async throws {
        update(job, state: .generating, step: "Analisi della lezione")
        let provider = try factory.generationProvider(id: job.generationProviderID, model: job.generationModel)
        let checkpoint = FileSbobinaturaCheckpointStore(url: fileStore.jobDirectory(job.id).appendingPathComponent("generation.json"))
        let engine = SbobinaturaEngine(provider: provider, prompts: factory.prompts(), configuration: factory.sbobinaturaConfiguration(), store: checkpoint)
        let lesson = lessonContext(for: recording)
        let base = job.includesTranscription ? 0.37 : 0.02
        let dto = try await engine.generate(segments: transcript.segmentDTOs, context: lesson, mode: job.mode, progress: { [weak self] progress in
            Task { @MainActor in
                guard let self else { return }
                let state: ProcessingJobState = progress.phase == .verifying || progress.phase == .repairing ? .verifying : .generating
                let step: String
                switch progress.phase {
                case .preparing: step = "Preparazione"
                case .analyzing: step = "Analisi della struttura della lezione"
                case .writing: step = "Scrittura: sezione \(progress.currentSection + 1) di \(progress.totalSections)"
                case .verifying: step = "Verifica di completezza: sezione \(progress.currentSection + 1) di \(progress.totalSections)"
                case .repairing: step = "Correzione: sezione \(progress.currentSection + 1) di \(progress.totalSections)"
                case .assembling: step = "Assemblaggio del documento"
                case .completed: step = "Documento completato"
                }
                if job.state != state { job.state = state }
                self.update(job, progress: base + (0.98 - base) * progress.fraction, step: step)
            }
        }, onSectionText: { [weak self] _, text in
            Task { @MainActor in self?.liveText = String(text.suffix(1200)) }
        })
        try Task.checkCancellation()
        let document = save(dto, recording: recording, transcriptID: transcript.id)
        job.resultDocumentID = document.id
    }

    func lessonContext(for recording: AudioRecording) -> LessonContext {
        let subject = recording.subject
        return LessonContext(
            subjectName: subject?.name ?? "Senza materia",
            lessonTitle: recording.title,
            lessonDate: recording.recordedAt,
            language: subject?.documentLanguage ?? "italiano",
            glossary: subject?.glossaryTerms ?? [],
            userInstructions: subject?.aiInstructions
        )
    }

    @discardableResult
    func save(_ dto: GeneratedDocumentDTO, recording: AudioRecording?, transcriptID: UUID?) -> GeneratedDocument {
        let document = GeneratedDocument(title: dto.title, mode: dto.mode, providerID: dto.providerID, model: dto.model, promptVersion: dto.promptVersion)
        document.headerMarkdown = dto.headerMarkdown
        document.outlineJSON = try? JSONEncoder().encode(dto.outline)
        document.inputTokens = dto.usage.inputTokens
        document.outputTokens = dto.usage.outputTokens
        document.subject = recording?.subject
        document.recording = recording
        document.transcriptID = transcriptID
        context.insert(document)
        for sectionDTO in dto.sections {
            let section = GeneratedSection(dto: sectionDTO)
            section.document = document
            context.insert(section)
        }
        document.refreshSearchText()
        let version = DocumentVersion(reason: "Generazione (\(dto.mode.displayName))", snapshot: DocumentSnapshot(document: document))
        version.document = document
        context.insert(version)
        try? context.save()
        return document
    }

    // MARK: Backend gestito

    private func runOnBackend(_ job: ProcessingJob, recording: AudioRecording) async throws {
        let client = try factory.backendClient()
        update(job, state: .preparing, progress: 0.01, step: "Preparazione dell'audio")
        if maintenance.playableURL(for: recording) == nil { await maintenance.finalize(recordingID: recording.id) }
        guard let audioURL = maintenance.playableURL(for: recording) else { throw TranscriptionPipelineError.sourceMissing }
        let subject = recording.subject
        let request = BackendJobRequest(
            idempotencyKey: job.id.uuidString,
            mode: job.mode,
            subjectName: subject?.name ?? "Senza materia",
            lessonTitle: recording.title,
            lessonDate: recording.recordedAt,
            documentLanguage: subject?.documentLanguage ?? "italiano",
            transcriptionLanguages: subject?.transcriptionLanguages ?? ["it"],
            glossary: subject?.glossaryTerms ?? [],
            instructions: subject?.aiInstructions,
            transcriptionModel: settings.openAITranscriptionModel,
            generationProvider: job.generationProviderID,
            generationModel: job.generationModel,
            includeGeneration: job.includesGeneration
        )
        var status = try await client.createJob(request)
        if status.status == "created" {
            update(job, state: .uploading, progress: 0.03, step: "Caricamento dell'audio sul backend")
            status = try await client.uploadAudio(jobID: status.id, fileURL: audioURL)
        }
        if status.status == "uploaded" {
            status = try await client.startJob(jobID: status.id)
        }
        update(job, state: .transcribing, step: "Elaborazione sul backend")
        let final = try await client.waitForCompletion(jobID: status.id) { [weak self] remote in
            Task { @MainActor in self?.update(job, progress: 0.05 + remote.progress * 0.9, step: remote.step.isEmpty ? "Elaborazione sul backend" : remote.step) }
        }
        guard final.status == "completed" else {
            throw AIServiceError.badRequest(message: final.error ?? "Elaborazione sul backend non riuscita")
        }
        let result = try await client.result(jobID: status.id)
        let transcript = Transcript(providerID: result.transcriptionProviderID, model: result.transcriptionModel, precision: result.transcript.report.precision)
        transcript.languageCodes = result.transcript.detectedLanguages
        transcript.reportJSON = try? JSONEncoder().encode(result.transcript.report)
        transcript.recording = recording
        context.insert(transcript)
        for dto in result.transcript.segments {
            let segment = TranscriptSegment(dto: dto)
            segment.transcript = transcript
            context.insert(segment)
        }
        transcript.searchText = result.transcript.fullText
        try context.save()
        job.transcriptID = transcript.id
        if let document = result.document {
            job.resultDocumentID = save(document, recording: recording, transcriptID: transcript.id).id
        }
        // I file sul server vengono eliminati appena scaricato il risultato.
        try? await client.deleteJob(jobID: status.id)
    }

    // MARK: - Tempo in background

    private func beginBackgroundTime() {
        guard backgroundTaskID == .invalid else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "Elaborazione AI") { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.expiredInBackground = true
                self.currentTask?.cancel()
                self.endBackgroundTime()
            }
        }
    }

    private func endBackgroundTime() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }

    private func scheduleRetry(after delay: TimeInterval) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            self?.processQueue()
        }
        scheduleBackgroundProcessing()
    }

    func scheduleBackgroundProcessing() {
        let request = BGProcessingTaskRequest(identifier: Self.backgroundTaskIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = Date().addingTimeInterval(60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            logger.notice("BGProcessingTask non pianificato: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Esecuzione da BGProcessingTask (ripresa dei lavori in attesa).
    func handleBackgroundProcessing(_ task: BGProcessingTask) {
        task.expirationHandler = { [weak self] in
            Task { @MainActor in
                self?.expiredInBackground = true
                self?.currentTask?.cancel()
            }
        }
        processQueue()
        Task { [weak self] in
            while let self, self.currentTask != nil {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            task.setTaskCompleted(success: true)
        }
    }

    private func cleanup(_ job: ProcessingJob) {
        fileStore.removeItemIfExists(fileStore.jobsDirectory.appendingPathComponent(job.id.uuidString))
    }

    // MARK: - Rigenerazione di una sezione

    func regenerate(section: GeneratedSection, in document: GeneratedDocument, instructions: String?, onText: @escaping @MainActor (String) -> Void) async throws {
        guard let outline = document.outline else { throw SbobinaturaError.sectionNotFound }
        guard let transcriptID = document.transcriptID,
              let transcript = try context.fetch(FetchDescriptor<Transcript>(predicate: #Predicate { $0.id == transcriptID })).first else {
            throw AIServiceError.notFound(message: "La trascrizione originale non è più disponibile.")
        }
        // Prima della rigenerazione si salva una versione del documento.
        let version = DocumentVersion(reason: "Prima della rigenerazione di «\(section.title)»", snapshot: DocumentSnapshot(document: document))
        version.document = document
        context.insert(version)
        try? context.save()

        let provider = try factory.generationProvider(id: settings.generationProvider.rawValue, model: settings.currentGenerationModel)
        let engine = SbobinaturaEngine(provider: provider, prompts: factory.prompts(), configuration: factory.sbobinaturaConfiguration())
        let previous = document.orderedSections.first { $0.order == section.order - 1 }?.markdown
        let lesson = document.recording.map(lessonContext(for:)) ?? LessonContext(subjectName: document.subject?.name ?? "", lessonTitle: document.title)
        let dto = try await engine.regenerateSection(order: section.order, outline: outline, segments: transcript.segmentDTOs, context: lesson, mode: document.mode, previousSectionMarkdown: previous, instructions: instructions, onText: { text in
            Task { @MainActor in onText(text) }
        })
        section.apply(dto)
        document.updatedAt = Date()
        document.refreshSearchText()
        try? context.save()
    }
}
