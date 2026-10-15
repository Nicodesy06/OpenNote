import Foundation

/// Rimuove il testo duplicato causato dalla sovrapposizione fra chunk
/// consecutivi, confrontando la coda del chunk precedente con l'inizio del
/// successivo a livello di parole normalizzate.
public enum OverlapDeduplicator {
    public struct Result: Equatable, Sendable {
        /// Testo del chunk precedente, eventualmente privato di parole finali
        /// troncate dal taglio.
        public var previous: String
        /// Testo del chunk corrente senza la parte duplicata.
        public var current: String
        /// Numero di parole riconosciute come duplicate (0 = nessuna).
        public var matchedWords: Int
        public var resolved: Bool
    }

    /// - Parameters:
    ///   - maxWords: numero massimo di parole da esaminare (deriva dalla
    ///     durata della sovrapposizione).
    ///   - minMatch: lunghezza minima della corrispondenza per considerarla
    ///     affidabile.
    ///   - maxEdgeSkip: parole ai bordi che possono essere troncate/errate.
    public static func trim(previous: String, current: String, maxWords: Int = 30, minMatch: Int = 3, maxEdgeSkip: Int = 2) -> Result {
        let previousWords = TextTokenizer.whitespaceWords(previous)
        let currentWords = TextTokenizer.whitespaceWords(current)
        let previousNorm = previousWords.map(TextTokenizer.normalize)
        let currentNorm = currentWords.map(TextTokenizer.normalize)

        // Indici delle parole con token non vuoto.
        let previousIdx = previousNorm.indices.filter { !previousNorm[$0].isEmpty }
        let currentIdx = currentNorm.indices.filter { !currentNorm[$0].isEmpty }
        let previousTail = Array(previousIdx.suffix(maxWords))
        let currentHead = Array(currentIdx.prefix(maxWords))

        guard previousTail.count >= minMatch, currentHead.count >= minMatch else {
            return Result(previous: previous, current: current, matchedWords: 0, resolved: false)
        }

        var best: (k: Int, skipPrevious: Int, skipCurrent: Int, mismatches: Int)?
        for skipPrevious in 0...min(maxEdgeSkip, previousTail.count - minMatch) {
            for skipCurrent in 0...min(maxEdgeSkip, currentHead.count - minMatch) {
                let available = min(previousTail.count - skipPrevious, currentHead.count - skipCurrent)
                guard available >= minMatch else { continue }
                for k in stride(from: available, through: minMatch, by: -1) {
                    // Suffisso di lunghezza k (che termina skipPrevious parole
                    // prima della fine) contro prefisso di lunghezza k (che
                    // inizia dopo skipCurrent parole).
                    let previousStart = previousTail.count - skipPrevious - k
                    var mismatches = 0
                    let tolerance = k / 6
                    var ok = true
                    for offset in 0..<k {
                        let a = previousNorm[previousTail[previousStart + offset]]
                        let b = currentNorm[currentHead[skipCurrent + offset]]
                        if a != b {
                            mismatches += 1
                            if mismatches > tolerance { ok = false; break }
                        }
                    }
                    // Il primo e l'ultimo token devono coincidere, per evitare
                    // allineamenti spuri.
                    if ok, previousNorm[previousTail[previousStart]] == currentNorm[currentHead[skipCurrent]],
                       previousNorm[previousTail[previousStart + k - 1]] == currentNorm[currentHead[skipCurrent + k - 1]] {
                        let score = k * 4 - mismatches * 3 - skipPrevious - skipCurrent
                        let bestScore = best.map { $0.k * 4 - $0.mismatches * 3 - $0.skipPrevious - $0.skipCurrent } ?? Int.min
                        if score > bestScore {
                            best = (k, skipPrevious, skipCurrent, mismatches)
                        }
                        break
                    }
                }
            }
        }

        guard let match = best else {
            return Result(previous: previous, current: current, matchedWords: 0, resolved: false)
        }

        // Rimuove dal corrente tutte le parole fino alla fine della
        // corrispondenza (incluse le parole di bordo saltate).
        let lastCurrentIndex = currentHead[match.skipCurrent + match.k - 1]
        let trimmedCurrent = currentWords.dropFirst(lastCurrentIndex + 1).joined(separator: " ")

        // Rimuove dal precedente le parole finali saltate (troncate dal taglio).
        var trimmedPrevious = previous
        if match.skipPrevious > 0 {
            let firstDropped = previousTail[previousTail.count - match.skipPrevious]
            trimmedPrevious = previousWords.prefix(firstDropped).joined(separator: " ")
        }
        return Result(previous: trimmedPrevious, current: trimmedCurrent, matchedWords: match.k, resolved: true)
    }
}
