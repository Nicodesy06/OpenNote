import Foundation
import os

/// Gestione centralizzata dei file dell'app (audio, disegni, PDF, immagini,
/// checkpoint dei lavori AI).
///
/// Protezione dei file: le registrazioni devono poter essere scritte anche a
/// schermo bloccato. Con `NSFileProtectionComplete` un file aperto prima del
/// blocco diventerebbe inaccessibile dopo il blocco e la scrittura fallirebbe.
/// Si usa quindi `completeUntilFirstUserAuthentication`: i dati sono cifrati
/// a dispositivo spento o riavviato e non ancora sbloccato, e accessibili dopo
/// il primo sblocco. È il compromesso documentato fra sicurezza e affidabilità
/// della registrazione (lo stesso livello predefinito delle app iOS).
final class FileStore: @unchecked Sendable {
    static let logger = Logger(subsystem: "QuadernoAI", category: "FileStore")

    let root: URL
    private let fileManager = FileManager.default

    init(root: URL) {
        self.root = root
        createBaseDirectories()
    }

    static func defaultRoot() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("QuadernoAI", isDirectory: true)
    }

    // MARK: - Cartelle

    var storeURL: URL { root.appendingPathComponent("Database/Library.store") }
    var recordingsDirectory: URL { root.appendingPathComponent("Recordings", isDirectory: true) }
    var drawingsDirectory: URL { root.appendingPathComponent("Drawings", isDirectory: true) }
    var pageImagesDirectory: URL { root.appendingPathComponent("PageImages", isDirectory: true) }
    var materialsDirectory: URL { root.appendingPathComponent("Materials", isDirectory: true) }
    var documentImagesDirectory: URL { root.appendingPathComponent("DocumentImages", isDirectory: true) }
    var jobsDirectory: URL { root.appendingPathComponent("Jobs", isDirectory: true) }
    var exportsDirectory: URL { fileManager.temporaryDirectory.appendingPathComponent("Exports", isDirectory: true) }
    var importsDirectory: URL { fileManager.temporaryDirectory.appendingPathComponent("Imports", isDirectory: true) }

    private func createBaseDirectories() {
        for directory in [root, storeURL.deletingLastPathComponent(), recordingsDirectory, drawingsDirectory, pageImagesDirectory, materialsDirectory, documentImagesDirectory, jobsDirectory] {
            ensureDirectory(directory)
        }
        // Esclude dal backup iCloud i dati temporanei dei lavori.
        var jobs = jobsDirectory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? jobs.setResourceValues(values)
    }

    func ensureDirectory(_ url: URL) {
        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        } catch {
            Self.logger.error("Creazione cartella non riuscita: \(error.localizedDescription, privacy: .public)")
        }
    }

    func recordingDirectory(_ id: UUID) -> URL {
        let url = recordingsDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
        ensureDirectory(url)
        return url
    }

    func recordingFileURL(recordingID: UUID, fileName: String) -> URL {
        recordingsDirectory.appendingPathComponent(recordingID.uuidString, isDirectory: true).appendingPathComponent(fileName)
    }

    func drawingURL(relativePath: String) -> URL {
        drawingsDirectory.appendingPathComponent(relativePath)
    }

    func materialURL(fileName: String) -> URL {
        materialsDirectory.appendingPathComponent(fileName)
    }

    func materialAnnotationsDirectory(_ id: UUID) -> URL {
        let url = materialsDirectory.appendingPathComponent("Annotations-\(id.uuidString)", isDirectory: true)
        ensureDirectory(url)
        return url
    }

    func jobDirectory(_ id: UUID) -> URL {
        let url = jobsDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
        ensureDirectory(url)
        return url
    }

    func pageImageURL(relativePath: String) -> URL {
        pageImagesDirectory.appendingPathComponent(relativePath)
    }

    func documentImageURL(relativePath: String) -> URL {
        documentImagesDirectory.appendingPathComponent(relativePath)
    }

    // MARK: - Scritture

    /// Scrittura atomica (file temporaneo + rename) con protezione adatta
    /// alla scrittura a schermo bloccato.
    func writeAtomically(_ data: Data, to url: URL) throws {
        ensureDirectory(url.deletingLastPathComponent())
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func fileExists(_ url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path)
    }

    func size(of url: URL) -> Int64 {
        (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
    }

    func removeItemIfExists(_ url: URL) {
        guard fileManager.fileExists(atPath: url.path) else { return }
        do {
            try fileManager.removeItem(at: url)
        } catch {
            Self.logger.error("Eliminazione non riuscita: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Copia un file a blocchi (FileManager.copyItem non carica il file in RAM).
    func copyFile(from source: URL, to destination: URL) throws {
        ensureDirectory(destination.deletingLastPathComponent())
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: source, to: destination)
        try? fileManager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: destination.path)
    }

    // MARK: - Spazio

    /// Spazio disponibile per dati importanti (in byte).
    func availableCapacity() -> Int64 {
        let values = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
        return Int64(values?.volumeAvailableCapacity ?? 0)
    }

    /// Occupazione di una cartella (per la schermata Archiviazione).
    func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey], options: [], errorHandler: nil) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
        }
        return total
    }

    /// Rimuove file temporanei rimasti da sessioni precedenti (upload,
    /// esportazioni, chunk audio).
    func cleanTemporaryFiles() {
        removeItemIfExists(exportsDirectory)
        removeItemIfExists(importsDirectory)
        let temporary = fileManager.temporaryDirectory
        if let items = try? fileManager.contentsOfDirectory(at: temporary, includingPropertiesForKeys: nil) {
            for item in items where item.pathExtension == "multipart" {
                removeItemIfExists(item)
            }
        }
    }

    func newExportURL(fileName: String) -> URL {
        ensureDirectory(exportsDirectory)
        return exportsDirectory.appendingPathComponent(Self.sanitizedFileName(fileName))
    }

    static func sanitizedFileName(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        let cleaned = name.components(separatedBy: invalid).joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Documento" : String(cleaned.prefix(120))
    }
}
