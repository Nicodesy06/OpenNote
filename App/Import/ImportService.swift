import AVFoundation
import PDFKit
import SwiftData
import UniformTypeIdentifiers
import os

/// Importazione di file audio (M4A, MP3, WAV, AAC, MP4 con traccia audio) e
/// PDF. I file vengono copiati nello spazio dell'app senza caricarli in RAM;
/// la pipeline di trascrizione è identica per audio importati e registrati.
@MainActor
final class ImportService {
    enum ImportError: Error, LocalizedError {
        case accessDenied
        case noAudioTrack
        case unreadable(String)
        case insufficientStorage
        case invalidPDF

        var errorDescription: String? {
            switch self {
            case .accessDenied: return "Non è stato possibile accedere al file selezionato."
            case .noAudioTrack: return "Il file non contiene una traccia audio riproducibile."
            case .unreadable(let message): return "File non leggibile: \(message)"
            case .insufficientStorage: return "Spazio insufficiente per importare il file."
            case .invalidPDF: return "Il file non è un PDF valido."
            }
        }
    }

    static let audioTypes: [UTType] = [.audio, .mpeg4Audio, .mp3, .wav, .aiff, .mpeg4Movie, .quickTimeMovie, UTType("public.aac-audio") ?? .audio]

    private let fileStore: FileStore
    private let modelContainer: ModelContainer
    private let logger = Logger(subsystem: "QuadernoAI", category: "Import")

    init(fileStore: FileStore, modelContainer: ModelContainer) {
        self.fileStore = fileStore
        self.modelContainer = modelContainer
    }

    private var context: ModelContext { modelContainer.mainContext }

    /// Importa un file audio. `url` può provenire dal selettore File (risorsa
    /// con ambito di sicurezza) o da "Apri con".
    func importAudio(from url: URL, subject: Subject?, title: String? = nil) async throws -> AudioRecording {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        guard fileStore.availableCapacity() > size + 100 * 1024 * 1024 else { throw ImportError.insufficientStorage }

        let recording = AudioRecording(title: title ?? url.deletingPathExtension().lastPathComponent, source: .imported, status: .finalizing)
        recording.originalFileName = url.lastPathComponent
        let ext = url.pathExtension.isEmpty ? "m4a" : url.pathExtension.lowercased()
        let fileName = "original.\(ext)"
        let destination = fileStore.recordingFileURL(recordingID: recording.id, fileName: fileName)
        _ = fileStore.recordingDirectory(recording.id)

        // Coordinazione per i provider di documenti (iCloud Drive ecc.).
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { readURL in
            do {
                try fileStore.copyFile(from: readURL, to: destination)
            } catch {
                copyError = error
            }
        }
        if let error = coordinationError ?? copyError {
            fileStore.removeItemIfExists(fileStore.recordingsDirectory.appendingPathComponent(recording.id.uuidString))
            throw ImportError.unreadable(error.localizedDescription)
        }

        let asset = AVURLAsset(url: destination)
        do {
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            guard !tracks.isEmpty else { throw ImportError.noAudioTrack }
            let duration = try await asset.load(.duration)
            recording.duration = duration.isValid ? duration.seconds : 0
            if let creation = try? await asset.load(.creationDate), let date = try? await creation.load(.dateValue) {
                recording.recordedAt = date
            }
        } catch let error as ImportError {
            fileStore.removeItemIfExists(fileStore.recordingsDirectory.appendingPathComponent(recording.id.uuidString))
            throw error
        } catch {
            fileStore.removeItemIfExists(fileStore.recordingsDirectory.appendingPathComponent(recording.id.uuidString))
            throw ImportError.unreadable(error.localizedDescription)
        }

        recording.audioFileName = fileName
        recording.byteSize = fileStore.size(of: destination)
        recording.status = .ready
        recording.subject = subject
        context.insert(recording)
        try context.save()
        logger.info("Audio importato")
        return recording
    }

    func importPDF(from url: URL, subject: Subject?, kind: MaterialKind = .other) throws -> PDFMaterial {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let id = UUID()
        let fileName = "\(id.uuidString).pdf"
        let destination = fileStore.materialURL(fileName: fileName)
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { readURL in
            do {
                try fileStore.copyFile(from: readURL, to: destination)
            } catch {
                copyError = error
            }
        }
        if let error = coordinationError ?? copyError { throw ImportError.unreadable(error.localizedDescription) }
        guard let document = PDFDocument(url: destination) else {
            fileStore.removeItemIfExists(destination)
            throw ImportError.invalidPDF
        }
        let material = PDFMaterial(title: url.deletingPathExtension().lastPathComponent, fileName: fileName, pageCount: document.pageCount, kind: kind)
        material.subject = subject
        context.insert(material)
        try context.save()
        return material
    }

    static func isAudio(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .audio) || type.conforms(to: .movie)
    }

    static func isPDF(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .pdf) == true
    }
}
