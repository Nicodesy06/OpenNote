import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Famiglie di modelli OpenAI per la trascrizione di file, con parametri e
/// formati di risposta diversi (verificati sulla documentazione OpenAI di
/// ottobre 2026: guida "File transcription" e cookbook di migrazione a
/// gpt-transcribe).
public enum OpenAITranscriptionModel: Sendable, Equatable, Hashable, Codable {
    /// `gpt-transcribe`: modello consigliato per file completi. Supporta
    /// `prompt`, `keywords`, `languages`. Restituisce solo testo, senza
    /// timestamp di segmento.
    case gptTranscribe
    /// `gpt-4o-transcribe-diarize`: etichette degli interlocutori e segmenti
    /// con tempi (`diarized_json`). Non supporta prompt; richiede
    /// `chunking_strategy` per audio oltre 30 secondi.
    case diarize
    /// `whisper-1`: unico modello con timestamp di segmento
    /// (`verbose_json`). Prompt limitato a circa 224 token.
    case whisper
    /// `gpt-4o-transcribe` / `gpt-4o-mini-transcribe` o altri modelli
    /// compatibili: solo testo, `language` singolo e `prompt`.
    case legacy(String)

    public var identifier: String {
        switch self {
        case .gptTranscribe: return "gpt-transcribe"
        case .diarize: return "gpt-4o-transcribe-diarize"
        case .whisper: return "whisper-1"
        case .legacy(let name): return name
        }
    }

    public init(identifier: String) {
        switch identifier {
        case "gpt-transcribe": self = .gptTranscribe
        case "gpt-4o-transcribe-diarize": self = .diarize
        case "whisper-1": self = .whisper
        default: self = .legacy(identifier)
        }
    }

    /// Prezzo indicativo per minuto (USD). Da verificare sul listino
    /// corrente: usato solo per mostrare una stima prima dell'invio.
    public var indicativeUSDPerMinute: Double {
        switch self {
        case .gptTranscribe: return 0.0045
        case .diarize: return 0.006
        case .whisper: return 0.006
        case .legacy(let name): return name.contains("mini") ? 0.003 : 0.006
        }
    }
}

public struct OpenAITranscriptionProvider: TranscriptionProvider {
    public static let providerID = "openai"
    public static let uploadLimitBytes = 25 * 1024 * 1024

    public let id = OpenAITranscriptionProvider.providerID
    public let displayName = "OpenAI"
    public let transcriptionModel: OpenAITranscriptionModel
    private let apiKey: String
    private let baseURL: URL
    private let transport: HTTPTransport
    private let temporaryDirectory: URL

    public var model: String { transcriptionModel.identifier }

    public init(apiKey: String, model: OpenAITranscriptionModel = .gptTranscribe, transport: HTTPTransport, baseURL: URL = URL(string: "https://api.openai.com/v1")!, temporaryDirectory: URL = FileManager.default.temporaryDirectory) {
        self.apiKey = apiKey
        self.transcriptionModel = model
        self.transport = transport
        self.baseURL = baseURL
        self.temporaryDirectory = temporaryDirectory
    }

    public var capabilities: TranscriptionCapabilities {
        TranscriptionCapabilities(
            maxUploadBytes: Self.uploadLimitBytes,
            maxChunkDuration: nil,
            returnsSegmentTimestamps: transcriptionModel == .diarize || transcriptionModel == .whisper,
            supportsDiarization: transcriptionModel == .diarize,
            supportsPrompt: transcriptionModel != .diarize,
            supportsKeywords: transcriptionModel == .gptTranscribe,
            maxKeywords: transcriptionModel == .gptTranscribe ? 100 : 0,
            requiresNetwork: true,
            supportedFileExtensions: ["mp3", "mp4", "mpeg", "mpga", "m4a", "wav", "webm"]
        )
    }

    public func estimateCost(durationSeconds: TimeInterval) -> CostEstimate? {
        let minutes = durationSeconds / 60
        return CostEstimate(amountUSD: minutes * transcriptionModel.indicativeUSDPerMinute,
                            basis: String(format: "%.1f min × $%.4f/min (%@, prezzo indicativo)", minutes, transcriptionModel.indicativeUSDPerMinute, model))
    }

    /// Costruisce il corpo multipart; esposto per i test.
    public func makeForm(chunk: AudioChunkFile, options: TranscriptionOptions) -> MultipartFormData {
        var form = MultipartFormData()
        form.addField("model", model)
        switch transcriptionModel {
        case .gptTranscribe:
            form.addField("response_format", "json")
            for language in options.languages { form.addField("languages[]", language) }
            if let prompt = Self.sanitizedPrompt(options.prompt, maxCharacters: 4000) { form.addField("prompt", prompt) }
            for keyword in Self.sanitizedKeywords(options.keywords, max: capabilities.maxKeywords) {
                form.addField("keywords[]", keyword)
            }
        case .diarize:
            form.addField("response_format", "diarized_json")
            form.addField("chunking_strategy", "auto")
            if let language = options.languages.first, options.languages.count == 1 { form.addField("language", language) }
        case .whisper:
            form.addField("response_format", "verbose_json")
            form.addField("timestamp_granularities[]", "segment")
            if let language = options.languages.first, options.languages.count == 1 { form.addField("language", language) }
            // Il prompt di whisper-1 è limitato a ~224 token: si privilegiano i
            // termini del glossario, che aiutano l'ortografia dei nomi.
            let glossaryPrompt = options.keywords.isEmpty ? nil : options.keywords.prefix(40).joined(separator: ", ")
            if let prompt = Self.sanitizedPrompt(glossaryPrompt ?? options.prompt, maxCharacters: 700) { form.addField("prompt", prompt) }
        case .legacy:
            form.addField("response_format", "json")
            if let language = options.languages.first, options.languages.count == 1 { form.addField("language", language) }
            var promptParts: [String] = []
            if let prompt = options.prompt { promptParts.append(prompt) }
            if !options.keywords.isEmpty { promptParts.append("Termini: " + options.keywords.prefix(60).joined(separator: ", ")) }
            if let prompt = Self.sanitizedPrompt(promptParts.joined(separator: "\n"), maxCharacters: 2000) { form.addField("prompt", prompt) }
        }
        let fileName = "chunk-\(chunk.spec.index).\(chunk.url.pathExtension.isEmpty ? "m4a" : chunk.url.pathExtension)"
        form.addFile("file", fileName: fileName, mimeType: chunk.mimeType, url: chunk.url)
        return form
    }

    static func sanitizedPrompt(_ prompt: String?, maxCharacters: Int) -> String? {
        guard let prompt = prompt?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty else { return nil }
        return String(prompt.prefix(maxCharacters))
    }

    /// Le keyword devono essere letterali su una riga senza `<`, `>`, CR, LF:
    /// un valore non valido fa rifiutare l'intera richiesta.
    static func sanitizedKeywords(_ keywords: [String], max: Int) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for keyword in keywords {
            let cleaned = keyword
                .replacingOccurrences(of: "<", with: "")
                .replacingOccurrences(of: ">", with: "")
                .replacingOccurrences(of: "\r", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespaces)
            guard !cleaned.isEmpty, cleaned.count <= 100, !seen.contains(cleaned.lowercased()) else { continue }
            seen.insert(cleaned.lowercased())
            result.append(cleaned)
            if result.count >= max { break }
        }
        return result
    }

    public func transcribe(chunk: AudioChunkFile, options: TranscriptionOptions) async throws -> ChunkTranscription {
        guard !apiKey.isEmpty else { throw AIServiceError.missingCredentials(provider: displayName) }
        guard chunk.byteSize <= Self.uploadLimitBytes else { throw AIServiceError.payloadTooLarge }
        let form = makeForm(chunk: chunk, options: options)
        let bodyURL = temporaryDirectory.appendingPathComponent("openai-upload-\(UUID().uuidString).multipart")
        try form.write(to: bodyURL)
        defer { try? FileManager.default.removeItem(at: bodyURL) }
        let request = HTTPRequest(
            url: baseURL.appendingPathComponent("audio/transcriptions"),
            method: "POST",
            headers: ["Authorization": "Bearer \(apiKey)", "Content-Type": form.contentType],
            body: .file(bodyURL),
            timeout: 600
        )
        let response: HTTPResponse
        do {
            response = try await transport.send(request)
        } catch {
            throw AIServiceError.from(error, provider: displayName)
        }
        guard (200..<300).contains(response.statusCode) else {
            throw AIServiceError.fromHTTP(response, provider: displayName)
        }
        return try Self.parse(response.body, model: transcriptionModel)
    }

    /// Interpreta le tre forme di risposta (json, diarized_json, verbose_json).
    public static func parse(_ data: Data, model: OpenAITranscriptionModel) throws -> ChunkTranscription {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIServiceError.decoding("JSON di trascrizione non valido")
        }
        let text = (json["text"] as? String) ?? ""
        var languages: [String] = []
        if let list = json["languages"] as? [[String: Any]] {
            languages = list.compactMap { $0["code"] as? String }
        } else if let language = json["language"] as? String {
            languages = [language]
        }
        var segments: [TimedText]?
        if let rawSegments = json["segments"] as? [[String: Any]] {
            segments = rawSegments.compactMap { raw in
                guard let start = number(raw["start"]), let end = number(raw["end"]) else { return nil }
                let segmentText = (raw["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let speaker = raw["speaker"] as? String
                return TimedText(start: start, end: end, text: segmentText, speaker: speaker)
            }
        }
        if text.isEmpty && (segments?.isEmpty ?? true) {
            // Un chunk silenzioso produce legittimamente testo vuoto.
            return ChunkTranscription(text: "", segments: nil, detectedLanguages: languages, model: model.identifier, providerID: providerID)
        }
        return ChunkTranscription(text: text, segments: segments, detectedLanguages: languages, model: model.identifier, providerID: providerID)
    }

    static func number(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }
}
