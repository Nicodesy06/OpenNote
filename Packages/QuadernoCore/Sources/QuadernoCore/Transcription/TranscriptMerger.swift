import Foundation

/// Report del merge, mostrato all'utente come diagnostica della trascrizione.
public struct TranscriptMergeReport: Codable, Sendable, Equatable {
    public var chunkCount: Int
    public var coverageGaps: [ClosedRange<TimeInterval>]
    /// Chunk in cui la sovrapposizione non è stata riconosciuta: possibile
    /// testo duplicato al confine.
    public var unresolvedOverlapChunks: [Int]
    /// Chunk che non contengono testo (silenzio o errore del provider).
    public var emptyChunks: [Int]
    /// Frasi rimosse perché tipiche allucinazioni su audio vuoto.
    public var removedSuspectPhrases: [String]
    public var precision: TimingPrecision

    public init(chunkCount: Int, coverageGaps: [ClosedRange<TimeInterval>], unresolvedOverlapChunks: [Int], emptyChunks: [Int], removedSuspectPhrases: [String], precision: TimingPrecision) {
        self.chunkCount = chunkCount
        self.coverageGaps = coverageGaps
        self.unresolvedOverlapChunks = unresolvedOverlapChunks
        self.emptyChunks = emptyChunks
        self.removedSuspectPhrases = removedSuspectPhrases
        self.precision = precision
    }

    public var isComplete: Bool { coverageGaps.isEmpty }
}

public struct MergedTranscript: Codable, Sendable, Equatable {
    public var segments: [TranscriptSegmentDTO]
    public var report: TranscriptMergeReport
    public var detectedLanguages: [String]

    public init(segments: [TranscriptSegmentDTO], report: TranscriptMergeReport, detectedLanguages: [String]) {
        self.segments = segments
        self.report = report
        self.detectedLanguages = detectedLanguages
    }

    public var fullText: String {
        segments.map(\.text).joined(separator: " ")
    }
}

public enum TranscriptMergeError: Error, Equatable {
    case missingChunks([Int])
}

/// Ricompone i risultati dei chunk in un'unica trascrizione con tempi
/// assoluti, rimuovendo i duplicati della sovrapposizione.
public enum TranscriptMerger {
    public static func merge(
        results: [(spec: ChunkSpec, transcription: ChunkTranscription)],
        plannedChunks: [ChunkSpec],
        totalDuration: TimeInterval,
        wordsPerSecondEstimate: Double = 3.5
    ) throws -> MergedTranscript {
        let byIndex = Dictionary(results.map { ($0.spec.index, $0) }, uniquingKeysWith: { _, last in last })
        let missing = plannedChunks.map(\.index).filter { byIndex[$0] == nil }
        guard missing.isEmpty else { throw TranscriptMergeError.missingChunks(missing) }

        var pieces: [(chunk: Int, start: TimeInterval, end: TimeInterval, text: String, speaker: String?, precision: TimingPrecision)] = []
        var unresolved: [Int] = []
        var empty: [Int] = []
        var removedPhrases: [String] = []
        var languages: [String] = []
        var anyExact = false
        var anyInterpolated = false

        for spec in plannedChunks.sorted(by: { $0.index < $1.index }) {
            guard let entry = byIndex[spec.index] else { continue }
            let transcription = entry.transcription
            for language in transcription.detectedLanguages where !languages.contains(language) {
                languages.append(language)
            }
            let isLast = spec.index == plannedChunks.map(\.index).max()

            var chunkPieces: [(start: TimeInterval, end: TimeInterval, text: String, speaker: String?, precision: TimingPrecision)] = []
            if let segments = transcription.segments, !segments.isEmpty {
                anyExact = true
                for segment in segments {
                    let absoluteStart = min(spec.extractEnd, spec.extractStart + max(0, segment.start))
                    let absoluteEnd = min(spec.extractEnd, max(absoluteStart, spec.extractStart + segment.end))
                    let midpoint = (absoluteStart + absoluteEnd) / 2
                    let owned = midpoint >= spec.coreStart && (midpoint < spec.coreEnd || (isLast && midpoint <= spec.coreEnd))
                    guard owned else { continue }
                    let filtered = HallucinationFilter.clean(segment.text)
                    removedPhrases.append(contentsOf: filtered.removed)
                    guard !filtered.text.isEmpty else { continue }
                    chunkPieces.append((absoluteStart, absoluteEnd, filtered.text, segment.speaker, .exact))
                }
            } else {
                let filtered = HallucinationFilter.clean(transcription.text)
                removedPhrases.append(contentsOf: filtered.removed)
                if !filtered.text.isEmpty {
                    anyInterpolated = true
                    chunkPieces.append((spec.coreStart, spec.coreEnd, filtered.text, nil, .interpolated))
                }
            }

            if chunkPieces.isEmpty {
                empty.append(spec.index)
                continue
            }

            // Deduplica al confine con il chunk precedente.
            if spec.index > 0, spec.leadingOverlap > 0, let lastIndex = pieces.indices.last {
                let maxWords = Int((spec.leadingOverlap * wordsPerSecondEstimate * 2).rounded(.up)) + 6
                let result = OverlapDeduplicator.trim(previous: pieces[lastIndex].text, current: chunkPieces[0].text, maxWords: maxWords, minMatch: 4)
                if result.resolved {
                    pieces[lastIndex].text = result.previous
                    chunkPieces[0].text = result.current
                    if chunkPieces[0].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        chunkPieces.removeFirst()
                    }
                } else if transcription.segments == nil || transcription.segments?.isEmpty == true {
                    // Con timestamp esatti l'appartenenza per punto medio
                    // gestisce già la sovrapposizione; senza timestamp il
                    // mancato riconoscimento va segnalato.
                    unresolved.append(spec.index)
                }
            }

            for piece in chunkPieces {
                pieces.append((spec.index, piece.start, piece.end, piece.text, piece.speaker, piece.precision))
            }
        }

        // Le porzioni senza timestamp vengono suddivise in gruppi di frasi con
        // tempi interpolati proporzionalmente alla lunghezza del testo.
        var segments: [TranscriptSegmentDTO] = []
        for piece in pieces {
            let text = piece.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if piece.precision == .interpolated {
                let groups = groupSentences(TextTokenizer.sentences(text), targetWords: 45)
                let totalCharacters = max(1, groups.reduce(0) { $0 + $1.count })
                var cursor = piece.start
                let span = piece.end - piece.start
                for group in groups {
                    let share = span * Double(group.count) / Double(totalCharacters)
                    let end = min(piece.end, cursor + share)
                    segments.append(TranscriptSegmentDTO(index: segments.count, start: cursor, end: end, text: group, speaker: nil, chunkIndex: piece.chunk, precision: .interpolated))
                    cursor = end
                }
            } else {
                segments.append(TranscriptSegmentDTO(index: segments.count, start: piece.start, end: piece.end, text: text, speaker: piece.speaker, chunkIndex: piece.chunk, precision: piece.precision))
            }
        }

        let precision: TimingPrecision = anyExact && !anyInterpolated ? .exact : (anyInterpolated ? .interpolated : .chunk)
        let report = TranscriptMergeReport(
            chunkCount: plannedChunks.count,
            coverageGaps: ChunkPlanner.coverageGaps(of: plannedChunks, duration: totalDuration),
            unresolvedOverlapChunks: unresolved,
            emptyChunks: empty,
            removedSuspectPhrases: removedPhrases,
            precision: precision
        )
        return MergedTranscript(segments: segments, report: report, detectedLanguages: languages)
    }

    /// Raggruppa frasi consecutive fino a circa `targetWords` parole.
    static func groupSentences(_ sentences: [String], targetWords: Int) -> [String] {
        var groups: [String] = []
        var current: [String] = []
        var words = 0
        for sentence in sentences {
            current.append(sentence)
            words += TextTokenizer.wordCount(sentence)
            if words >= targetWords {
                groups.append(current.joined(separator: " "))
                current = []
                words = 0
            }
        }
        if !current.isEmpty {
            // Un residuo molto corto si accorpa al gruppo precedente.
            if words < targetWords / 4, let last = groups.popLast() {
                groups.append(last + " " + current.joined(separator: " "))
            } else {
                groups.append(current.joined(separator: " "))
            }
        }
        return groups
    }
}

/// Rimuove frasi che i modelli di trascrizione generano tipicamente su
/// silenzio o rumore (artefatti dei dati di addestramento con sottotitoli).
/// Rimuove soltanto corrispondenze esatte di frasi note e le riporta nel
/// report, per non cancellare mai contenuto reale in modo silenzioso.
public enum HallucinationFilter {
    static let knownPhrases: [String] = [
        "sottotitoli creati dalla comunità amara.org",
        "sottotitoli creati dalla comunita amara.org",
        "sottotitoli a cura di qtss",
        "sottotitoli e revisione a cura di qtss",
        "grazie per la visione",
        "grazie a tutti per la visione",
        "iscriviti al canale",
        "subtitles by the amara.org community",
        "thanks for watching",
        "thank you for watching"
    ]

    public static func clean(_ text: String) -> (text: String, removed: [String]) {
        var sentences = TextTokenizer.sentences(text)
        var removed: [String] = []
        sentences.removeAll { sentence in
            let normalized = sentence.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " .!?…\"'"))
            let match = knownPhrases.contains { normalized == $0 || normalized == $0.replacingOccurrences(of: ".", with: "") }
            if match { removed.append(sentence) }
            return match
        }
        return (sentences.joined(separator: " "), removed)
    }
}
