import CoreML
import Foundation
import WhisperKit

/// Esecuzione dei modelli Whisper con WhisperKit (CoreML). Come per
/// FluidAudio, resta in memoria un solo modello alla volta.
actor WhisperKitEngine {
    static let shared = WhisperKitEngine()

    private static let repository = "argmaxinc/whisperkit-coreml"
    private var loadedVariant: String?
    private var pipeline: WhisperKit?

    /// Radice dei download (modelli e tokenizer) in Application Support.
    nonisolated static var downloadBase: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("OnDeviceModels/WhisperKit", isDirectory: true)
    }

    nonisolated static func modelFolder(variant: String) -> URL {
        downloadBase.appendingPathComponent("models/\(repository)/\(variant)", isDirectory: true)
    }

    nonisolated static func isDownloaded(variant: String) -> Bool {
        let folder = modelFolder(variant: variant)
        let required = ["MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc"]
        return required.allSatisfy { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
    }

    /// Scarica il modello e lo carica una volta: il primo caricamento
    /// scarica anche il tokenizer e specializza i modelli CoreML per questo
    /// iPad, così le trascrizioni successive funzionano senza rete.
    func download(variant: String, progress: @escaping OnDeviceProgressHandler) async throws -> URL {
        let folder = try await WhisperKit.download(
            variant: variant,
            downloadBase: Self.downloadBase,
            from: Self.repository,
            progressCallback: { update in
                progress(OnDeviceProgress(fraction: update.fractionCompleted, phase: .downloading))
            }
        )
        progress(OnDeviceProgress(fraction: 0, phase: .preparing))
        try await load(variant: variant)
        progress(OnDeviceProgress(fraction: 1, phase: .preparing))
        return folder
    }

    private func load(variant: String) async throws -> WhisperKit {
        if loadedVariant == variant, let pipeline { return pipeline }
        unload()
        guard Self.isDownloaded(variant: variant) else { throw OnDeviceEngineError.notInstalled(variant) }
        let config = WhisperKitConfig(
            model: variant,
            downloadBase: Self.downloadBase,
            modelRepo: Self.repository,
            modelFolder: Self.modelFolder(variant: variant).path,
            tokenizerFolder: Self.downloadBase,
            // Niente GPU: iPadOS non la concede alle app in background, e la
            // trascrizione deve poter proseguire a schermo bloccato.
            computeOptions: ModelComputeOptions(melCompute: .cpuOnly, audioEncoderCompute: .cpuAndNeuralEngine, textDecoderCompute: .cpuAndNeuralEngine),
            verbose: false,
            prewarm: false,
            load: true,
            download: false
        )
        let loaded = try await WhisperKit(config)
        pipeline = loaded
        loadedVariant = variant
        return loaded
    }

    func unload() {
        pipeline = nil
        loadedVariant = nil
    }

    func transcribe(url: URL, variant: String, language: String?, keywords: [String]) async throws -> EngineOutput {
        let whisper = try await load(variant: variant)
        var promptTokens: [Int]?
        if !keywords.isEmpty, let tokenizer = whisper.tokenizer {
            // Il glossario come prompt iniziale aiuta Whisper con i termini
            // tecnici; si tengono solo token testuali e al massimo 200.
            let prompt = " " + keywords.prefix(60).joined(separator: ", ")
            let tokens = tokenizer.encode(text: prompt).filter { $0 < tokenizer.specialTokens.specialTokenBegin }
            promptTokens = Array(tokens.suffix(200))
        }
        let options = DecodingOptions(
            task: .transcribe,
            language: language,
            temperature: 0,
            usePrefillPrompt: true,
            detectLanguage: language == nil,
            skipSpecialTokens: true,
            withoutTimestamps: false,
            promptTokens: promptTokens,
            chunkingStrategy: .vad
        )
        let results = try await whisper.transcribe(audioPath: url.path, decodeOptions: options)
        let segments = results.flatMap(\.segments).compactMap { segment -> EngineSegment? in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return EngineSegment(start: TimeInterval(segment.start), end: TimeInterval(segment.end), text: text)
        }
        let text = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return EngineOutput(text: text, tokens: nil, segments: segments, detectedLanguage: results.first?.language)
    }
}
