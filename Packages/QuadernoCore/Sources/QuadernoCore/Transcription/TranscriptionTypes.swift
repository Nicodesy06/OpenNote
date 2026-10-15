import Foundation

/// Precisione dei riferimenti temporali di un segmento.
public enum TimingPrecision: String, Codable, Sendable {
    /// Timestamp restituiti dal provider (es. diarizzazione, whisper-1).
    case exact
    /// Timestamp interpolati all'interno del chunk: utili per navigare
    /// l'audio, ma approssimativi.
    case interpolated
    /// Solo l'intervallo dell'intero chunk.
    case chunk
}

/// Segmento temporizzato restituito da un provider, con tempi relativi al
/// chunk inviato.
public struct TimedText: Codable, Sendable, Equatable {
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String
    public var speaker: String?

    public init(start: TimeInterval, end: TimeInterval, text: String, speaker: String? = nil) {
        self.start = start
        self.end = end
        self.text = text
        self.speaker = speaker
    }
}

/// Risultato della trascrizione di un singolo chunk.
public struct ChunkTranscription: Codable, Sendable, Equatable {
    public var text: String
    /// Segmenti con tempi relativi all'inizio del chunk, se disponibili.
    public var segments: [TimedText]?
    public var detectedLanguages: [String]
    public var model: String
    public var providerID: String

    public init(text: String, segments: [TimedText]? = nil, detectedLanguages: [String] = [], model: String, providerID: String) {
        self.text = text
        self.segments = segments
        self.detectedLanguages = detectedLanguages
        self.model = model
        self.providerID = providerID
    }
}

/// Segmento finale della trascrizione, con tempi assoluti.
public struct TranscriptSegmentDTO: Codable, Sendable, Equatable, Identifiable {
    public var id: Int { index }
    public var index: Int
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String
    public var speaker: String?
    public var chunkIndex: Int
    public var precision: TimingPrecision

    public init(index: Int, start: TimeInterval, end: TimeInterval, text: String, speaker: String? = nil, chunkIndex: Int, precision: TimingPrecision) {
        self.index = index
        self.start = start
        self.end = end
        self.text = text
        self.speaker = speaker
        self.chunkIndex = chunkIndex
        self.precision = precision
    }
}

/// Opzioni di trascrizione comuni a tutti i provider.
public struct TranscriptionOptions: Codable, Sendable, Equatable {
    /// Codici ISO 639-1; vuoto = rilevamento automatico.
    public var languages: [String]
    /// Contesto libero (materia, argomento della lezione).
    public var prompt: String?
    /// Termini del glossario della materia.
    public var keywords: [String]
    public var diarize: Bool
    public var knownSpeakerNames: [String]

    public init(languages: [String] = ["it"], prompt: String? = nil, keywords: [String] = [], diarize: Bool = false, knownSpeakerNames: [String] = []) {
        self.languages = languages
        self.prompt = prompt
        self.keywords = keywords
        self.diarize = diarize
        self.knownSpeakerNames = knownSpeakerNames
    }
}

/// Capacità dichiarate da un provider; guidano la pianificazione dei chunk.
public struct TranscriptionCapabilities: Codable, Sendable, Equatable {
    public var maxUploadBytes: Int?
    public var maxChunkDuration: TimeInterval?
    public var returnsSegmentTimestamps: Bool
    public var supportsDiarization: Bool
    public var supportsPrompt: Bool
    public var supportsKeywords: Bool
    public var maxKeywords: Int
    public var requiresNetwork: Bool
    public var supportedFileExtensions: [String]

    public init(maxUploadBytes: Int?, maxChunkDuration: TimeInterval?, returnsSegmentTimestamps: Bool, supportsDiarization: Bool, supportsPrompt: Bool, supportsKeywords: Bool, maxKeywords: Int = 0, requiresNetwork: Bool, supportedFileExtensions: [String]) {
        self.maxUploadBytes = maxUploadBytes
        self.maxChunkDuration = maxChunkDuration
        self.returnsSegmentTimestamps = returnsSegmentTimestamps
        self.supportsDiarization = supportsDiarization
        self.supportsPrompt = supportsPrompt
        self.supportsKeywords = supportsKeywords
        self.maxKeywords = maxKeywords
        self.requiresNetwork = requiresNetwork
        self.supportedFileExtensions = supportedFileExtensions
    }
}

/// Stima dei costi. È sempre una stima: il prezzo reale dipende dal listino
/// corrente del provider.
public struct CostEstimate: Codable, Sendable, Equatable {
    public var amountUSD: Double
    public var basis: String

    public init(amountUSD: Double, basis: String) {
        self.amountUSD = amountUSD
        self.basis = basis
    }
}

/// File audio di un chunk già estratto, pronto per l'invio.
public struct AudioChunkFile: Sendable, Equatable {
    public var spec: ChunkSpec
    public var url: URL
    public var byteSize: Int
    public var mimeType: String

    public init(spec: ChunkSpec, url: URL, byteSize: Int, mimeType: String = "audio/mp4") {
        self.spec = spec
        self.url = url
        self.byteSize = byteSize
        self.mimeType = mimeType
    }
}

/// Provider di speech-to-text sostituibile.
public protocol TranscriptionProvider: Sendable {
    var id: String { get }
    var displayName: String { get }
    var model: String { get }
    var capabilities: TranscriptionCapabilities { get }
    /// Trascrive un singolo chunk. La suddivisione di file lunghi è compito di
    /// `TranscriptionPipeline`, identica per audio registrati e importati.
    func transcribe(chunk: AudioChunkFile, options: TranscriptionOptions) async throws -> ChunkTranscription
    func estimateCost(durationSeconds: TimeInterval) -> CostEstimate?
}
