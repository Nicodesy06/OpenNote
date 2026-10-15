import Foundation

public struct LLMMessage: Sendable, Equatable, Codable {
    public enum Role: String, Sendable, Codable { case user, assistant }
    public var role: Role
    public var text: String

    public init(role: Role, text: String) {
        self.role = role
        self.text = text
    }

    public static func user(_ text: String) -> LLMMessage { LLMMessage(role: .user, text: text) }
}

/// Schema JSON per output strutturati. Deve rispettare le regole comuni ad
/// Anthropic e OpenAI strict mode: tutti i campi obbligatori e
/// `additionalProperties: false`.
public struct JSONSchemaSpec: Sendable, Equatable {
    public var name: String
    public var schema: JSONValue

    public init(name: String, schema: JSONValue) {
        self.name = name
        self.schema = schema
    }
}

/// Livello di sforzo di ragionamento, tradotto per ciascun provider.
public enum GenerationEffort: String, Sendable, Codable, CaseIterable {
    case low, medium, high, xhigh, max
}

public struct GenerationRequest: Sendable, Equatable {
    public var system: String
    public var messages: [LLMMessage]
    public var maxOutputTokens: Int
    public var jsonSchema: JSONSchemaSpec?
    public var effort: GenerationEffort?
    /// Se `true` e il provider lo supporta, la risposta viene trasmessa in
    /// streaming (consigliato per output lunghi: evita timeout HTTP).
    public var stream: Bool

    public init(system: String, messages: [LLMMessage], maxOutputTokens: Int = 16_000, jsonSchema: JSONSchemaSpec? = nil, effort: GenerationEffort? = nil, stream: Bool = false) {
        self.system = system
        self.messages = messages
        self.maxOutputTokens = maxOutputTokens
        self.jsonSchema = jsonSchema
        self.effort = effort
        self.stream = stream
    }
}

public enum GenerationStopReason: String, Sendable, Codable {
    case complete
    case maxTokens
    case refusal
    case other
}

public struct GenerationUsage: Sendable, Equatable, Codable {
    public var inputTokens: Int
    public var outputTokens: Int

    public init(inputTokens: Int = 0, outputTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }

    public static func + (lhs: GenerationUsage, rhs: GenerationUsage) -> GenerationUsage {
        GenerationUsage(inputTokens: lhs.inputTokens + rhs.inputTokens, outputTokens: lhs.outputTokens + rhs.outputTokens)
    }
}

public struct GenerationResult: Sendable, Equatable {
    public var text: String
    public var stopReason: GenerationStopReason
    public var usage: GenerationUsage
    public var model: String
    public var refusalCategory: String?

    public init(text: String, stopReason: GenerationStopReason, usage: GenerationUsage, model: String, refusalCategory: String? = nil) {
        self.text = text
        self.stopReason = stopReason
        self.usage = usage
        self.model = model
        self.refusalCategory = refusalCategory
    }
}

/// Provider di generazione testuale (rielaborazione della sbobinatura),
/// indipendente dal provider di trascrizione.
public protocol TextGenerationProvider: Sendable {
    var id: String { get }
    var displayName: String { get }
    var model: String { get }
    /// Numero indicativo di caratteri di input gestibili in una richiesta,
    /// usato per decidere come suddividere la trascrizione.
    var inputCharacterBudget: Int { get }
    /// Prezzi indicativi per milione di token (input, output), se noti.
    var indicativePricePerMillion: (input: Double, output: Double)? { get }

    func generate(_ request: GenerationRequest, onTextDelta: (@Sendable (String) -> Void)?) async throws -> GenerationResult
    func listModels() async throws -> [String]
}

public extension TextGenerationProvider {
    func generate(_ request: GenerationRequest) async throws -> GenerationResult {
        try await generate(request, onTextDelta: nil)
    }
}

/// Parser riga per riga di Server-Sent Events. Non dipende dalle righe vuote
/// separatrici: ogni riga `data:` di Anthropic e OpenAI contiene un oggetto
/// JSON completo.
public struct SSELineParser: Sendable {
    public private(set) var currentEvent: String?

    public init() {}

    /// Restituisce il payload JSON se la riga è una riga `data:`.
    public mutating func consume(_ line: String) -> (event: String?, data: String)? {
        let trimmed = line.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
        if trimmed.isEmpty {
            currentEvent = nil
            return nil
        }
        if trimmed.hasPrefix(":") { return nil }
        if trimmed.hasPrefix("event:") {
            currentEvent = trimmed.dropFirst("event:".count).trimmingCharacters(in: .whitespaces)
            return nil
        }
        if trimmed.hasPrefix("data:") {
            let payload = trimmed.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
            return (currentEvent, payload)
        }
        return nil
    }
}
