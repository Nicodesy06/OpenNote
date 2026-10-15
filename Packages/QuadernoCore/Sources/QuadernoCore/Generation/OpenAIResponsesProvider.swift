import Foundation

/// Client della Responses API di OpenAI per la rielaborazione testuale.
/// Il modello non è fissato nel codice: l'utente lo sceglie dall'elenco
/// restituito da `GET /v1/models` del proprio account.
public struct OpenAIResponsesProvider: TextGenerationProvider {
    public static let providerID = "openai"

    public let id = OpenAIResponsesProvider.providerID
    public let displayName = "OpenAI"
    public let model: String
    private let apiKey: String
    private let transport: HTTPTransport
    private let baseURL: URL
    public var characterBudget: Int

    public init(apiKey: String, model: String, transport: HTTPTransport, baseURL: URL = URL(string: "https://api.openai.com/v1")!, characterBudget: Int = 300_000) {
        self.apiKey = apiKey
        self.model = model
        self.transport = transport
        self.baseURL = baseURL
        self.characterBudget = characterBudget
    }

    public var inputCharacterBudget: Int { characterBudget }
    public var indicativePricePerMillion: (input: Double, output: Double)? { nil }

    /// I modelli di ragionamento accettano `reasoning.effort`.
    static func supportsReasoningEffort(_ model: String) -> Bool {
        model.hasPrefix("gpt-5") || model.hasPrefix("gpt-6") || model.hasPrefix("o3") || model.hasPrefix("o4")
    }

    public func makeBody(_ request: GenerationRequest) -> JSONValue {
        var body: [String: JSONValue] = [
            "model": .string(model),
            "instructions": .string(request.system),
            "input": .array(request.messages.map { message in
                ["role": .string(message.role.rawValue), "content": .string(message.text)]
            }),
            "max_output_tokens": .number(Double(request.maxOutputTokens)),
            "store": false
        ]
        if let schema = request.jsonSchema {
            body["text"] = ["format": ["type": "json_schema", "name": .string(schema.name), "schema": schema.schema, "strict": true]]
        }
        if let effort = request.effort, Self.supportsReasoningEffort(model) {
            let mapped: String
            switch effort {
            case .low: mapped = "low"
            case .medium: mapped = "medium"
            case .high, .xhigh, .max: mapped = "high"
            }
            body["reasoning"] = ["effort": .string(mapped)]
        }
        if request.stream { body["stream"] = true }
        return .object(body)
    }

    private var headers: [String: String] {
        ["Authorization": "Bearer \(apiKey)", "Content-Type": "application/json"]
    }

    public func generate(_ request: GenerationRequest, onTextDelta: (@Sendable (String) -> Void)?) async throws -> GenerationResult {
        guard !apiKey.isEmpty else { throw AIServiceError.missingCredentials(provider: displayName) }
        guard !model.isEmpty else { throw AIServiceError.unsupported("Seleziona un modello OpenAI nelle Impostazioni.") }
        let httpRequest = HTTPRequest(url: baseURL.appendingPathComponent("responses"), method: "POST", headers: headers, body: .data(try makeBody(request).encoded()), timeout: request.stream ? 900 : 600)
        if request.stream {
            var parser = SSELineParser()
            var accumulator = StreamAccumulator(model: model)
            do {
                for try await line in transport.streamLines(httpRequest) {
                    guard let event = parser.consume(line) else { continue }
                    if let delta = try accumulator.consume(event.data) { onTextDelta?(delta) }
                }
            } catch {
                throw AIServiceError.from(error, provider: displayName)
            }
            return accumulator.result
        }
        let response: HTTPResponse
        do {
            response = try await transport.send(httpRequest)
        } catch {
            throw AIServiceError.from(error, provider: displayName)
        }
        guard (200..<300).contains(response.statusCode) else { throw AIServiceError.fromHTTP(response, provider: displayName) }
        return try Self.parseResponse(response.body, requestedModel: model)
    }

    public static func parseResponse(_ data: Data, requestedModel: String) throws -> GenerationResult {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIServiceError.decoding("Risposta OpenAI non valida")
        }
        return result(from: json, requestedModel: requestedModel, streamedText: nil)
    }

    static func result(from json: [String: Any], requestedModel: String, streamedText: String?) -> GenerationResult {
        var text = ""
        var refusal: String?
        if let streamedText {
            text = streamedText
        } else {
            for item in json["output"] as? [[String: Any]] ?? [] where item["type"] as? String == "message" {
                for part in item["content"] as? [[String: Any]] ?? [] {
                    switch part["type"] as? String {
                    case "output_text": text += part["text"] as? String ?? ""
                    case "refusal": refusal = part["refusal"] as? String ?? "refusal"
                    default: break
                    }
                }
            }
        }
        let status = json["status"] as? String
        let incomplete = (json["incomplete_details"] as? [String: Any])?["reason"] as? String
        var stopReason: GenerationStopReason = .complete
        if refusal != nil {
            stopReason = .refusal
        } else if status == "incomplete" {
            stopReason = incomplete == "max_output_tokens" ? .maxTokens : .other
        } else if status != nil && status != "completed" {
            stopReason = .other
        }
        let usage = json["usage"] as? [String: Any]
        return GenerationResult(
            text: text,
            stopReason: stopReason,
            usage: GenerationUsage(inputTokens: usage?["input_tokens"] as? Int ?? 0, outputTokens: usage?["output_tokens"] as? Int ?? 0),
            model: json["model"] as? String ?? requestedModel,
            refusalCategory: refusal
        )
    }

    public struct StreamAccumulator: Sendable {
        public private(set) var text = ""
        private var final: GenerationResult?
        private let model: String

        public init(model: String) { self.model = model }

        public mutating func consume(_ payload: String) throws -> String? {
            guard let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = json["type"] as? String else { return nil }
            switch type {
            case "response.output_text.delta":
                if let delta = json["delta"] as? String {
                    text += delta
                    return delta
                }
            case "response.completed", "response.incomplete":
                if let response = json["response"] as? [String: Any] {
                    final = OpenAIResponsesProvider.result(from: response, requestedModel: model, streamedText: text)
                }
            case "response.failed":
                let error = (json["response"] as? [String: Any])?["error"] as? [String: Any]
                let message = error?["message"] as? String ?? "elaborazione non riuscita"
                if (error?["code"] as? String) == "server_error" { throw AIServiceError.serverUnavailable(status: 500) }
                throw AIServiceError.badRequest(message: message)
            case "error":
                let message = json["message"] as? String ?? "errore di streaming"
                throw AIServiceError.badRequest(message: message)
            case "response.refusal.delta":
                break
            default:
                break
            }
            return nil
        }

        public var result: GenerationResult {
            final ?? GenerationResult(text: text, stopReason: .other, usage: GenerationUsage(), model: model)
        }
    }

    public func listModels() async throws -> [String] {
        guard !apiKey.isEmpty else { throw AIServiceError.missingCredentials(provider: displayName) }
        let request = HTTPRequest(url: baseURL.appendingPathComponent("models"), headers: ["Authorization": "Bearer \(apiKey)"], timeout: 30)
        let response: HTTPResponse
        do {
            response = try await transport.send(request)
        } catch {
            throw AIServiceError.from(error, provider: displayName)
        }
        guard (200..<300).contains(response.statusCode) else { throw AIServiceError.fromHTTP(response, provider: displayName) }
        guard let json = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any], let data = json["data"] as? [[String: Any]] else {
            throw AIServiceError.decoding("Elenco modelli non valido")
        }
        return data.compactMap { $0["id"] as? String }.sorted()
    }

    /// Suggerisce un modello di testo fra quelli disponibili, preferendo le
    /// famiglie più recenti. Non sostituisce la scelta dell'utente.
    public static func suggestTextModel(from models: [String]) -> String? {
        let excluded = ["transcribe", "tts", "audio", "realtime", "image", "embedding", "moderation", "search", "whisper", "dall-e", "codex", "mini-tts"]
        let candidates = models.filter { model in !excluded.contains { model.contains($0) } }
        for prefix in ["gpt-6", "gpt-5"] {
            let family = candidates.filter { $0.hasPrefix(prefix) && !$0.contains("nano") && !$0.contains("mini") }
            // Preferisce gli alias senza data (es. "gpt-5.5" invece di "gpt-5.5-2026-..").
            if let alias = family.filter({ $0.range(of: #"\d{4}-\d{2}-\d{2}"#, options: .regularExpression) == nil }).sorted().last {
                return alias
            }
            if let any = family.sorted().last { return any }
        }
        return candidates.first { $0.hasPrefix("gpt-4.1") } ?? candidates.first
    }
}
