import SwiftData
import SwiftUI
import QuadernoCore

/// Avvio di trascrizione e sbobinatura: modalità, provider, costo stimato e
/// consenso esplicito all'invio dei dati ai servizi cloud.
struct GenerateSheet: View {
    enum Kind: String, Identifiable {
        case full
        case transcriptionOnly
        case documentOnly
        var id: String { rawValue }
    }

    let recording: AudioRecording
    var kind: Kind = .full
    @Environment(\.dismiss) private var dismiss
    @Environment(AppServices.self) private var services
    @Environment(JobRunner.self) private var jobRunner
    @Environment(NetworkMonitor.self) private var network
    @EnvironmentObject private var settings: AppSettings
    @State private var mode: SbobinaturaMode = .integrale
    @State private var consent = false
    @State private var showSettings = false

    private var factory: ProviderFactory {
        ProviderFactory(settings: settings, keychain: services.keychain, transport: ProviderFactory.sharedTransport)
    }

    private var needsTranscription: Bool { kind != .documentOnly }
    private var needsGeneration: Bool { kind != .transcriptionOnly }
    private var usesBackend: Bool { settings.transcriptionProvider == .backend }

    private var transcriptionReady: Bool {
        switch settings.transcriptionProvider {
        case .openAI: return services.keychain.hasValue(account: APIKeyAccount.openAI)
        case .appleOnDevice: return true
        case .backend: return !settings.backendURL.isEmpty && services.keychain.hasValue(account: APIKeyAccount.backendToken)
        }
    }

    private var generationReady: Bool {
        if usesBackend { return true }
        switch settings.generationProvider {
        case .anthropic: return services.keychain.hasValue(account: APIKeyAccount.anthropic)
        case .openAI: return services.keychain.hasValue(account: APIKeyAccount.openAI) && !settings.openAITextModel.isEmpty
        }
    }

    private var sendsToCloud: Bool {
        (needsTranscription && settings.transcriptionProvider != .appleOnDevice) || needsGeneration
    }

    private var estimate: CostEstimator.Estimate {
        let transcription = needsTranscription ? (try? factory.currentTranscriptionProvider()) : nil
        let generation = needsGeneration ? (try? factory.currentGenerationProvider()) : nil
        let characters = kind == .documentOnly ? recording.latestTranscript?.searchText.count : nil
        return CostEstimator.estimate(durationSeconds: recording.duration, transcription: transcription, generation: generation, mode: mode, verify: settings.verifyWithModel, transcriptCharacters: characters)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Registrazione", value: recording.title)
                    LabeledContent("Durata", value: Format.spokenDuration(recording.duration))
                }
                if needsGeneration {
                    Section("Tipo di documento") {
                        Picker("Tipo", selection: $mode) {
                            ForEach(SbobinaturaMode.allCases) { mode in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(mode.displayName)
                                    Text(description(of: mode)).font(.caption).foregroundStyle(.secondary)
                                }
                                .tag(mode)
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    }
                }
                Section {
                    if needsTranscription {
                        providerRow(title: "Trascrizione", value: transcriptionDescription, ready: transcriptionReady)
                    }
                    if needsGeneration {
                        providerRow(title: "Sbobinatura", value: usesBackend ? "Backend (\(settings.generationProvider.displayName))" : "\(settings.generationProvider.displayName) · \(settings.currentGenerationModel)", ready: generationReady)
                        LabeledContent("Controllo di completezza", value: settings.verifyWithModel ? "Attivo" : "Solo controllo locale")
                    }
                    Button("Modifica provider e chiavi") { showSettings = true }
                } header: {
                    Text("Servizi AI")
                }
                Section {
                    let estimate = self.estimate
                    if let total = estimate.totalUSD {
                        LabeledContent("Costo stimato", value: Format.usd(total))
                        if let transcription = estimate.transcriptionUSD, needsTranscription {
                            LabeledContent("· trascrizione", value: Format.usd(transcription)).foregroundStyle(.secondary)
                        }
                        if let generation = estimate.generationUSD, needsGeneration {
                            LabeledContent("· rielaborazione (~\(estimate.estimatedInputTokens / 1000)k token in, ~\(estimate.estimatedOutputTokens / 1000)k out)", value: Format.usd(generation)).foregroundStyle(.secondary)
                        }
                    }
                    ForEach(estimate.notes, id: \.self) { note in
                        Text(note).font(.caption).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Costi")
                } footer: {
                    Text("Le chiamate API sono addebitate dal provider sul tuo account API, separato da abbonamenti come ChatGPT Plus o Claude Pro.")
                }
                if sendsToCloud {
                    Section {
                        Toggle(isOn: $consent) {
                            Text(consentText).font(.callout)
                        }
                    } header: {
                        Text("Consenso all'invio")
                    } footer: {
                        Text("Le lezioni possono contenere voci e dati personali di altre persone. Senza consenso non viene inviato nulla. La conservazione dei dati presso il provider dipende dalle sue condizioni per le API.")
                    }
                }
                if !network.isConnected && sendsToCloud {
                    Label("Sei offline: il lavoro partirà al ritorno della connessione.", systemImage: "wifi.slash").foregroundStyle(.orange)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annulla") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Avvia") { start() }
                        .disabled(!canStart)
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .onAppear { mode = settings.defaultMode }
        }
    }

    private var title: String {
        switch kind {
        case .full: return "Trascrivi e crea sbobinatura"
        case .transcriptionOnly: return "Trascrivi"
        case .documentOnly: return "Nuova sbobinatura"
        }
    }

    private var canStart: Bool {
        (!needsTranscription || transcriptionReady) && (!needsGeneration || generationReady) && (!sendsToCloud || consent)
    }

    private var transcriptionDescription: String {
        switch settings.transcriptionProvider {
        case .openAI: return "OpenAI · \(settings.openAITranscriptionModel)"
        case .appleOnDevice: return "Sul dispositivo (nessun invio)"
        case .backend: return "Backend gestito"
        }
    }

    private var consentText: String {
        var parts: [String] = []
        if needsTranscription {
            switch settings.transcriptionProvider {
            case .openAI: parts.append("l'audio della registrazione a OpenAI per la trascrizione")
            case .backend: parts.append("l'audio al backend configurato (\(URL(string: settings.backendURL)?.host ?? settings.backendURL))")
            case .appleOnDevice: break
            }
        }
        if needsGeneration && !usesBackend {
            parts.append("il testo della trascrizione a \(settings.generationProvider.displayName) per la rielaborazione")
        }
        return "Acconsento a inviare " + parts.joined(separator: " e ") + "."
    }

    private func description(of mode: SbobinaturaMode) -> String {
        switch mode {
        case .integrale: return "Testo universitario completo e discorsivo, senza tagli intenzionali (consigliato)."
        case .trascrizionePulita: return "Vicina al parlato, solo ripulita da intercalari e ripetizioni."
        case .riassunto: return "Versione condensata per il ripasso, con definizioni, nomi e date."
        }
    }

    @ViewBuilder
    private func providerRow(title: String, value: String, ready: Bool) -> some View {
        LabeledContent(title) {
            HStack {
                Text(value).foregroundStyle(.secondary)
                Image(systemName: ready ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(ready ? .green : .orange)
                    .accessibilityLabel(ready ? "Configurato" : "Da configurare")
            }
        }
    }

    private func start() {
        let jobKind: ProcessingJobKind
        switch kind {
        case .full: jobKind = .transcriptionAndSbobinatura
        case .transcriptionOnly: jobKind = .transcription
        case .documentOnly: jobKind = .sbobinatura
        }
        jobRunner.enqueue(kind: jobKind, recording: recording, mode: mode, transcriptID: kind == .documentOnly ? recording.latestTranscript?.id : nil, consent: consent || !sendsToCloud, estimatedCost: estimate.totalUSD)
        dismiss()
    }
}

/// Coda delle elaborazioni con stato, avanzamento, errori e azioni.
struct JobsView: View {
    @Query(sort: \ProcessingJob.createdAt, order: .reverse) private var jobs: [ProcessingJob]
    @Environment(JobRunner.self) private var jobRunner
    @Environment(NetworkMonitor.self) private var network

    var body: some View {
        Group {
            if jobs.isEmpty {
                EmptyStateView(title: "Nessuna elaborazione", systemImage: "tray", message: "Le trascrizioni e le sbobinature in corso compaiono qui. Puoi chiudere l'app: i lavori riprendono da dove si erano fermati.")
            } else {
                List {
                    if !network.isConnected {
                        Label("Offline: i lavori cloud riprenderanno al ritorno della rete.", systemImage: "wifi.slash").foregroundStyle(.orange)
                    }
                    if jobRunner.runningJobID != nil, !jobRunner.liveText.isEmpty {
                        Section("Anteprima della scrittura") {
                            Text(jobRunner.liveText)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(8)
                                .animation(.default, value: jobRunner.liveText)
                        }
                    }
                    Section {
                        ForEach(jobs) { job in
                            JobRow(job: job)
                        }
                    } footer: {
                        Text("iPadOS limita l'esecuzione in background: se l'app resta a lungo chiusa, il lavoro riprende alla riapertura senza ripetere le parti già completate. Per elaborazioni garantite ad app chiusa configura il backend gestito.")
                    }
                }
            }
        }
        .navigationTitle("Elaborazioni AI")
    }
}

struct JobRow: View {
    let job: ProcessingJob
    @Environment(JobRunner.self) private var jobRunner
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon).foregroundStyle(color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body.weight(.medium))
                    Text("\(job.state.displayName) · \(job.stepDescription)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                actions
            }
            if job.state.isActive || job.state == .pending || job.state == .waiting {
                ProgressView(value: job.progress)
            }
            if let error = job.errorMessage, job.state == .failed || job.state == .waiting {
                Text(error).font(.caption).foregroundStyle(job.state == .failed ? .red : .orange)
            }
        }
        .padding(.vertical, 4)
    }

    private var resultDocument: GeneratedDocument? {
        guard let documentID = job.resultDocumentID else { return nil }
        return try? modelContext.fetch(FetchDescriptor<GeneratedDocument>(predicate: #Predicate { $0.id == documentID })).first
    }

    private var title: String {
        let recordingID = job.recordingID
        let recording = try? modelContext.fetch(FetchDescriptor<AudioRecording>(predicate: #Predicate { $0.id == recordingID })).first
        let name = recording?.title ?? "Registrazione eliminata"
        switch job.kind {
        case .transcription: return "Trascrizione · \(name)"
        case .sbobinatura: return "\(job.mode.displayName) · \(name)"
        case .transcriptionAndSbobinatura: return "Trascrizione e \(job.mode.displayName.lowercased()) · \(name)"
        }
    }

    private var icon: String {
        switch job.state {
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.octagon.fill"
        case .cancelled: return "slash.circle"
        case .waiting: return "pause.circle"
        case .pending: return "clock"
        default: return "sparkles"
        }
    }

    private var color: Color {
        switch job.state {
        case .completed: return .green
        case .failed: return .red
        case .waiting: return .orange
        case .cancelled: return .secondary
        default: return .accentColor
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch job.state {
        case .failed, .waiting:
            Button("Riprova") { jobRunner.retry(job) }.buttonStyle(.bordered)
            Button(role: .destructive) { jobRunner.cancel(job) } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
        case .completed:
            if let document = resultDocument {
                NavigationLink {
                    DocumentEditorView(document: document)
                } label: {
                    Text("Apri")
                }
                .buttonStyle(.bordered)
                .fixedSize()
            }
            Button { jobRunner.delete(job) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                .accessibilityLabel("Rimuovi dalla lista")
        case .cancelled:
            Button { jobRunner.delete(job) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
        default:
            Button("Annulla", role: .destructive) { jobRunner.cancel(job) }.buttonStyle(.borderless)
        }
    }
}
