import AVFoundation
import os

/// Scrive l'audio in file M4A/AAC consecutivi ("segmenti") che vengono chiusi
/// e finalizzati periodicamente. Ogni segmento chiuso è un file valido: in
/// caso di chiusura imprevista dell'app si perde al massimo il segmento in
/// corso. La rotazione avviene fra un buffer e il successivo dello stesso
/// flusso continuo, quindi non si creano buchi fra i segmenti.
///
/// Tutti i metodi vanno chiamati dalla stessa coda seriale.
final class SegmentedAudioWriter {
    struct Segment: Codable, Equatable {
        var index: Int
        var fileName: String
        var frames: Int64
        var sampleRate: Double
        var closed: Bool

        var duration: TimeInterval { sampleRate > 0 ? Double(frames) / sampleRate : 0 }
    }

    enum WriterError: Error, LocalizedError {
        case cannotCreateFile(String)
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .cannotCreateFile(let message): return "Impossibile creare il file audio: \(message)"
            case .writeFailed(let message): return "Scrittura dell'audio non riuscita: \(message)"
            }
        }
    }

    let directory: URL
    let encoding: EncodingSettings
    private(set) var segments: [Segment]
    private var currentFile: AVAudioFile?
    private var currentSampleRate: Double = 0
    private let logger = Logger(subsystem: "QuadernoAI", category: "SegmentedAudioWriter")

    /// Chiamato (sulla coda del writer) ogni volta che un segmento viene
    /// chiuso e finalizzato su disco.
    var onSegmentClosed: ((Segment) -> Void)?
    /// Chiamato quando viene aperto un nuovo segmento.
    var onSegmentOpened: ((Segment) -> Void)?

    init(directory: URL, encoding: EncodingSettings, existingSegments: [Segment] = []) {
        self.directory = directory
        self.encoding = encoding
        self.segments = existingSegments
    }

    var totalDuration: TimeInterval { segments.reduce(0) { $0 + $1.duration } }

    var isOpen: Bool { currentFile != nil }

    static func fileName(for index: Int) -> String {
        String(format: "segment-%04d.m4a", index)
    }

    func write(_ buffer: AVAudioPCMBuffer) throws {
        let sampleRate = buffer.format.sampleRate
        if currentFile == nil || sampleRate != currentSampleRate {
            if currentFile != nil { closeCurrentSegment() }
            try openSegment(sampleRate: sampleRate)
        }
        guard let file = currentFile else { return }
        do {
            try file.write(from: buffer)
        } catch {
            // Il segmento corrente viene chiuso per preservare quanto scritto.
            closeCurrentSegment()
            throw WriterError.writeFailed(error.localizedDescription)
        }
        segments[segments.count - 1].frames += Int64(buffer.frameLength)
        let maxFrames = Int64(encoding.segmentDuration * sampleRate)
        if segments[segments.count - 1].frames >= maxFrames {
            closeCurrentSegment()
        }
    }

    private func openSegment(sampleRate: Double) throws {
        let index = (segments.last?.index ?? -1) + 1
        let name = Self.fileName(for: index)
        let url = directory.appendingPathComponent(name)
        do {
            let file = try AVAudioFile(forWriting: url, settings: encoding.fileSettings(sampleRate: sampleRate), commonFormat: .pcmFormatFloat32, interleaved: false)
            try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
            currentFile = file
            currentSampleRate = sampleRate
            let segment = Segment(index: index, fileName: name, frames: 0, sampleRate: sampleRate, closed: false)
            segments.append(segment)
            onSegmentOpened?(segment)
        } catch {
            logger.error("Creazione segmento non riuscita: \(error.localizedDescription, privacy: .public)")
            throw WriterError.cannotCreateFile(error.localizedDescription)
        }
    }

    /// Chiude e finalizza il segmento corrente (scrive l'indice del file M4A).
    func closeCurrentSegment() {
        guard let file = currentFile else { return }
        if #available(iOS 18.0, *) {
            file.close()
        }
        // Su iOS 17 il file viene finalizzato al rilascio dell'oggetto.
        currentFile = nil
        guard !segments.isEmpty else { return }
        segments[segments.count - 1].closed = true
        let segment = segments[segments.count - 1]
        if segment.frames == 0 {
            // Segmento vuoto (es. pausa immediata): rimosso.
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(segment.fileName))
            segments.removeLast()
            return
        }
        onSegmentClosed?(segment)
    }
}
