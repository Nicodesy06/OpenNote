import AVFoundation
import SwiftData
import os

/// Finalizzazione e recupero delle registrazioni.
///
/// - `finalize`: unisce i segmenti in `audio.m4a` dopo lo Stop. I segmenti
///   vengono eliminati solo dopo aver verificato il file unito.
/// - `recoverInterruptedRecordings`: all'avvio ricostruisce le registrazioni
///   rimaste "in corso" per un crash o una chiusura forzata, usando il
///   manifest e i segmenti su disco.
@MainActor
final class RecordingMaintenance {
    static let consolidatedFileName = "audio.m4a"

    private let fileStore: FileStore
    private let modelContainer: ModelContainer
    private let logger = Logger(subsystem: "QuadernoAI", category: "RecordingMaintenance")
    private var finalizing = Set<UUID>()

    init(fileStore: FileStore, modelContainer: ModelContainer) {
        self.fileStore = fileStore
        self.modelContainer = modelContainer
    }

    private var context: ModelContext { modelContainer.mainContext }

    private func fetch(_ id: UUID) -> AudioRecording? {
        try? context.fetch(FetchDescriptor<AudioRecording>(predicate: #Predicate { $0.id == id })).first
    }

    /// URL del file audio riproducibile/trascrivibile, se esiste.
    func playableURL(for recording: AudioRecording) -> URL? {
        if let name = recording.audioFileName {
            let url = fileStore.recordingFileURL(recordingID: recording.id, fileName: name)
            if fileStore.fileExists(url) { return url }
        }
        return nil
    }

    /// URL dei segmenti esistenti, in ordine.
    func segmentURLs(for recording: AudioRecording) -> [URL] {
        recording.orderedSegments
            .map { fileStore.recordingFileURL(recordingID: recording.id, fileName: $0.fileName) }
            .filter { fileStore.fileExists($0) }
    }

    /// Unisce i segmenti. Idempotente: se il file unito esiste già ed è
    /// valido, si limita a ripulire i segmenti.
    @discardableResult
    func finalize(recordingID: UUID) async -> Bool {
        guard !finalizing.contains(recordingID), let recording = fetch(recordingID) else { return false }
        if playableURL(for: recording) != nil, recording.segments.isEmpty {
            if recording.status == .finalizing { recording.status = .ready }
            try? context.save()
            return true
        }
        let segments = segmentURLs(for: recording)
        guard !segments.isEmpty else {
            if playableURL(for: recording) == nil {
                recording.status = .damaged
                try? context.save()
            }
            return false
        }
        finalizing.insert(recordingID)
        defer { finalizing.remove(recordingID) }
        let output = fileStore.recordingFileURL(recordingID: recordingID, fileName: Self.consolidatedFileName)
        do {
            let duration = try await AudioConsolidator.consolidate(segments: segments, output: output)
            guard let recording = fetch(recordingID) else { return false }
            recording.audioFileName = Self.consolidatedFileName
            recording.duration = duration
            recording.byteSize = fileStore.size(of: output)
            for segment in recording.segments { context.delete(segment) }
            if recording.status != .recovered { recording.status = .ready }
            try context.save()
            for url in segments { fileStore.removeItemIfExists(url) }
            logger.info("Registrazione finalizzata")
            return true
        } catch {
            logger.error("Finalizzazione non riuscita: \(error.localizedDescription, privacy: .public)")
            fileStore.removeItemIfExists(output)
            // I segmenti restano su disco e riproducibili; si ritenterà.
            if let recording = fetch(recordingID), recording.status == .finalizing {
                recording.status = .ready
                try? context.save()
            }
            return false
        }
    }

    /// Composizione dei segmenti per riprodurre una registrazione non ancora
    /// unita.
    func compositionForSegments(of recording: AudioRecording) async -> AVAsset? {
        let urls = segmentURLs(for: recording)
        guard !urls.isEmpty else { return nil }
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { return nil }
        var cursor = CMTime.zero
        for url in urls {
            let asset = AVURLAsset(url: url)
            guard let source = try? await asset.loadTracks(withMediaType: .audio).first,
                  let duration = try? await asset.load(.duration), duration.seconds > 0 else { continue }
            try? track.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: source, at: cursor)
            cursor = CMTimeAdd(cursor, duration)
        }
        return composition
    }

    // MARK: - Recupero all'avvio

    /// Da chiamare all'avvio, quando nessuna registrazione è attiva.
    func recoverInterruptedRecordings() async {
        let directories = (try? FileManager.default.contentsOfDirectory(at: fileStore.recordingsDirectory, includingPropertiesForKeys: nil)) ?? []
        for directory in directories {
            guard let id = UUID(uuidString: directory.lastPathComponent) else { continue }
            let manifestURL = directory.appendingPathComponent(RecordingManifest.fileName)
            guard var manifest = ManifestWriter.load(from: manifestURL) else { continue }
            let recording = fetch(id)
            let needsRecovery = manifest.status != .finished || recording == nil || recording?.status == .recording
            if needsRecovery {
                await recover(manifest: &manifest, directory: directory, existing: recording)
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                if let data = try? encoder.encode(manifest) {
                    try? fileStore.writeAtomically(data, to: manifestURL)
                }
            }
        }
        // Registrazioni rimaste in finalizzazione (unione interrotta).
        let pending = (try? context.fetch(FetchDescriptor<AudioRecording>())) ?? []
        for recording in pending where recording.status == .finalizing || recording.status == .recovered || (recording.audioFileName == nil && !recording.segments.isEmpty) {
            await finalize(recordingID: recording.id)
        }
        verifyFiles()
    }

    private func recover(manifest: inout RecordingManifest, directory: URL, existing: AudioRecording?) async {
        logger.notice("Recupero di una registrazione interrotta")
        // Segmenti: quelli chiusi sono validi; l'ultimo aperto viene
        // verificato e scartato se illeggibile (file M4A non finalizzato).
        var validSegments: [SegmentedAudioWriter.Segment] = []
        for var segment in manifest.segments {
            let url = directory.appendingPathComponent(segment.fileName)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            if segment.closed {
                validSegments.append(segment)
                continue
            }
            if let duration = try? await AudioConsolidator.duration(of: url), duration > 0.5 {
                segment.frames = Int64(duration * max(segment.sampleRate, 1))
                segment.closed = true
                validSegments.append(segment)
            } else {
                logger.notice("Segmento finale non finalizzato: scartato")
                try? FileManager.default.removeItem(at: url)
            }
        }
        manifest.segments = validSegments
        manifest.status = .finished
        manifest.updatedAt = Date()

        let recording: AudioRecording
        if let existing {
            recording = existing
        } else {
            recording = AudioRecording(title: manifest.title, source: .recorded, status: .recovered)
            recording.id = manifest.recordingID
            recording.recordedAt = manifest.startedAt
            recording.createdAt = manifest.startedAt
            if let subjectID = manifest.subjectID {
                recording.subject = try? context.fetch(FetchDescriptor<Subject>(predicate: #Predicate { $0.id == subjectID })).first
            }
            if let notebookID = manifest.notebookID {
                recording.notebook = try? context.fetch(FetchDescriptor<Notebook>(predicate: #Predicate { $0.id == notebookID })).first
            }
            context.insert(recording)
        }
        for segment in recording.segments { context.delete(segment) }
        var offset: TimeInterval = 0
        for segment in validSegments {
            let model = AudioSegment(index: segment.index, fileName: segment.fileName, startOffset: offset, duration: segment.duration)
            model.recording = recording
            context.insert(model)
            offset += segment.duration
        }
        let existingMarks = Set(recording.pageMarks.map { "\($0.pageID)-\($0.time)" })
        for mark in manifest.marks where !existingMarks.contains("\(mark.pageID)-\(mark.time)") {
            let model = PageMark(pageID: mark.pageID, pageIndex: mark.pageIndex, time: mark.time, kind: PageMarkKind(rawValue: mark.kind) ?? .visited)
            model.recording = recording
            context.insert(model)
        }
        recording.duration = offset
        recording.status = validSegments.isEmpty ? .damaged : .recovered
        if !recording.notes.contains("recuperata") {
            recording.notes += (recording.notes.isEmpty ? "" : "\n") + "Registrazione recuperata dopo una chiusura imprevista dell'app (\(Self.dateString(Date())))."
        }
        try? context.save()
    }

    /// Segnala le registrazioni pronte il cui file audio è sparito.
    func verifyFiles() {
        let recordings = (try? context.fetch(FetchDescriptor<AudioRecording>())) ?? []
        var changed = false
        for recording in recordings where recording.status == .ready || recording.status == .recovered {
            if playableURL(for: recording) == nil && segmentURLs(for: recording).isEmpty {
                recording.status = .damaged
                changed = true
            }
        }
        if changed { try? context.save() }
    }

    static func dateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "it_IT")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
