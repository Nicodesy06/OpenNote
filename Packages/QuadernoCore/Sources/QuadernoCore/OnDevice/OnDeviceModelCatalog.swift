import Foundation

/// Motore che esegue un modello sul dispositivo.
public enum OnDeviceEngine: String, Codable, Sendable, CaseIterable {
    /// FluidAudio (CoreML sul Neural Engine): Parakeet, Canary, SenseVoice.
    case fluidAudio
    /// WhisperKit di Argmax (CoreML): modelli Whisper.
    case whisperKit
    /// Framework Speech di Apple (SpeechAnalyzer / SFSpeechRecognizer).
    case appleSpeech
}

/// Precisione dei riferimenti temporali prodotti dal modello.
public enum OnDeviceTimestamps: String, Codable, Sendable {
    /// Tempi per parola o per segmento.
    case precise
    /// Solo testo: tempi interpolati dall'app.
    case none
}

/// Descrizione di un modello di trascrizione eseguibile sul dispositivo.
public struct OnDeviceModel: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var displayName: String
    public var engine: OnDeviceEngine
    /// Identificatore interno al motore (versione Parakeet, variante Whisper…).
    public var engineModel: String
    public var summary: String
    /// Codici ISO 639-1 supportati; vuoto = moltissime lingue / gestito dal sistema.
    public var languages: [String]
    public var languageSummary: String
    public var approximateSizeMB: Int
    /// Versione minima di iPadOS.
    public var minimumOSMajor: Int
    /// RAM minima consigliata (GB) per un'esecuzione fluida.
    public var minimumRAMGB: Int
    /// Punteggio indicativo di accuratezza sull'italiano (0–100), usato solo per
    /// ordinare i suggerimenti. Deriva da benchmark pubblici (FLEURS) e non va
    /// presentato come misura assoluta.
    public var italianQuality: Int
    /// Durata massima (s) di audio per singola chiamata, se il motore la limita.
    public var maxChunkSeconds: TimeInterval?
    public var timestamps: OnDeviceTimestamps
    public var requiresDownload: Bool

    public init(id: String, displayName: String, engine: OnDeviceEngine, engineModel: String, summary: String, languages: [String], languageSummary: String, approximateSizeMB: Int, minimumOSMajor: Int, minimumRAMGB: Int, italianQuality: Int, maxChunkSeconds: TimeInterval?, timestamps: OnDeviceTimestamps, requiresDownload: Bool) {
        self.id = id
        self.displayName = displayName
        self.engine = engine
        self.engineModel = engineModel
        self.summary = summary
        self.languages = languages
        self.languageSummary = languageSummary
        self.approximateSizeMB = approximateSizeMB
        self.minimumOSMajor = minimumOSMajor
        self.minimumRAMGB = minimumRAMGB
        self.italianQuality = italianQuality
        self.maxChunkSeconds = maxChunkSeconds
        self.timestamps = timestamps
        self.requiresDownload = requiresDownload
    }

    /// `true` se il modello supporta tutte le lingue richieste (lista vuota
    /// del modello = copertura ampia o gestita dal sistema).
    public func supports(languages requested: [String]) -> Bool {
        guard !languages.isEmpty else { return true }
        let wanted = requested.isEmpty ? ["it"] : requested
        return wanted.allSatisfy { languages.contains($0.lowercased()) }
    }
}

/// Catalogo dei modelli sul dispositivo (ottobre 2026). I nomi dei modelli e
/// delle varianti corrispondono ai repository CoreML pubblicati da
/// FluidInference e Argmax su Hugging Face.
public enum OnDeviceModelCatalog {
    static let european25 = ["bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de", "el", "hu", "it", "lv", "lt", "mt", "pl", "pt", "ro", "sk", "sl", "es", "sv", "ru", "uk"]

    public static let all: [OnDeviceModel] = [
        OnDeviceModel(
            id: "parakeet-ultra", displayName: "Parakeet Ultra", engine: .fluidAudio, engineModel: "ultra",
            summary: "Evoluzione di Parakeet V3: stessa velocità, errori ridotti. Consigliato per l'italiano.",
            languages: european25, languageSummary: "25 lingue europee",
            approximateSizeMB: 630, minimumOSMajor: 17, minimumRAMGB: 4, italianQuality: 92,
            maxChunkSeconds: nil, timestamps: .precise, requiresDownload: true),
        OnDeviceModel(
            id: "canary-1b-v2", displayName: "Canary 1B v2", engine: .fluidAudio, engineModel: "canary-int4",
            summary: "Modello NVIDIA più grande (1 miliardo di parametri): molto accurato, più lento di Parakeet.",
            languages: european25, languageSummary: "25 lingue europee",
            approximateSizeMB: 640, minimumOSMajor: 17, minimumRAMGB: 6, italianQuality: 90,
            maxChunkSeconds: nil, timestamps: .none, requiresDownload: true),
        OnDeviceModel(
            id: "parakeet-v3", displayName: "Parakeet V3", engine: .fluidAudio, engineModel: "v3",
            summary: "Il modello usato da Whisper Notes: ottima precisione, molto veloce sul Neural Engine.",
            languages: european25, languageSummary: "25 lingue europee",
            approximateSizeMB: 465, minimumOSMajor: 17, minimumRAMGB: 4, italianQuality: 88,
            maxChunkSeconds: nil, timestamps: .precise, requiresDownload: true),
        OnDeviceModel(
            id: "whisper-large-v3", displayName: "Whisper Large v3", engine: .whisperKit, engineModel: "openai_whisper-large-v3-v20240930_626MB",
            summary: "Il Whisper più accurato (versione compressa per iPad): tra i migliori sull'italiano nei benchmark pubblici, ma più lento e più energivoro.",
            languages: [], languageSummary: "99 lingue",
            approximateSizeMB: 626, minimumOSMajor: 17, minimumRAMGB: 8, italianQuality: 91,
            maxChunkSeconds: nil, timestamps: .precise, requiresDownload: true),
        OnDeviceModel(
            id: "whisper-large-v3-turbo", displayName: "Whisper Large v3 Turbo", engine: .whisperKit, engineModel: "openai_whisper-large-v3-v20240930_turbo_632MB",
            summary: "Whisper di OpenAI ottimizzato per Apple Silicon: buona precisione in 99 lingue.",
            languages: [], languageSummary: "99 lingue",
            approximateSizeMB: 632, minimumOSMajor: 17, minimumRAMGB: 6, italianQuality: 87,
            maxChunkSeconds: nil, timestamps: .precise, requiresDownload: true),
        OnDeviceModel(
            id: "parakeet-redux", displayName: "Parakeet Redux", engine: .fluidAudio, engineModel: "redux",
            summary: "Versione compatta di Parakeet V3: un terzo dello spazio, precisione di poco inferiore. Prima compilazione lenta.",
            languages: european25, languageSummary: "25 lingue europee",
            approximateSizeMB: 220, minimumOSMajor: 18, minimumRAMGB: 3, italianQuality: 84,
            maxChunkSeconds: nil, timestamps: .precise, requiresDownload: true),
        OnDeviceModel(
            id: "whisper-small", displayName: "Whisper Small", engine: .whisperKit, engineModel: "openai_whisper-small_216MB",
            summary: "Whisper leggero per iPad meno recenti: veloce, precisione discreta.",
            languages: [], languageSummary: "99 lingue",
            approximateSizeMB: 216, minimumOSMajor: 17, minimumRAMGB: 3, italianQuality: 70,
            maxChunkSeconds: nil, timestamps: .precise, requiresDownload: true),
        OnDeviceModel(
            id: "sensevoice-small", displayName: "SenseVoice", engine: .fluidAudio, engineModel: "sensevoice-int8",
            summary: "Ottimizzato per cinese, cantonese, giapponese e coreano. Molto veloce.",
            languages: ["zh", "yue", "ja", "ko", "en"], languageSummary: "Cinese, cantonese, giapponese, coreano",
            approximateSizeMB: 450, minimumOSMajor: 17, minimumRAMGB: 3, italianQuality: 0,
            maxChunkSeconds: 100, timestamps: .none, requiresDownload: true),
        OnDeviceModel(
            id: "apple-speech", displayName: "Apple Speech", engine: .appleSpeech, engineModel: "system",
            summary: "Riconoscimento di sistema: nessun download nell'app, la lingua è gestita da iPadOS. Su iPadOS 26 usa SpeechAnalyzer.",
            languages: [], languageSummary: "Lingue gestite dal sistema",
            approximateSizeMB: 0, minimumOSMajor: 17, minimumRAMGB: 2, italianQuality: 85,
            maxChunkSeconds: nil, timestamps: .precise, requiresDownload: false)
    ]

    public static func model(id: String) -> OnDeviceModel? {
        all.first { $0.id == id }
    }

    /// Modelli compatibili con dispositivo e lingue, dal più accurato per
    /// l'italiano (o per le lingue richieste).
    public static func compatible(osMajor: Int, ramGB: Int, languages: [String]) -> [OnDeviceModel] {
        all.filter { $0.minimumOSMajor <= osMajor && $0.minimumRAMGB <= ramGB && $0.supports(languages: languages) }
            .sorted { lhs, rhs in
                if lhs.italianQuality != rhs.italianQuality { return lhs.italianQuality > rhs.italianQuality }
                return lhs.approximateSizeMB < rhs.approximateSizeMB
            }
    }

    /// Modello consigliato. Su iPadOS 26 con poca memoria si preferisce Apple
    /// Speech (nessun download); altrimenti il modello più accurato compatibile.
    public static func recommended(osMajor: Int, ramGB: Int, languages: [String]) -> OnDeviceModel? {
        let candidates = compatible(osMajor: osMajor, ramGB: ramGB, languages: languages)
        if ramGB < 4, osMajor >= 26, let apple = candidates.first(where: { $0.engine == .appleSpeech }) {
            return apple
        }
        return candidates.first
    }
}

/// Raggruppa parole temporizzate (es. token di Parakeet o Whisper) in
/// segmenti di frase, spezzando su punteggiatura finale, pause o durata.
public enum TimedWordGrouper {
    public struct Word: Sendable, Equatable {
        public var text: String
        public var start: TimeInterval
        public var end: TimeInterval

        public init(text: String, start: TimeInterval, end: TimeInterval) {
            self.text = text
            self.start = start
            self.end = end
        }
    }

    /// I token SentencePiece iniziano con "▁" quando aprono una parola.
    public static func wordsFromSentencePiece(_ tokens: [Word]) -> [Word] {
        var words: [Word] = []
        for token in tokens {
            let startsWord = token.text.hasPrefix("▁") || token.text.hasPrefix(" ")
            let clean = token.text.replacingOccurrences(of: "▁", with: " ")
            if startsWord || words.isEmpty {
                let trimmed = clean.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }
                words.append(Word(text: trimmed, start: token.start, end: token.end))
            } else {
                words[words.count - 1].text += clean
                words[words.count - 1].end = token.end
            }
        }
        return words
    }

    public static func segments(from words: [Word], maxDuration: TimeInterval = 15, pause: TimeInterval = 1.0) -> [TimedText] {
        var output: [TimedText] = []
        var current: [Word] = []
        func flush() {
            guard let first = current.first, let last = current.last else { return }
            output.append(TimedText(start: first.start, end: last.end, text: current.map(\.text).joined(separator: " ")))
            current.removeAll()
        }
        for word in words {
            if let last = current.last {
                let gap = word.start - last.end
                let span = word.end - (current.first?.start ?? word.start)
                if gap > pause || span > maxDuration { flush() }
            }
            current.append(word)
            if let character = word.text.last, ".?!…".contains(character), (current.last!.end - current.first!.start) > 3 {
                flush()
            }
        }
        flush()
        return output
    }
}
