import AVFoundation
import SwiftUI
import QuadernoCore

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppServices.self) private var services
    @Environment(RecordingService.self) private var recorder
    @EnvironmentObject private var settings: AppSettings
    @State private var anthropicModels: [String] = []
    @State private var openAIModels: [String] = []
    @State private var inputs: [RecordingService.InputOption] = []
    @State private var storage: [(String, Int64)] = []

    static let transcriptionModels: [(id: String, description: String)] = [
        ("gpt-transcribe", "Consigliato: alta accuratezza, glossario e lingue; tempi approssimati per frase."),
        ("gpt-4o-transcribe-diarize", "Distingue gli interlocutori (docente/studenti) con tempi per segmento; non usa il glossario."),
        ("whisper-1", "Tempi precisi per segmento; accuratezza inferiore sui termini tecnici."),
        ("gpt-4o-transcribe", "Modello precedente."),
        ("gpt-4o-mini-transcribe", "Modello precedente, economico.")
    ]

    var body: some View {
        NavigationStack {
            Form {
                apiKeysSection
                transcriptionSection
                generationSection
                recordingSection
                Section("Scrittura") {
                    Toggle("Disegna anche con il dito", isOn: $settings.fingerDrawing)
                    Text("Con l'opzione disattivata il dito scorre e ingrandisce la pagina, e solo Apple Pencil scrive (palm rejection automatico).")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                privacySection
                storageSection
                aboutSection
            }
            .navigationTitle("Impostazioni")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Fine") { dismiss() } }
            }
            .onAppear {
                inputs = recorder.availableInputs()
                refreshStorage()
            }
        }
    }

    // MARK: - Chiavi API

    private var apiKeysSection: some View {
        Section {
            APIKeyField(title: "OpenAI", account: APIKeyAccount.openAI, placeholder: "sk-…") { key in
                let models = try await OpenAIResponsesProvider(apiKey: key, model: "", transport: ProviderFactory.sharedTransport).listModels()
                openAIModels = models
                if settings.openAITextModel.isEmpty, let suggestion = OpenAIResponsesProvider.suggestTextModel(from: models) {
                    settings.openAITextModel = suggestion
                }
                return "Connessione riuscita: \(models.count) modelli disponibili."
            }
            APIKeyField(title: "Anthropic", account: APIKeyAccount.anthropic, placeholder: "sk-ant-…") { key in
                let models = try await AnthropicProvider(apiKey: key, transport: ProviderFactory.sharedTransport).listModels()
                anthropicModels = models
                return "Connessione riuscita: \(models.count) modelli disponibili."
            }
        } header: {
            Text("Chiavi API (Bring Your Own Key)")
        } footer: {
            Text("Le chiavi sono salvate solo nel Portachiavi di questo iPad. OpenAI e Anthropic non offrono un accesso OAuth alle API per app di terze parti con il tuo abbonamento ChatGPT o Claude: servono chiavi API, con fatturazione separata dagli abbonamenti consumer. Crea le chiavi su platform.openai.com e console.anthropic.com.")
        }
    }

    // MARK: - Trascrizione

    private var transcriptionSection: some View {
        Section {
            Picker("Servizio", selection: $settings.transcriptionProvider) {
                ForEach(AppSettings.TranscriptionProviderChoice.allCases) { Text($0.displayName).tag($0) }
            }
            switch settings.transcriptionProvider {
            case .openAI:
                Picker("Modello", selection: $settings.openAITranscriptionModel) {
                    ForEach(Self.transcriptionModels, id: \.id) { Text($0.id).tag($0.id) }
                }
                if let description = Self.transcriptionModels.first(where: { $0.id == settings.openAITranscriptionModel })?.description {
                    Text(description).font(.footnote).foregroundStyle(.secondary)
                }
                Stepper(value: $settings.transcriptionChunkMinutes, in: 2...15, step: 1) {
                    LabeledContent("Durata delle parti", value: "\(Int(settings.transcriptionChunkMinutes)) min")
                }
                Text("Le registrazioni lunghe vengono divise in parti (tagliate sulle pause, con breve sovrapposizione) per rispettare il limite di 25 MB per file. Parti più brevi danno riferimenti all'audio più precisi.")
                    .font(.footnote).foregroundStyle(.secondary)
            case .appleOnDevice:
                Text("Trascrizione sul dispositivo: nessun invio dell'audio e nessun costo API, ma accuratezza generalmente inferiore sui termini tecnici, nessuna distinzione degli interlocutori e maggiore consumo di batteria durante l'elaborazione. Su iPadOS 26 usa SpeechAnalyzer; sulle versioni precedenti il riconoscimento classico, a parti brevi.")
                    .font(.footnote).foregroundStyle(.secondary)
            case .backend:
                BackendSettingsFields()
            }
        } header: {
            Text("Trascrizione")
        }
    }

    // MARK: - Sbobinatura

    private var generationSection: some View {
        Section {
            if settings.transcriptionProvider == .backend {
                Text("Con il backend gestito la rielaborazione avviene sul server con le chiavi configurate lì; qui scegli provider e modello da richiedere.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Picker("Servizio", selection: $settings.generationProvider) {
                ForEach(AppSettings.GenerationProviderChoice.allCases) { Text($0.displayName).tag($0) }
            }
            switch settings.generationProvider {
            case .anthropic:
                Picker("Modello", selection: $settings.anthropicModel) {
                    ForEach(anthropicModelOptions, id: \.self) { Text($0).tag($0) }
                }
                Toggle("Fallback automatico in caso di rifiuto", isOn: $settings.useServerSideFallback)
                Text("Se i filtri di sicurezza bloccano per errore un contenuto didattico (es. biologia, sicurezza informatica), il server di Anthropic ripete la richiesta con un modello alternativo.")
                    .font(.footnote).foregroundStyle(.secondary)
            case .openAI:
                if openAIModels.isEmpty {
                    TextField("Modello (es. scegli dopo il test della chiave)", text: $settings.openAITextModel)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } else {
                    Picker("Modello", selection: $settings.openAITextModel) {
                        ForEach(openAIModels.filter { !$0.contains("transcribe") && !$0.contains("tts") && !$0.contains("embedding") && !$0.contains("whisper") }, id: \.self) { Text($0).tag($0) }
                    }
                }
            }
            Picker("Accuratezza della scrittura", selection: $settings.writingEffort) {
                Text("Bassa (più veloce)").tag(GenerationEffort.low)
                Text("Media").tag(GenerationEffort.medium)
                Text("Alta (consigliata)").tag(GenerationEffort.high)
                Text("Molto alta").tag(GenerationEffort.xhigh)
            }
            Picker("Documento predefinito", selection: $settings.defaultMode) {
                ForEach(SbobinaturaMode.allCases) { Text($0.displayName).tag($0) }
            }
            Toggle("Controllo di completezza con l'AI", isOn: $settings.verifyWithModel)
            Toggle("Correzione automatica dei problemi gravi", isOn: $settings.autoRepair)
                .disabled(!settings.verifyWithModel)
            NavigationLink("Istruzioni della sbobinatura") { PromptEditorView() }
        } header: {
            Text("Sbobinatura")
        } footer: {
            Text("Il controllo confronta ogni sezione con la trascrizione (omissioni, valori, date, nomi, affermazioni non dette) e aumenta il costo di circa il 50–80%. Non è una garanzia assoluta di completezza.")
        }
    }

    private var anthropicModelOptions: [String] {
        var options = anthropicModels.filter { $0.hasPrefix("claude") }
        for fallback in [AnthropicProvider.defaultModel, "claude-sonnet-5-5", "claude-haiku-5-5", settings.anthropicModel] where !options.contains(fallback) {
            options.append(fallback)
        }
        return options
    }

    // MARK: - Registrazione

    private var recordingSection: some View {
        Section {
            Picker("Profilo", selection: $settings.recordingProfile) {
                ForEach(RecordingProfileID.allCases) { Text(RecordingProfile.profile(for: $0).displayName).tag($0) }
            }
            Text(RecordingProfile.profile(for: settings.recordingProfile).summary).font(.footnote).foregroundStyle(.secondary)
            if RecordingProfile.profile(for: settings.recordingProfile).appliesSoftwareGain {
                Stepper(value: $settings.experimentalGainDB, in: 0...24, step: 3) {
                    LabeledContent("Guadagno digitale", value: "+\(Int(settings.experimentalGainDB)) dB")
                }
            }
            Picker("Microfono", selection: $settings.preferredInputUID) {
                Text("Automatico (sistema)").tag("")
                ForEach(inputs) { Text($0.name).tag($0.id) }
            }
            if let input = inputs.first(where: { $0.id == settings.preferredInputUID }), !input.dataSources.isEmpty {
                Picker("Capsula / orientamento", selection: $settings.preferredDataSourceID) {
                    Text("Automatico").tag(-1)
                    ForEach(input.dataSources) { Text($0.name).tag($0.id) }
                }
            }
            Picker("Qualità", selection: $settings.recordingBitrate) {
                Text("48 kbps (più leggera)").tag(48_000)
                Text("64 kbps (consigliata per la voce)").tag(64_000)
                Text("96 kbps").tag(96_000)
            }
            Stepper(value: $settings.segmentMinutes, in: 1...10, step: 1) {
                LabeledContent("Salvataggio di sicurezza ogni", value: "\(Int(settings.segmentMinutes)) min")
            }
            Toggle("Riprendi dopo un'interruzione (es. chiamata)", isOn: $settings.autoResumeAfterInterruption)
            Toggle("Avvisami se la registrazione si interrompe", isOn: $settings.notifyOnInterruption)
            TestRecordingView()
        } header: {
            Text("Registrazione")
        } footer: {
            Text("L'audio viene salvato in blocchi chiusi a intervalli regolari: in caso di chiusura imprevista dell'app si perde al massimo l'ultimo blocco. Durante la registrazione non viene eseguita alcuna elaborazione AI.")
        }
    }

    // MARK: - Privacy

    private var privacySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("Cosa resta sul dispositivo").font(.subheadline.weight(.semibold))
                Text("Quaderni, registrazioni, trascrizioni e sbobinature sono salvati solo su questo iPad (inclusi nel backup del dispositivo). L'app non usa analytics e non invia audio o testi nei log.")
                Text("Cosa viene inviato e quando").font(.subheadline.weight(.semibold))
                Text("Solo quando avvii tu una trascrizione o una sbobinatura, dopo il consenso: l'audio al servizio di trascrizione scelto e il testo della trascrizione al servizio di rielaborazione. Le richieste viaggiano su HTTPS direttamente verso il provider (o verso il tuo backend).")
                Text("Conservazione presso i provider").font(.subheadline.weight(.semibold))
                Text("Dipende dalle condizioni API del provider (in genere i dati API non sono usati per l'addestramento e possono essere conservati per un periodo limitato per la prevenzione degli abusi). Verifica le condizioni aggiornate prima di registrare persone che non hanno dato il loro consenso.")
            }
            .font(.footnote)
            Link("Condizioni sui dati delle API OpenAI", destination: URL(string: "https://openai.com/policies/")!)
            Link("Privacy di Anthropic", destination: URL(string: "https://www.anthropic.com/legal/privacy")!)
        } header: {
            Text("Privacy")
        }
    }

    // MARK: - Archiviazione

    private var storageSection: some View {
        Section("Archiviazione") {
            ForEach(storage, id: \.0) { item in
                LabeledContent(item.0, value: Format.bytes(item.1))
            }
            LabeledContent("Spazio libero", value: Format.bytes(services.fileStore.availableCapacity()))
            Button("Elimina file temporanei") {
                services.fileStore.cleanTemporaryFiles()
                refreshStorage()
            }
        }
    }

    private func refreshStorage() {
        let store = services.fileStore
        storage = [
            ("Registrazioni", store.directorySize(store.recordingsDirectory)),
            ("Disegni", store.directorySize(store.drawingsDirectory) + store.directorySize(store.pageImagesDirectory)),
            ("PDF e annotazioni", store.directorySize(store.materialsDirectory)),
            ("Immagini dei documenti", store.directorySize(store.documentImagesDirectory)),
            ("Lavori AI in corso", store.directorySize(store.jobsDirectory))
        ]
    }

    private var aboutSection: some View {
        Section("Informazioni") {
            LabeledContent("Versione", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-")
            LabeledContent("Istruzioni di sbobinatura", value: ProviderFactory(settings: settings, keychain: services.keychain, transport: ProviderFactory.sharedTransport).prompts().effectiveVersion)
        }
    }
}

/// Campo per una chiave API: salvataggio nel Keychain, test, rimozione.
struct APIKeyField: View {
    let title: String
    let account: String
    let placeholder: String
    let test: (String) async throws -> String
    @Environment(AppServices.self) private var services
    @State private var draft = ""
    @State private var hasKey = false
    @State private var status: String?
    @State private var statusIsError = false
    @State private var testing = false
    @State private var confirmRemove = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.body.weight(.medium))
                Spacer()
                if hasKey {
                    StatusBadge(text: "Configurata", systemImage: "key.fill", color: .green)
                }
            }
            HStack {
                SecureField(hasKey ? "Sostituisci la chiave" : placeholder, text: $draft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(.password)
                Button("Salva") { save() }
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            HStack {
                Button {
                    runTest()
                } label: {
                    if testing { ProgressView() } else { Label("Verifica connessione", systemImage: "bolt.horizontal") }
                }
                .disabled(!hasKey || testing)
                Spacer()
                if hasKey {
                    Button("Rimuovi", role: .destructive) { confirmRemove = true }
                }
            }
            .buttonStyle(.borderless)
            if let status {
                Text(status).font(.caption).foregroundStyle(statusIsError ? .red : .green)
            }
        }
        .padding(.vertical, 4)
        .onAppear { hasKey = services.keychain.hasValue(account: account) }
        .confirmationDialog("Rimuovere la chiave \(title)?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Rimuovi", role: .destructive) {
                try? services.keychain.delete(account: account)
                hasKey = false
                status = "Chiave rimossa."
                statusIsError = false
            }
        }
    }

    private func save() {
        let key = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try services.keychain.save(key, account: account)
            draft = ""
            hasKey = true
            runTest()
        } catch {
            status = error.readableMessage
            statusIsError = true
        }
    }

    private func runTest() {
        guard let key = services.keychain.read(account: account) else { return }
        testing = true
        status = nil
        Task {
            do {
                status = try await test(key)
                statusIsError = false
            } catch {
                status = AIServiceError.from(error, provider: title).userMessage
                statusIsError = true
            }
            testing = false
        }
    }
}

/// Configurazione del backend gestito.
struct BackendSettingsFields: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(AppServices.self) private var services
    @State private var token = ""
    @State private var status: String?
    @State private var testing = false

    var body: some View {
        TextField("Indirizzo del backend (https://…)", text: $settings.backendURL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.URL)
        HStack {
            SecureField(services.keychain.hasValue(account: APIKeyAccount.backendToken) ? "Token salvato — sostituisci" : "Token di accesso", text: $token)
                .textInputAutocapitalization(.never)
            Button("Salva") {
                try? services.keychain.save(token.trimmingCharacters(in: .whitespaces), account: APIKeyAccount.backendToken)
                token = ""
            }
            .disabled(token.isEmpty)
        }
        Button {
            test()
        } label: {
            if testing { ProgressView() } else { Text("Verifica connessione") }
        }
        if let status {
            Text(status).font(.caption).foregroundStyle(.secondary)
        }
        Text("Il backend esegue trascrizione e sbobinatura lato server con lavori persistenti: l'elaborazione continua anche se l'iPad è bloccato o l'app chiusa. I segreti dei provider restano sul server. Vedi Backend/README.md.")
            .font(.footnote).foregroundStyle(.secondary)
    }

    private func test() {
        testing = true
        Task {
            do {
                let client = try ProviderFactory(settings: settings, keychain: services.keychain, transport: ProviderFactory.sharedTransport).backendClient()
                status = try await client.health() ? "Backend raggiungibile." : "Risposta inattesa."
            } catch {
                status = AIServiceError.from(error, provider: "Backend").userMessage
            }
            testing = false
        }
    }
}

/// Visualizzazione e personalizzazione del prompt di sistema versionato.
struct PromptEditorView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var library = (try? PromptLibrary.load()) ?? PromptLibrary(version: "-", templates: [:])
    @State private var draft = ""
    @State private var showDefault = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Versione predefinita", value: library.version)
                Button(showDefault ? "Nascondi istruzioni predefinite" : "Mostra istruzioni predefinite") { showDefault.toggle() }
                if showDefault {
                    Text(library.raw(.system)).font(.caption.monospaced()).textSelection(.enabled)
                }
            } footer: {
                Text("Le istruzioni predefinite impongono completezza, fedeltà alla lezione, segnalazione dei passaggi incerti e riferimenti all'audio.")
            }
            Section {
                TextEditor(text: $draft).frame(minHeight: 260).font(.callout.monospaced())
                HStack {
                    Button("Parti dalle predefinite") { draft = library.raw(.system) }
                    Spacer()
                    Button("Ripristina predefinite", role: .destructive) {
                        draft = ""
                        settings.customSystemPrompt = ""
                    }
                }
                .buttonStyle(.borderless)
            } header: {
                Text("Istruzioni personalizzate")
            } footer: {
                Text("Se compilate, sostituiscono le istruzioni di sistema predefinite (la versione del documento lo registra). Mantieni le convenzioni [[incerto: …]] e [[S12-S15]], usate dall'app per evidenziare i dubbi e collegare il testo all'audio. Il segnaposto {{LINGUA}} viene sostituito con la lingua del documento.")
            }
        }
        .navigationTitle("Istruzioni")
        .onAppear { draft = settings.customSystemPrompt }
        .onDisappear { settings.customSystemPrompt = draft.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
}
