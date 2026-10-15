import AVFoundation
import Speech
import QuadernoCore

/// Trascrizione sul dispositivo con i framework Apple.
///
/// - iPadOS 26+: `SpeechAnalyzer` / `SpeechTranscriber` (modello per audio
///   lungo e voci distanti), con download del modello linguistico se serve.
/// - iPadOS 17–25: `SFSpeechRecognizer` con riconoscimento solo sul
///   dispositivo, su chunk brevi.
///
/// Limiti: nessuna diarizzazione, accuratezza generalmente inferiore ai
/// modelli cloud su lessico tecnico, uso intenso di CPU/Neural Engine
/// (consumo di batteria). Per questo è un'opzione esplicita e non si
/// attiva mai automaticamente.
struct AppleSpeechTranscriptionProvider: TranscriptionProvider {
    let id = "apple-ondevice"
    let displayName = "Apple (sul dispositivo)"

    var model: String {
        if #available(iOS 26.0, *) { return "SpeechAnalyzer" }
        return "SFSpeechRecognizer"
    }

    var capabilities: TranscriptionCapabilities {
        let maxChunk: TimeInterval
        if #available(iOS 26.0, *) { maxChunk = 30 * 60 } else { maxChunk = 4 * 60 }
        return TranscriptionCapabilities(maxUploadBytes: nil, maxChunkDuration: maxChunk, returnsSegmentTimestamps: true, supportsDiarization: false, supportsPrompt: false, supportsKeywords: true, maxKeywords: 100, requiresNetwork: false, supportedFileExtensions: ["m4a", "wav", "mp3", "aiff", "caf"])
    }

    func estimateCost(durationSeconds: TimeInterval) -> CostEstimate? {
        CostEstimate(amountUSD: 0, basis: "Elaborazione sul dispositivo: nessun costo API, maggiore consumo di batteria.")
    }

    enum AppleSpeechError: Error, LocalizedError {
        case notAuthorized
        case unsupportedLocale(String)
        case onDeviceUnavailable
        case recognitionFailed(String)

        var errorDescription: String? {
            switch self {
            case .notAuthorized: return "Autorizza il riconoscimento vocale in Impostazioni › Privacy."
            case .unsupportedLocale(let locale): return "La lingua \(locale) non è disponibile per la trascrizione sul dispositivo."
            case .onDeviceUnavailable: return "Il riconoscimento sul dispositivo non è disponibile per questa lingua su questo iPad."
            case .recognitionFailed(let message): return "Trascrizione locale non riuscita: \(message)"
            }
        }
    }

    func transcribe(chunk: AudioChunkFile, options: TranscriptionOptions) async throws -> ChunkTranscription {
        let localeIdentifier = (options.languages.first ?? "it") == "it" ? "it-IT" : (options.languages.first ?? "it")
        let locale = Locale(identifier: localeIdentifier)
        if #available(iOS 26.0, *) {
            let segments = try await transcribeWithAnalyzer(url: chunk.url, locale: locale)
            return ChunkTranscription(text: segments.map(\.text).joined(separator: " "), segments: segments, detectedLanguages: [localeIdentifier], model: model, providerID: id)
        }
        let segments = try await transcribeWithRecognizer(url: chunk.url, locale: locale, contextualStrings: options.keywords)
        return ChunkTranscription(text: segments.map(\.text).joined(separator: " "), segments: segments, detectedLanguages: [localeIdentifier], model: model, providerID: id)
    }

    // MARK: - iPadOS 26+

    @available(iOS 26.0, *)
    private func transcribeWithAnalyzer(url: URL, locale: Locale) async throws -> [TimedText] {
        let supportedLocales = await SpeechTranscriber.supportedLocales
        guard let supported = supportedLocales.first(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) })
                ?? supportedLocales.first(where: { $0.language.languageCode == locale.language.languageCode }) else {
            throw AppleSpeechError.unsupportedLocale(locale.identifier)
        }
        let transcriber = SpeechTranscriber(locale: supported, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let file = try AVAudioFile(forReading: url)
        async let collected: [TimedText] = {
            var output: [TimedText] = []
            for try await result in transcriber.results {
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                output.append(TimedText(start: result.range.start.seconds, end: result.range.end.seconds, text: text))
            }
            return output
        }()
        if let lastSample = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: lastSample)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await collected
    }

    // MARK: - iPadOS 17–25

    private func transcribeWithRecognizer(url: URL, locale: Locale, contextualStrings: [String]) async throws -> [TimedText] {
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard status == .authorized else { throw AppleSpeechError.notAuthorized }
        guard let recognizer = SFSpeechRecognizer(locale: locale) else { throw AppleSpeechError.unsupportedLocale(locale.identifier) }
        guard recognizer.supportsOnDeviceRecognition else { throw AppleSpeechError.onDeviceUnavailable }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        request.taskHint = .dictation
        request.contextualStrings = Array(contextualStrings.prefix(100))

        let transcription: SFTranscription = try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            recognizer.recognitionTask(with: request) { result, error in
                guard !resumed else { return }
                if let error {
                    resumed = true
                    continuation.resume(throwing: AppleSpeechError.recognitionFailed(error.localizedDescription))
                } else if let result, result.isFinal {
                    resumed = true
                    continuation.resume(returning: result.bestTranscription)
                }
            }
        }
        return Self.group(transcription.segments)
    }

    /// Raggruppa le parole in segmenti di circa 12 secondi o fino a una pausa.
    static func group(_ words: [SFTranscriptionSegment]) -> [TimedText] {
        var output: [TimedText] = []
        var current: [SFTranscriptionSegment] = []
        for word in words {
            if let last = current.last {
                let gap = word.timestamp - (last.timestamp + last.duration)
                let span = word.timestamp + word.duration - (current.first?.timestamp ?? 0)
                if gap > 1.2 || span > 12 {
                    output.append(makeSegment(current))
                    current = []
                }
            }
            current.append(word)
        }
        if !current.isEmpty { output.append(makeSegment(current)) }
        return output
    }

    private static func makeSegment(_ words: [SFTranscriptionSegment]) -> TimedText {
        let start = words.first?.timestamp ?? 0
        let end = (words.last.map { $0.timestamp + $0.duration }) ?? start
        return TimedText(start: start, end: end, text: words.map(\.substring).joined(separator: " "))
    }
}
