import Foundation

/// Un chunk pianificato.
///
/// - `coreStart..<coreEnd` è la porzione "di proprietà" del chunk: le porzioni
///   core di tutti i chunk formano una partizione esatta di `0..<durata`, così
///   è verificabile che nessun intervallo venga saltato.
/// - `extractStart..<extractEnd` è l'intervallo effettivamente estratto e
///   inviato: include una piccola sovrapposizione prima del core, per non
///   perdere parole tagliate al confine; i duplicati vengono poi rimossi.
public struct ChunkSpec: Codable, Sendable, Equatable, Hashable {
    public var index: Int
    public var coreStart: TimeInterval
    public var coreEnd: TimeInterval
    public var extractStart: TimeInterval
    public var extractEnd: TimeInterval
    /// `true` se il confine finale cade su una pausa rilevata.
    public var endsOnSilence: Bool

    public init(index: Int, coreStart: TimeInterval, coreEnd: TimeInterval, extractStart: TimeInterval, extractEnd: TimeInterval, endsOnSilence: Bool) {
        self.index = index
        self.coreStart = coreStart
        self.coreEnd = coreEnd
        self.extractStart = extractStart
        self.extractEnd = extractEnd
        self.endsOnSilence = endsOnSilence
    }

    public var extractDuration: TimeInterval { extractEnd - extractStart }
    public var leadingOverlap: TimeInterval { coreStart - extractStart }
}

public struct ChunkPlanConfiguration: Sendable, Equatable {
    /// Durata desiderata del core di ogni chunk. Chunk più brevi danno
    /// riferimenti audio più precisi con provider senza timestamp.
    public var targetDuration: TimeInterval
    /// Durata massima assoluta di un chunk estratto (limite del provider).
    public var maxDuration: TimeInterval
    /// Sovrapposizione prima di ogni chunk successivo al primo.
    public var overlap: TimeInterval
    /// Finestra (±) entro cui cercare una pausa attorno al confine ideale.
    public var silenceSearchWindow: TimeInterval
    /// Un ultimo chunk più corto di questa soglia viene accorpato al precedente
    /// se il limite massimo lo consente.
    public var minimumTailDuration: TimeInterval

    public init(targetDuration: TimeInterval = 6 * 60, maxDuration: TimeInterval = 20 * 60, overlap: TimeInterval = 4, silenceSearchWindow: TimeInterval = 25, minimumTailDuration: TimeInterval = 45) {
        self.targetDuration = targetDuration
        self.maxDuration = maxDuration
        self.overlap = overlap
        self.silenceSearchWindow = silenceSearchWindow
        self.minimumTailDuration = minimumTailDuration
    }

    /// Calcola la durata massima compatibile con un limite in byte, dato il
    /// bitrate del file estratto, mantenendo un margine di sicurezza del 15%
    /// per header e variazioni del bitrate.
    public static func maxDuration(forByteLimit bytes: Int, bitrate: Int, providerMaxDuration: TimeInterval?) -> TimeInterval {
        let bytesPerSecond = Double(bitrate) / 8
        var seconds = (Double(bytes) * 0.85) / bytesPerSecond
        if let providerMaxDuration { seconds = min(seconds, providerMaxDuration) }
        return seconds
    }
}

public enum ChunkPlanError: Error, Equatable {
    case invalidDuration
    case invalidConfiguration(String)
}

/// Pianifica la suddivisione di una registrazione lunga in chunk inviabili.
public enum ChunkPlanner {
    /// - Parameters:
    ///   - duration: durata totale dell'audio in secondi.
    ///   - silences: istanti (secondi) in cui è stata rilevata una pausa,
    ///     candidati preferiti per i tagli. Possono essere vuoti.
    public static func plan(duration: TimeInterval, silences: [TimeInterval] = [], configuration: ChunkPlanConfiguration) throws -> [ChunkSpec] {
        guard duration.isFinite, duration > 0 else { throw ChunkPlanError.invalidDuration }
        let config = configuration
        guard config.maxDuration > config.overlap + 1 else {
            throw ChunkPlanError.invalidConfiguration("La durata massima deve superare la sovrapposizione")
        }
        // Il core non può superare maxDuration - overlap, altrimenti il chunk
        // estratto (core + sovrapposizione) eccederebbe il limite.
        let maxCore = config.maxDuration - config.overlap
        let target = min(max(config.targetDuration, 10), maxCore)
        let window = min(config.silenceSearchWindow, target / 3)
        let sortedSilences = silences.filter { $0 > 0 && $0 < duration }.sorted()

        var boundaries: [(time: TimeInterval, silence: Bool)] = []
        var cursor: TimeInterval = 0
        while duration - cursor > target {
            let ideal = cursor + target
            let lowerBound = max(cursor + target - window, cursor + 10)
            let upperBound = min(cursor + target + window, cursor + maxCore, duration)
            let candidate = sortedSilences
                .filter { $0 >= lowerBound && $0 <= upperBound }
                .min { abs($0 - ideal) < abs($1 - ideal) }
            let cut = candidate ?? min(ideal, cursor + maxCore)
            // Evita un ultimo chunk minuscolo: se il resto è sotto la soglia e
            // può essere assorbito senza superare il massimo, si chiude qui.
            // La regola vale solo se il resto sarebbe davvero l'ultimo chunk
            // (non più lungo del target).
            let remainder = duration - cut
            let minimumTail = min(config.minimumTailDuration, target / 2)
            if remainder < minimumTail && remainder <= target && duration - cursor <= maxCore {
                break
            }
            boundaries.append((cut, candidate != nil))
            cursor = cut
        }

        var specs: [ChunkSpec] = []
        var start: TimeInterval = 0
        for (index, boundary) in (boundaries + [(duration, true)]).enumerated() {
            let extractStart = index == 0 ? start : max(0, start - config.overlap)
            specs.append(ChunkSpec(index: index, coreStart: start, coreEnd: boundary.time, extractStart: extractStart, extractEnd: boundary.time, endsOnSilence: boundary.silence))
            start = boundary.time
        }
        return specs
    }

    /// Verifica che le porzioni core formino una partizione completa e
    /// contigua di `0..<duration`. Restituisce gli intervalli scoperti.
    public static func coverageGaps(of specs: [ChunkSpec], duration: TimeInterval, tolerance: TimeInterval = 0.001) -> [ClosedRange<TimeInterval>] {
        var gaps: [ClosedRange<TimeInterval>] = []
        var cursor: TimeInterval = 0
        for spec in specs.sorted(by: { $0.coreStart < $1.coreStart }) {
            if spec.coreStart > cursor + tolerance {
                gaps.append(cursor...spec.coreStart)
            }
            cursor = max(cursor, spec.coreEnd)
        }
        if duration > cursor + tolerance {
            gaps.append(cursor...duration)
        }
        return gaps
    }
}
