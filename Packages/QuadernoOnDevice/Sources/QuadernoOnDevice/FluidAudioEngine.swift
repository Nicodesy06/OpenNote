import CoreML
import FluidAudio
import Foundation

/// Esecuzione dei modelli FluidAudio (Parakeet, Canary, SenseVoice) sul
/// Neural Engine. Tiene in memoria un solo modello alla volta: i modelli
/// occupano centinaia di MB e l'iPad può terminare l'app se ne carica più
/// d'uno insieme.
actor FluidAudioEngine {
    static let shared = FluidAudioEngine()

    private enum Loaded {
        case parakeet(AsrManager)
        case canary(CanaryModels)
        case senseVoice(SenseVoiceManager)
    }

    private var loadedKey: String?
    private var loaded: Loaded?

    // MARK: - Varianti

    private static func parakeetVersion(_ engineModel: String) -> AsrModelVersion? {
        switch engineModel {
        case "v3": return .v3
        case "ultra": return .ultra
        case "redux": return .redux
        default: return nil
        }
    }

    private static let canaryPrecision: CanaryPrecision = .int4

    /// Id dei token `<|xx|>` di canary-1b-v2 (vocab.json del modello). FluidAudio
    /// 0.17.7 espone solo il prompt inglese; il formato del prompt è quello di
    /// `CanaryConfig.makePrompt` nelle versioni successive.
    static let canaryLanguageTokens: [String: Int32] = [
        "bg": 46, "hr": 58, "cs": 59, "da": 60, "nl": 62, "en": 64, "et": 66, "fi": 70,
        "fr": 71, "de": 78, "el": 79, "hu": 89, "it": 99, "lv": 117, "lt": 120, "mt": 127,
        "pl": 150, "pt": 151, "ro": 154, "ru": 157, "sk": 167, "sl": 168, "es": 171, "sv": 175, "uk": 192
    ]

    /// ▁ <|startofcontext|> <|startoftranscript|> <|emo:undefined|> <sorgente>
    /// <destinazione> <|pnc|> <|noitn|> <|notimestamp|> <|nodiarize|>
    static func canaryTranscriptionPrompt(languageToken: Int32) -> [Int32] {
        [16053, 7, 4, 16, languageToken, languageToken, 5, 9, 11, 13]
    }
    private static let senseVoicePrecision: SenseVoiceEncoderPrecision = .int8

    private static func repo(_ engineModel: String) -> Repo? {
        if let version = parakeetVersion(engineModel) {
            switch version {
            case .ultra: return .parakeetUltra
            case .redux: return .parakeetRedux
            default: return .parakeetV3
            }
        }
        if engineModel.hasPrefix("canary") { return .canary1bV2 }
        if engineModel.hasPrefix("sensevoice") { return .senseVoiceSmall }
        return nil
    }

    /// Cartella della cache di FluidAudio (Application Support/FluidAudio/Models).
    nonisolated static func directory(engineModel: String) -> URL? {
        guard let repo = repo(engineModel) else { return nil }
        return MLModelConfigurationUtils.defaultModelsDirectory(for: repo)
    }

    nonisolated static func isDownloaded(engineModel: String) -> Bool {
        guard let directory = directory(engineModel: engineModel) else { return false }
        if let version = parakeetVersion(engineModel) {
            return AsrModels.modelsExist(at: directory, version: version)
        }
        if engineModel.hasPrefix("canary") {
            return CanaryModels.modelsExist(at: directory, precision: canaryPrecision)
        }
        if engineModel.hasPrefix("sensevoice") {
            return SenseVoiceModels.modelsExist(at: directory, precision: senseVoicePrecision)
        }
        return false
    }

    // MARK: - Download e caricamento

    /// Scarica i file del modello (riprende quelli già presenti) e lo carica
    /// una volta, così la compilazione per il Neural Engine avviene subito e
    /// non alla prima lezione.
    func download(engineModel: String, progress: @escaping OnDeviceProgressHandler) async throws -> URL {
        let handler: ProgressHandler = { update in
            progress(OnDeviceProgress(fraction: update.fractionCompleted, phase: .downloading))
        }
        let directory: URL
        if let version = Self.parakeetVersion(engineModel) {
            directory = try await AsrModels.download(version: version, progressHandler: handler)
        } else if engineModel.hasPrefix("canary") {
            directory = try await CanaryModels.download(precision: Self.canaryPrecision, progressHandler: handler)
        } else if engineModel.hasPrefix("sensevoice") {
            directory = try await SenseVoiceModels.download(precision: Self.senseVoicePrecision, progressHandler: handler)
        } else {
            throw OnDeviceEngineError.unknownModel(engineModel)
        }
        progress(OnDeviceProgress(fraction: 0, phase: .preparing))
        try await load(engineModel: engineModel)
        progress(OnDeviceProgress(fraction: 1, phase: .preparing))
        return directory
    }

    private func load(engineModel: String) async throws {
        if loadedKey == engineModel, loaded != nil { return }
        unload()
        guard Self.isDownloaded(engineModel: engineModel), let directory = Self.directory(engineModel: engineModel) else {
            throw OnDeviceEngineError.notInstalled(engineModel)
        }
        if let version = Self.parakeetVersion(engineModel) {
            let models = try await AsrModels.load(from: directory, version: version)
            let manager = AsrManager()
            try await manager.loadModels(models)
            loaded = .parakeet(manager)
        } else if engineModel.hasPrefix("canary") {
            loaded = .canary(try CanaryModels.load(from: directory, precision: Self.canaryPrecision))
        } else if engineModel.hasPrefix("sensevoice") {
            let models = try SenseVoiceModels.load(from: directory, precision: Self.senseVoicePrecision)
            loaded = .senseVoice(SenseVoiceManager(models: models))
        } else {
            throw OnDeviceEngineError.unknownModel(engineModel)
        }
        loadedKey = engineModel
    }

    func unload() {
        loaded = nil
        loadedKey = nil
    }

    // MARK: - Trascrizione

    func transcribe(url: URL, engineModel: String, language: String?) async throws -> EngineOutput {
        try await load(engineModel: engineModel)
        switch loaded {
        case .parakeet(let manager):
            var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
            let hint = language.flatMap { Language(rawValue: $0.lowercased()) }
            let result = try await manager.transcribe(url, decoderState: &state, language: hint)
            let tokens = (result.tokenTimings ?? []).map {
                EngineToken(text: $0.token, start: $0.startTime, end: $0.endTime)
            }
            return EngineOutput(text: result.text, tokens: tokens.isEmpty ? nil : tokens, segments: nil, detectedLanguage: language)
        case .canary(let models):
            let code = language?.lowercased() ?? "it"
            let tokenID = Self.canaryLanguageTokens[code] ?? Self.canaryLanguageTokens["it"]!
            let manager = CanaryManager(models: models, prompt: Self.canaryTranscriptionPrompt(languageToken: tokenID))
            let text = try await manager.transcribe(audioURL: url)
            return EngineOutput(text: text, tokens: nil, segments: nil, detectedLanguage: Self.canaryLanguageTokens[code] != nil ? code : "it")
        case .senseVoice(let manager):
            let text = try await manager.transcribe(audioURL: url)
            return EngineOutput(text: text, tokens: nil, segments: nil, detectedLanguage: nil)
        case nil:
            throw OnDeviceEngineError.notInstalled(engineModel)
        }
    }
}
