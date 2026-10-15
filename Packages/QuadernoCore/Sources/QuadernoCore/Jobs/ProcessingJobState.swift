import Foundation

/// Stati espliciti di un lavoro di elaborazione AI. Il completamento non è
/// mai simulato: `completed` si raggiunge solo dopo il salvataggio effettivo
/// dei risultati.
public enum ProcessingJobState: String, Codable, Sendable, CaseIterable {
    case pending
    case preparing
    case uploading
    case transcribing
    case generating
    case verifying
    case completed
    case failed
    case cancelled
    /// In attesa di rete o di riapertura dell'app per proseguire.
    case waiting

    public var isTerminal: Bool {
        self == .completed || self == .cancelled
    }

    public var isActive: Bool {
        [.preparing, .uploading, .transcribing, .generating, .verifying].contains(self)
    }

    public var displayName: String {
        switch self {
        case .pending: return "In coda"
        case .preparing: return "Preparazione"
        case .uploading: return "Caricamento"
        case .transcribing: return "Trascrizione"
        case .generating: return "Generazione"
        case .verifying: return "Verifica"
        case .completed: return "Completato"
        case .failed: return "Non riuscito"
        case .cancelled: return "Annullato"
        case .waiting: return "In attesa"
        }
    }

    /// Transizioni ammesse; impedisce, ad esempio, di riportare a
    /// "completed" un lavoro annullato.
    public func canTransition(to next: ProcessingJobState) -> Bool {
        if self == next { return true }
        switch self {
        case .completed, .cancelled:
            return false
        case .failed, .waiting:
            return [.pending, .preparing, .uploading, .transcribing, .generating, .cancelled, .failed, .waiting].contains(next)
        default:
            return true
        }
    }
}

public enum ProcessingJobKind: String, Codable, Sendable {
    /// Solo trascrizione.
    case transcription
    /// Generazione della sbobinatura da una trascrizione esistente.
    case sbobinatura
    /// Trascrizione seguita da sbobinatura.
    case transcriptionAndSbobinatura
}

/// Stima dei costi complessivi prima dell'invio, mostrata insieme alla
/// richiesta di consenso. I valori sono indicativi.
public enum CostEstimator {
    public struct Estimate: Sendable, Equatable {
        public var transcriptionUSD: Double?
        public var generationUSD: Double?
        public var estimatedInputTokens: Int
        public var estimatedOutputTokens: Int
        public var notes: [String]

        public var totalUSD: Double? {
            switch (transcriptionUSD, generationUSD) {
            case (nil, nil): return nil
            default: return (transcriptionUSD ?? 0) + (generationUSD ?? 0)
            }
        }
    }

    /// Parole stimate al minuto nel parlato di una lezione.
    public static let wordsPerMinute = 140.0
    /// Caratteri per token in italiano (stima prudente).
    public static let charactersPerToken = 3.3

    public static func estimate(durationSeconds: TimeInterval, transcription: TranscriptionProvider?, generation: TextGenerationProvider?, mode: SbobinaturaMode, verify: Bool, transcriptCharacters: Int? = nil) -> Estimate {
        let characters = Double(transcriptCharacters ?? Int(durationSeconds / 60 * wordsPerMinute * 6.2))
        let transcriptTokens = characters / charactersPerToken
        // Scaletta (1×) + scrittura (1× + contesto ~3k per sezione) +
        // verifica (≈2×: trascrizione e testo) + correzioni occasionali.
        let sections = max(1, Double(Int(durationSeconds / 60 / 9)))
        var input = transcriptTokens + (transcriptTokens + sections * 3_000)
        var output = transcriptTokens * mode.expectedOutputRatio + 2_000
        if verify {
            input += transcriptTokens * (1 + mode.expectedOutputRatio) + sections * 500
            output += sections * 800
            // Correzione automatica stimata su un terzo delle sezioni.
            input += (transcriptTokens * 1.9) / 3
            output += (transcriptTokens * mode.expectedOutputRatio) / 3
        }
        var notes: [String] = []
        var generationUSD: Double?
        if let generation {
            if let prices = generation.indicativePricePerMillion {
                generationUSD = input / 1_000_000 * prices.input + output / 1_000_000 * prices.output
            } else {
                notes.append("Prezzo del modello \(generation.model) non noto all'app: consulta il listino del provider.")
            }
        }
        let transcriptionUSD = transcription?.estimateCost(durationSeconds: durationSeconds)?.amountUSD
        notes.append("Stima indicativa basata su listini noti a ottobre 2026; il costo reale è quello addebitato dal provider sul tuo account.")
        return Estimate(transcriptionUSD: transcriptionUSD, generationUSD: generationUSD, estimatedInputTokens: Int(input), estimatedOutputTokens: Int(output), notes: notes)
    }
}
