import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Errori dei servizi AI, normalizzati fra provider diversi.
public enum AIServiceError: Error, Sendable, Equatable {
    case missingCredentials(provider: String)
    case invalidCredentials(provider: String)
    case permissionDenied(provider: String, message: String)
    case rateLimited(retryAfter: TimeInterval?)
    case quotaExceeded(message: String)
    case serverUnavailable(status: Int)
    case badRequest(message: String)
    case payloadTooLarge
    case notFound(message: String)
    case network(String)
    case timeout
    case refused(category: String?)
    case truncated
    case decoding(String)
    case cancelled
    case unsupported(String)

    /// Indica se ha senso ritentare automaticamente la stessa richiesta.
    public var isRetryable: Bool {
        switch self {
        case .rateLimited, .serverUnavailable, .network, .timeout:
            return true
        default:
            return false
        }
    }

    public var retryAfter: TimeInterval? {
        if case .rateLimited(let value) = self { return value }
        return nil
    }

    /// Messaggio in italiano adatto all'interfaccia. Non include mai il
    /// contenuto della trascrizione o della lezione.
    public var userMessage: String {
        switch self {
        case .missingCredentials(let provider):
            return "Nessuna chiave API configurata per \(provider). Aggiungila nelle Impostazioni."
        case .invalidCredentials(let provider):
            return "La chiave API di \(provider) non è valida o è stata revocata."
        case .permissionDenied(let provider, let message):
            return "\(provider) ha negato l'accesso: \(message)"
        case .rateLimited:
            return "Il provider ha temporaneamente limitato le richieste. Verrà ritentato automaticamente."
        case .quotaExceeded(let message):
            return "Credito o quota API esauriti: \(message)"
        case .serverUnavailable(let status):
            return "Il servizio non è al momento disponibile (HTTP \(status)). Verrà ritentato."
        case .badRequest(let message):
            return "Richiesta rifiutata dal provider: \(message)"
        case .payloadTooLarge:
            return "Il file inviato supera il limite del provider."
        case .notFound(let message):
            return "Risorsa non trovata: \(message)"
        case .network(let message):
            return "Problema di rete: \(message)"
        case .timeout:
            return "La richiesta ha impiegato troppo tempo."
        case .refused(let category):
            return "Il modello ha rifiutato di elaborare questo contenuto" + (category.map { " (\($0))" } ?? "") + "."
        case .truncated:
            return "La risposta del modello è stata troncata."
        case .decoding(let message):
            return "Risposta del provider non interpretabile: \(message)"
        case .cancelled:
            return "Operazione annullata."
        case .unsupported(let message):
            return message
        }
    }

    /// Converte un errore qualsiasi (rete, cancellazione, stato HTTP) in un
    /// `AIServiceError`.
    public static func from(_ error: Error, provider: String) -> AIServiceError {
        if let error = error as? AIServiceError { return error }
        if error is CancellationError { return .cancelled }
        if let failure = error as? HTTPStatusFailure {
            return fromHTTP(failure.response, provider: provider)
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled: return .cancelled
            case .timedOut: return .timeout
            default: return .network(urlError.localizedDescription)
            }
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            if nsError.code == NSURLErrorCancelled { return .cancelled }
            if nsError.code == NSURLErrorTimedOut { return .timeout }
            return .network(nsError.localizedDescription)
        }
        return .network(String(describing: error))
    }

    /// Interpreta una risposta HTTP non 2xx di OpenAI o Anthropic.
    public static func fromHTTP(_ response: HTTPResponse, provider: String) -> AIServiceError {
        let message = extractErrorMessage(response.body)
        let lowerMessage = message.lowercased()
        switch response.statusCode {
        case 400:
            if lowerMessage.contains("credit balance") || lowerMessage.contains("billing") {
                return .quotaExceeded(message: message)
            }
            return .badRequest(message: message)
        case 401:
            return .invalidCredentials(provider: provider)
        case 402:
            return .quotaExceeded(message: message)
        case 403:
            return .permissionDenied(provider: provider, message: message)
        case 404:
            return .notFound(message: message)
        case 408:
            return .timeout
        case 413:
            return .payloadTooLarge
        case 429:
            // OpenAI usa 429 anche per "insufficient_quota", che non va ritentato.
            if lowerMessage.contains("quota") || lowerMessage.contains("billing") {
                return .quotaExceeded(message: message)
            }
            let retry = response.header("retry-after").flatMap(TimeInterval.init)
            return .rateLimited(retryAfter: retry)
        case 500...599:
            return .serverUnavailable(status: response.statusCode)
        default:
            return .badRequest(message: "HTTP \(response.statusCode): \(message)")
        }
    }

    static func extractErrorMessage(_ body: Data) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            let text = String(decoding: body.prefix(300), as: UTF8.self)
            return text.isEmpty ? "nessun dettaglio" : text
        }
        if let error = json["error"] as? [String: Any], let message = error["message"] as? String {
            return message
        }
        if let message = json["message"] as? String { return message }
        if let detail = json["detail"] as? String { return detail }
        return "nessun dettaglio"
    }
}
