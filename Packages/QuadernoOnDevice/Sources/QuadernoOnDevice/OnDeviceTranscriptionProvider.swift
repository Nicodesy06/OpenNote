import Foundation
import QuadernoCore

/// Provider di trascrizione che esegue sul dispositivo i modelli del
/// catalogo (`OnDeviceModelCatalog`). L'audio non lascia mai l'iPad.
///
/// Apple Speech non passa da qui: l'app usa il proprio provider basato sul
/// framework Speech.
public struct OnDeviceTranscriptionProvider: TranscriptionProvider {
    public static let providerID = "ondevice"

    public let modelInfo: OnDeviceModel

    public init(model: OnDeviceModel) {
        self.modelInfo = model
    }

    public var id: String { Self.providerID }
    public var displayName: String { "Sul dispositivo · \(modelInfo.displayName)" }
    public var model: String { modelInfo.id }

    public var capabilities: TranscriptionCapabilities {
        TranscriptionCapabilities(
            maxUploadBytes: nil,
            // Chunk da 10 minuti: abbastanza lunghi da dare contesto al
            // modello, abbastanza brevi da limitare memoria e lavoro perso
            // se il sistema sospende l'app.
            maxChunkDuration: modelInfo.maxChunkSeconds ?? 600,
            returnsSegmentTimestamps: modelInfo.timestamps == .precise,
            supportsDiarization: false,
            supportsPrompt: false,
            supportsKeywords: modelInfo.engine == .whisperKit,
            maxKeywords: modelInfo.engine == .whisperKit ? 60 : 0,
            requiresNetwork: false,
            supportedFileExtensions: ["m4a", "wav", "caf", "aiff", "mp3"]
        )
    }

    public func estimateCost(durationSeconds: TimeInterval) -> CostEstimate? {
        CostEstimate(amountUSD: 0, basis: "Elaborazione sul dispositivo: nessun costo API, maggiore consumo di batteria.")
    }

    public func transcribe(chunk: AudioChunkFile, options: TranscriptionOptions) async throws -> ChunkTranscription {
        guard OnDeviceModelFiles.isInstalled(modelInfo) else {
            throw OnDeviceEngineError.notInstalled(modelInfo.displayName)
        }
        try await ThermalGate.waitIfNeeded()
        let language = options.languages.first
        let output: EngineOutput
        switch modelInfo.engine {
        case .fluidAudio:
            output = try await FluidAudioEngine.shared.transcribe(url: chunk.url, engineModel: modelInfo.engineModel, language: language)
        case .whisperKit:
            output = try await WhisperKitEngine.shared.transcribe(url: chunk.url, variant: modelInfo.engineModel, language: language, keywords: options.keywords)
        case .appleSpeech:
            throw OnDeviceEngineError.unknownModel(modelInfo.id)
        }
        let text = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let segments = Self.segments(from: output)
        // Un tratto senza parlato (pausa, intervallo) è legittimo: si
        // restituisce testo vuoto e la verifica della copertura lo segnala.
        return ChunkTranscription(
            text: text.isEmpty ? (segments?.map(\.text).joined(separator: " ") ?? "") : text,
            segments: segments,
            detectedLanguages: output.detectedLanguage.map { [$0] } ?? options.languages,
            model: modelInfo.id,
            providerID: id
        )
    }

    static func segments(from output: EngineOutput) -> [TimedText]? {
        if let segments = output.segments, !segments.isEmpty {
            return segments.map { TimedText(start: $0.start, end: $0.end, text: $0.text) }
        }
        if let tokens = output.tokens, !tokens.isEmpty {
            let words = TimedWordGrouper.wordsFromSentencePiece(tokens.map {
                TimedWordGrouper.Word(text: $0.text, start: $0.start, end: $0.end)
            })
            // Se i token non segnano l'inizio delle parole il raggruppamento
            // non è affidabile: meglio tempi interpolati dalla pipeline.
            let expectedWords = output.text.split(whereSeparator: \.isWhitespace).count
            guard !words.isEmpty, words.count * 2 >= expectedWords else { return nil }
            let grouped = TimedWordGrouper.segments(from: words)
            return grouped.isEmpty ? nil : grouped
        }
        return nil
    }
}

/// Attende che l'iPad si raffreddi prima di un nuovo chunk: con stato
/// termico critico iPadOS rallenta comunque CPU e Neural Engine, e
/// insistere scalda il dispositivo e consuma batteria senza vantaggi.
enum ThermalGate {
    static func waitIfNeeded(maxWait: TimeInterval = 600) async throws {
        var waited: TimeInterval = 0
        while ProcessInfo.processInfo.thermalState == .critical, waited < maxWait {
            try await Task.sleep(nanoseconds: 15_000_000_000)
            waited += 15
        }
    }
}
