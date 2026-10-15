import Foundation

// Tipi neutri scambiati tra i motori e il provider. I file dei motori
// importano solo il proprio framework (FluidAudio o WhisperKit) e non
// QuadernoCore, per evitare ambiguità tra nomi omonimi dei moduli.

/// Token o parola con tempi relativi all'inizio del file trascritto.
struct EngineToken: Sendable {
    var text: String
    var start: TimeInterval
    var end: TimeInterval
}

/// Segmento di frase con tempi relativi all'inizio del file.
struct EngineSegment: Sendable {
    var start: TimeInterval
    var end: TimeInterval
    var text: String
}

/// Risultato grezzo di un motore.
struct EngineOutput: Sendable {
    var text: String
    /// Token SentencePiece temporizzati (Parakeet).
    var tokens: [EngineToken]?
    /// Segmenti già pronti (Whisper).
    var segments: [EngineSegment]?
    var detectedLanguage: String?
}

/// Avanzamento di un download o della preparazione di un modello.
public struct OnDeviceProgress: Sendable, Equatable {
    public enum Phase: String, Sendable {
        case downloading
        /// Compilazione/specializzazione CoreML per questo iPad.
        case preparing
    }

    public var fraction: Double
    public var phase: Phase

    public init(fraction: Double, phase: Phase) {
        self.fraction = fraction
        self.phase = phase
    }
}

public typealias OnDeviceProgressHandler = @Sendable (OnDeviceProgress) -> Void

enum OnDeviceEngineError: Error, LocalizedError {
    case unknownModel(String)
    case notInstalled(String)
    case emptyResult

    var errorDescription: String? {
        switch self {
        case .unknownModel(let id): return "Modello sul dispositivo sconosciuto: \(id)."
        case .notInstalled(let name): return "Il modello \(name) non è scaricato. Scaricalo in Impostazioni › Modelli di trascrizione."
        case .emptyResult: return "Il modello non ha restituito testo per questo tratto di audio."
        }
    }
}
