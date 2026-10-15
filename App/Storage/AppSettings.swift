import Foundation
import Combine
import QuadernoCore

/// Preferenze non segrete, salvate in UserDefaults. Le chiavi API stanno nel
/// Keychain (`KeychainStore`).
final class AppSettings: ObservableObject {
    enum TranscriptionProviderChoice: String, CaseIterable, Identifiable {
        case openAI = "openai"
        case appleOnDevice = "apple-ondevice"
        case backend = "backend"
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .openAI: return "OpenAI (cloud)"
            case .appleOnDevice: return "Apple — sul dispositivo"
            case .backend: return "Backend Quaderno AI"
            }
        }
    }

    enum GenerationProviderChoice: String, CaseIterable, Identifiable {
        case anthropic = "anthropic"
        case openAI = "openai"
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .anthropic: return "Anthropic Claude"
            case .openAI: return "OpenAI"
            }
        }
    }

    private let defaults: UserDefaults

    // Provider AI
    @Published var transcriptionProvider: TranscriptionProviderChoice { didSet { save(transcriptionProvider.rawValue, "transcriptionProvider") } }
    @Published var openAITranscriptionModel: String { didSet { save(openAITranscriptionModel, "openAITranscriptionModel") } }
    @Published var generationProvider: GenerationProviderChoice { didSet { save(generationProvider.rawValue, "generationProvider") } }
    @Published var anthropicModel: String { didSet { save(anthropicModel, "anthropicModel") } }
    @Published var openAITextModel: String { didSet { save(openAITextModel, "openAITextModel") } }
    @Published var writingEffort: GenerationEffort { didSet { save(writingEffort.rawValue, "writingEffort") } }
    @Published var verifyWithModel: Bool { didSet { save(verifyWithModel, "verifyWithModel") } }
    @Published var autoRepair: Bool { didSet { save(autoRepair, "autoRepair") } }
    @Published var useServerSideFallback: Bool { didSet { save(useServerSideFallback, "useServerSideFallback") } }
    @Published var customSystemPrompt: String { didSet { save(customSystemPrompt, "customSystemPrompt") } }
    @Published var transcriptionChunkMinutes: Double { didSet { save(transcriptionChunkMinutes, "transcriptionChunkMinutes") } }
    @Published var defaultMode: SbobinaturaMode { didSet { save(defaultMode.rawValue, "defaultMode") } }
    @Published var backendURL: String { didSet { save(backendURL, "backendURL") } }

    // Registrazione
    @Published var recordingProfile: RecordingProfileID { didSet { save(recordingProfile.rawValue, "recordingProfile") } }
    @Published var recordingBitrate: Int { didSet { save(recordingBitrate, "recordingBitrate") } }
    @Published var segmentMinutes: Double { didSet { save(segmentMinutes, "segmentMinutes") } }
    @Published var experimentalGainDB: Double { didSet { save(experimentalGainDB, "experimentalGainDB") } }
    @Published var autoResumeAfterInterruption: Bool { didSet { save(autoResumeAfterInterruption, "autoResumeAfterInterruption") } }
    @Published var notifyOnInterruption: Bool { didSet { save(notifyOnInterruption, "notifyOnInterruption") } }
    @Published var preferredInputUID: String { didSet { save(preferredInputUID, "preferredInputUID") } }
    @Published var preferredDataSourceID: Int { didSet { save(preferredDataSourceID, "preferredDataSourceID") } }

    // Scrittura
    @Published var fingerDrawing: Bool { didSet { save(fingerDrawing, "fingerDrawing") } }

    // Privacy: avvisi già mostrati per provider.
    @Published var acknowledgedCloudNotice: [String] { didSet { defaults.set(acknowledgedCloudNotice, forKey: "acknowledgedCloudNotice") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        transcriptionProvider = TranscriptionProviderChoice(rawValue: defaults.string(forKey: "transcriptionProvider") ?? "") ?? .openAI
        openAITranscriptionModel = defaults.string(forKey: "openAITranscriptionModel") ?? "gpt-transcribe"
        generationProvider = GenerationProviderChoice(rawValue: defaults.string(forKey: "generationProvider") ?? "") ?? .anthropic
        anthropicModel = defaults.string(forKey: "anthropicModel") ?? AnthropicProvider.defaultModel
        openAITextModel = defaults.string(forKey: "openAITextModel") ?? ""
        writingEffort = GenerationEffort(rawValue: defaults.string(forKey: "writingEffort") ?? "") ?? .high
        verifyWithModel = defaults.object(forKey: "verifyWithModel") as? Bool ?? true
        autoRepair = defaults.object(forKey: "autoRepair") as? Bool ?? true
        useServerSideFallback = defaults.object(forKey: "useServerSideFallback") as? Bool ?? true
        customSystemPrompt = defaults.string(forKey: "customSystemPrompt") ?? ""
        transcriptionChunkMinutes = defaults.object(forKey: "transcriptionChunkMinutes") as? Double ?? 6
        defaultMode = SbobinaturaMode(rawValue: defaults.string(forKey: "defaultMode") ?? "") ?? .integrale
        backendURL = defaults.string(forKey: "backendURL") ?? ""
        recordingProfile = RecordingProfileID(rawValue: defaults.string(forKey: "recordingProfile") ?? "") ?? .classroom
        recordingBitrate = defaults.object(forKey: "recordingBitrate") as? Int ?? 64_000
        segmentMinutes = defaults.object(forKey: "segmentMinutes") as? Double ?? 3
        experimentalGainDB = defaults.object(forKey: "experimentalGainDB") as? Double ?? 6
        autoResumeAfterInterruption = defaults.object(forKey: "autoResumeAfterInterruption") as? Bool ?? true
        notifyOnInterruption = defaults.object(forKey: "notifyOnInterruption") as? Bool ?? true
        preferredInputUID = defaults.string(forKey: "preferredInputUID") ?? ""
        preferredDataSourceID = defaults.object(forKey: "preferredDataSourceID") as? Int ?? -1
        fingerDrawing = defaults.object(forKey: "fingerDrawing") as? Bool ?? false
        acknowledgedCloudNotice = defaults.stringArray(forKey: "acknowledgedCloudNotice") ?? []
    }

    private func save(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
    }

    var currentGenerationModel: String {
        generationProvider == .anthropic ? anthropicModel : openAITextModel
    }

    var currentTranscriptionModel: String {
        switch transcriptionProvider {
        case .openAI: return openAITranscriptionModel
        case .appleOnDevice: return "on-device"
        case .backend: return "backend"
        }
    }
}
