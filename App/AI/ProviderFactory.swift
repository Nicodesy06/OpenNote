import Foundation
import QuadernoCore
import QuadernoOnDevice

/// Costruisce i provider AI a partire da impostazioni e Keychain. Il
/// provider di trascrizione e quello di generazione sono indipendenti
/// (es. trascrizione OpenAI + sbobinatura Claude).
@MainActor
struct ProviderFactory {
    let settings: AppSettings
    let keychain: KeychainStore
    let transport: HTTPTransport

    static let sharedTransport: HTTPTransport = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 900
        configuration.timeoutIntervalForResource = 60 * 60
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSessionTransport(session: URLSession(configuration: configuration))
    }()

    enum FactoryError: Error, LocalizedError {
        case backendNotConfigured

        var errorDescription: String? {
            "Configura l'indirizzo e il token del backend nelle Impostazioni."
        }
    }

    func transcriptionProvider(id: String, model: String, checkpointDirectory: URL?) throws -> TranscriptionProvider {
        switch id {
        case AppleSpeechTranscriptionProvider().id, OnDeviceTranscriptionProvider.providerID:
            // "apple-ondevice" resta valido per i lavori creati dalle versioni precedenti.
            if let onDevice = OnDeviceModelCatalog.model(id: model), onDevice.engine != .appleSpeech {
                return OnDeviceTranscriptionProvider(model: onDevice)
            }
            return AppleSpeechTranscriptionProvider()
        case AppSettings.TranscriptionProviderChoice.backend.rawValue:
            // Il backend esegue l'intero lavoro lato server (BackendJobClient):
            // non è un provider di trascrizione per chunk.
            throw AIServiceError.unsupported("Con il backend gestito la trascrizione avviene lato server.")
        default:
            let key = keychain.read(account: APIKeyAccount.openAI) ?? ""
            guard !key.isEmpty else { throw AIServiceError.missingCredentials(provider: "OpenAI") }
            var uploadTransport = transport
            if let checkpointDirectory {
                uploadTransport = BackgroundUploadTransport.shared.scoped(checkpointDirectory: checkpointDirectory, model: model, fallback: transport)
            }
            return OpenAITranscriptionProvider(apiKey: key, model: OpenAITranscriptionModel(identifier: model), transport: uploadTransport)
        }
    }

    /// `true` se il provider elabora l'audio sull'iPad, senza rete.
    static func isOnDevice(providerID: String) -> Bool {
        providerID == OnDeviceTranscriptionProvider.providerID || providerID == AppleSpeechTranscriptionProvider().id
    }

    func generationProvider(id: String, model: String) throws -> TextGenerationProvider {
        switch id {
        case OpenAIResponsesProvider.providerID:
            let key = keychain.read(account: APIKeyAccount.openAI) ?? ""
            guard !key.isEmpty else { throw AIServiceError.missingCredentials(provider: "OpenAI") }
            return OpenAIResponsesProvider(apiKey: key, model: model, transport: transport)
        default:
            let key = keychain.read(account: APIKeyAccount.anthropic) ?? ""
            guard !key.isEmpty else { throw AIServiceError.missingCredentials(provider: "Anthropic Claude") }
            return AnthropicProvider(apiKey: key, model: model.isEmpty ? AnthropicProvider.defaultModel : model, transport: transport, useServerSideFallback: settings.useServerSideFallback)
        }
    }

    /// Provider correntemente selezionati nelle impostazioni (per stime e
    /// verifica della configurazione).
    func currentTranscriptionProvider() throws -> TranscriptionProvider {
        try transcriptionProvider(id: settings.transcriptionProvider.rawValue, model: settings.currentTranscriptionModel, checkpointDirectory: nil)
    }

    func currentGenerationProvider() throws -> TextGenerationProvider {
        try generationProvider(id: settings.generationProvider.rawValue, model: settings.currentGenerationModel)
    }

    func backendClient() throws -> BackendJobClient {
        guard let url = URL(string: settings.backendURL), !settings.backendURL.isEmpty,
              let token = keychain.read(account: APIKeyAccount.backendToken), !token.isEmpty else {
            throw FactoryError.backendNotConfigured
        }
        return BackendJobClient(baseURL: url, token: token, transport: transport)
    }

    func prompts() -> PromptLibrary {
        var library = (try? PromptLibrary.load()) ?? PromptLibrary(version: "mancante", templates: [:])
        library.systemOverride = settings.customSystemPrompt
        return library
    }

    func sbobinaturaConfiguration() -> SbobinaturaConfiguration {
        SbobinaturaConfiguration(writingEffort: settings.writingEffort, verifyWithModel: settings.verifyWithModel, autoRepair: settings.autoRepair)
    }
}
