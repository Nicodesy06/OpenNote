import Foundation

/// Client della Messages API di Anthropic via HTTP (non esiste un SDK Swift
/// ufficiale). Autenticazione con chiave API dell'utente (Bring Your Own Key).
public struct AnthropicProvider: TextGenerationProvider {
    public static let providerID = "anthropic"
    public static let defaultModel = "claude-opus-5-5"
    public static let apiVersion = "2023-06-01"
    /// Beta che consente al server di ripetere la richiesta su un modello di
    /// fallback se i classificatori di sicurezza rifiutano un contenuto
    /// legittimo (es. lezioni di biologia o sicurezza informatica).
    public static let fallbackBeta = "server-side-fallback-2026-07-01"

    public let id = AnthropicProvider.providerID
    public let displayName = "Anthropic Claude"
    public let model: String
    private let apiKey: String
    private let transport: HTTPTransport
    private let baseURL: URL
    public var useServerSideFallback: Bool

    public init(apiKey: String, model: String = AnthropicProvider.defaultModel, transport: HTTPTransport, baseURL: URL = URL(string: "https://api.anthropic.com/v1")!, useServerSideFallback: Bool = true) {
        self.apiKey = apiKey
        self.model = model
        self.transport = transport
        self.baseURL = baseURL
        self.useServerSideFallback = useServerSideFallback
    }

    /// Contesto di 1M token sui modelli attuali; si usa un budget prudente
    /// (circa 3,5 caratteri per token in italiano).
    public var inputCharacterBudget: Int { 600_000 }

    public var indicativePricePerMillion: (input: Double, output: Double)? {
        Self.indicativePrices[model]
    }

    static let indicativePrices: [String: (input: Double, output: Double)] = [
        "claude-opus-5-5": (4, 20),
        "claude-opus-5": (5, 25),
        "claude-sonnet-5-5": (2, 10),
        "claude-sonnet-5": (2, 10),
        "claude-haiku-5-5": (0.10, 0.50),
        "claude-fable-5-1": (10, 50)
    ]

    /// Modelli che accettano `fallbacks: "default"` (documentazione API,
    /// ottobre 2026).
    static func supportsDefaultFallback(_ model: String) -> Bool {
        ["claude-opus-5-5", "claude-opus-5", "claude-fable-5-1", "claude-sonnet-5-5"].contains(model)
    }

    /// Modelli che accettano `output_config.effort`.
    static func supportsEffort(_ model: String) -> Bool {
        let patterns = ["claude-opus-5", "claude-sonnet-5", "claude-haiku-5", "claude-fable-5", "claude-mythos-5", "claude-opus-4-5", "claude-opus-4-6", "claude-opus-4-7", "claude-opus-4-8", "claude-sonnet-4-6"]
        return patterns.contains { model.hasPrefix($0) }
    }

    private var headers: [String: String] {
        var headers = [
            "x-api-key": apiKey,
            "anthropic-version": Self.apiVersion,
            "content-type": "application/json"
        ]
        if useServerSideFallback && Self.supportsDefaultFallback(model) {
            headers["anthropic-beta"] = Self.fallbackBeta
        }
        return headers
    }

    /// Corpo della richiesta; esposto per i test.
    public func makeBody(_ request: GenerationRequest) -> JSONValue {
        var body: [String: JSONValue] = [
            "model": .string(model),
            "max_tokens": .number(Double(request.maxOutputTokens)),
            "system": .string(request.system),
            "messages": .array(request.messages.map { message in
                ["role": .string(message.role.rawValue), "content": .string(message.text)]
            })
        ]
        // Il pensiero adattivo è attivo per impostazione predefinita sui
        // modelli attuali: il parametro `thinking` viene omesso.
        var outputConfig: [String: JSONValue] = [:]
        if let effort = request.effort, Self.supportsEffort(model) {
            outputConfig["effort"] = .string(effort.rawValue)
        }
        if let schema = request.jsonSchema {
            outputConfig["format"] = ["type": "json_schema", "schema": schema.schema]
        }
        if !outputConfig.isEmpty { body["output_config"] = .object(outputConfig) }
        if useServerSideFallback && Self.supportsDefaultFallback(model) {
            body["fallbacks"] = "default"
        }
        if request.stream { body["stream"] = true }
        return .object(body)
    }

    public func generate(_ request: GenerationRequest, onTextDelta: (@Sendable (String) -> Void)?) async throws -> GenerationResult {
        guard !apiKey.isEmpty else { throw AIServiceError.missingCredentials(provider: displayName) }
        let httpRequest = HTTPRequest(
            url: baseURL.appendingPathComponent("messages"),
            method: "POST",
            headers: headers,
            body: .data(try makeBody(request).encoded()),
            timeout: request.stream ? 900 : 600
        )
        if request.stream {
            return try await streamed(httpRequest, onTextDelta: onTextDelta)
        }
        let response: HTTPResponse
        do {
            response = try await transport.send(httpRequest)
        } catch {
            throw AIServiceError.from(error, provider: displayName)
        }
        guard (200..<300).contains(response.statusCode) else {
            throw AIServiceError.fromHTTP(response, provider: displayName)
        }
        return try Self.parseMessage(response.body, requestedModel: model)
    }

    public static func parseMessage(_ data: Data, requestedModel: String) throws -> GenerationResult {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIServiceError.decoding("Messaggio Anthropic non valido")
        }
        let content = json["content"] as? [[String: Any]] ?? []
        // Si considerano solo i blocchi di testo: blocchi di pensiero o di
        // fallback non fanno parte del documento.
        let text = content.compactMap { block -> String? in
            guard block["type"] as? String == "text" else { return nil }
            return block["text"] as? String
        }.joined()
        let usage = json["usage"] as? [String: Any]
        let stopReason = mapStopReason(json["stop_reason"] as? String)
        let stopDetails = json["stop_details"] as? [String: Any]
        return GenerationResult(
            text: text,
            stopReason: stopReason,
            usage: GenerationUsage(inputTokens: usage?["input_tokens"] as? Int ?? 0, outputTokens: usage?["output_tokens"] as? Int ?? 0),
            model: json["model"] as? String ?? requestedModel,
            refusalCategory: stopDetails?["category"] as? String
        )
    }

    static func mapStopReason(_ value: String?) -> GenerationStopReason {
        switch value {
        case "end_turn", "stop_sequence": return .complete
        case "max_tokens", "model_context_window_exceeded": return .maxTokens
        case "refusal": return .refusal
        default: return .other
        }
    }

    /// Accumulatore degli eventi di streaming; separato per essere testabile.
    public struct StreamAccumulator: Sendable {
        public private(set) var text = ""
        public private(set) var usage = GenerationUsage()
        public private(set) var stopReason: GenerationStopReason = .other
        public private(set) var model: String
        public private(set) var refusalCategory: String?
        private var textBlockIndexes = Set<Int>()

        public init(model: String) { self.model = model }

        /// Elabora un payload `data:`; restituisce l'eventuale delta di testo.
        public mutating func consume(_ payload: String) throws -> String? {
            guard let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = json["type"] as? String else { return nil }
            switch type {
            case "message_start":
                if let message = json["message"] as? [String: Any] {
                    if let value = message["model"] as? String { model = value }
                    if let usageJSON = message["usage"] as? [String: Any] {
                        usage.inputTokens = usageJSON["input_tokens"] as? Int ?? usage.inputTokens
                    }
                }
            case "content_block_start":
                if let index = json["index"] as? Int, let block = json["content_block"] as? [String: Any], block["type"] as? String == "text" {
                    textBlockIndexes.insert(index)
                    if let initial = block["text"] as? String, !initial.isEmpty {
                        text += initial
                        return initial
                    }
                }
            case "content_block_delta":
                if let delta = json["delta"] as? [String: Any], delta["type"] as? String == "text_delta", let piece = delta["text"] as? String {
                    text += piece
                    return piece
                }
            case "message_delta":
                if let delta = json["delta"] as? [String: Any] {
                    if let reason = delta["stop_reason"] as? String { stopReason = AnthropicProvider.mapStopReason(reason) }
                    if let details = delta["stop_details"] as? [String: Any] { refusalCategory = details["category"] as? String }
                }
                if let usageJSON = json["usage"] as? [String: Any] {
                    usage.outputTokens = usageJSON["output_tokens"] as? Int ?? usage.outputTokens
                    if let input = usageJSON["input_tokens"] as? Int, input > 0 { usage.inputTokens = input }
                }
            case "error":
                let error = json["error"] as? [String: Any]
                let errorType = error?["type"] as? String ?? ""
                let message = error?["message"] as? String ?? "errore di streaming"
                switch errorType {
                case "overloaded_error": throw AIServiceError.serverUnavailable(status: 529)
                case "rate_limit_error": throw AIServiceError.rateLimited(retryAfter: nil)
                case "api_error": throw AIServiceError.serverUnavailable(status: 500)
                case "authentication_error": throw AIServiceError.invalidCredentials(provider: "Anthropic Claude")
                default: throw AIServiceError.badRequest(message: message)
                }
            default:
                break
            }
            return nil
        }

        public var result: GenerationResult {
            GenerationResult(text: text, stopReason: stopReason, usage: usage, model: model, refusalCategory: refusalCategory)
        }
    }

    private func streamed(_ request: HTTPRequest, onTextDelta: (@Sendable (String) -> Void)?) async throws -> GenerationResult {
        var parser = SSELineParser()
        var accumulator = StreamAccumulator(model: model)
        do {
            for try await line in transport.streamLines(request) {
                guard let event = parser.consume(line) else { continue }
                if let delta = try accumulator.consume(event.data) {
                    onTextDelta?(delta)
                }
            }
        } catch {
            throw AIServiceError.from(error, provider: displayName)
        }
        return accumulator.result
    }

    public func listModels() async throws -> [String] {
        guard !apiKey.isEmpty else { throw AIServiceError.missingCredentials(provider: displayName) }
        var components = URLComponents(url: baseURL.appendingPathComponent("models"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "limit", value: "100")]
        let request = HTTPRequest(url: components.url!, headers: ["x-api-key": apiKey, "anthropic-version": Self.apiVersion], timeout: 30)
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
        return data.compactMap { $0["id"] as? String }
    }
}
