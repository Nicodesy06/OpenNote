import Foundation
import PencilKit
import os

/// Salvataggio e caricamento dei disegni PencilKit (dati vettoriali,
/// `PKDrawing.dataRepresentation()`), fuori dal thread principale per non
/// bloccare la scrittura. Le scritture sono serializzate e atomiche: un
/// salvataggio interrotto non può corrompere il file precedente.
final class DrawingStore: @unchecked Sendable {
    private let fileStore: FileStore
    private let queue = DispatchQueue(label: "it.quadernoai.drawing-store", qos: .utility)
    private let logger = Logger(subsystem: "QuadernoAI", category: "DrawingStore")
    /// Cache limitata dei disegni decodificati (pagine adiacenti).
    private let cache = NSCache<NSString, DrawingBox>()

    final class DrawingBox {
        let drawing: PKDrawing
        init(_ drawing: PKDrawing) { self.drawing = drawing }
    }

    init(fileStore: FileStore) {
        self.fileStore = fileStore
        cache.countLimit = 6
    }

    static func relativePath(notebookID: UUID, pageID: UUID) -> String {
        "\(notebookID.uuidString)/\(pageID.uuidString).drawing"
    }

    func load(relativePath: String) async -> PKDrawing {
        if let cached = cache.object(forKey: relativePath as NSString) {
            return cached.drawing
        }
        let url = fileStore.drawingURL(relativePath: relativePath)
        return await withCheckedContinuation { continuation in
            queue.async {
                var drawing = PKDrawing()
                if let data = try? Data(contentsOf: url) {
                    do {
                        drawing = try PKDrawing(data: data)
                    } catch {
                        self.logger.error("Disegno illeggibile: \(error.localizedDescription, privacy: .public)")
                    }
                }
                self.cache.setObject(DrawingBox(drawing), forKey: relativePath as NSString)
                continuation.resume(returning: drawing)
            }
        }
    }

    /// Salva in modo asincrono; `completion` riceve dimensione e numero di
    /// tratti (sul thread principale) oppure l'errore.
    func save(_ drawing: PKDrawing, relativePath: String, completion: (@MainActor (Result<(bytes: Int, strokes: Int), Error>) -> Void)? = nil) {
        cache.setObject(DrawingBox(drawing), forKey: relativePath as NSString)
        let url = fileStore.drawingURL(relativePath: relativePath)
        queue.async {
            let data = drawing.dataRepresentation()
            let result: Result<(bytes: Int, strokes: Int), Error>
            do {
                try self.fileStore.writeAtomically(data, to: url)
                result = .success((data.count, drawing.strokes.count))
            } catch {
                self.logger.error("Salvataggio disegno non riuscito: \(error.localizedDescription, privacy: .public)")
                result = .failure(error)
            }
            if let completion {
                Task { @MainActor in completion(result) }
            }
        }
    }

    /// Salvataggio sincrono (chiusura dell'editor o passaggio in background).
    func saveSynchronously(_ drawing: PKDrawing, relativePath: String) throws {
        cache.setObject(DrawingBox(drawing), forKey: relativePath as NSString)
        let data = drawing.dataRepresentation()
        let url = fileStore.drawingURL(relativePath: relativePath)
        try queue.sync {
            try fileStore.writeAtomically(data, to: url)
        }
    }

    func copy(from source: String, to destination: String) {
        let sourceURL = fileStore.drawingURL(relativePath: source)
        let destinationURL = fileStore.drawingURL(relativePath: destination)
        queue.sync {
            if FileManager.default.fileExists(atPath: sourceURL.path) {
                try? fileStore.copyFile(from: sourceURL, to: destinationURL)
            }
        }
        cache.removeObject(forKey: destination as NSString)
    }

    func delete(relativePath: String) {
        cache.removeObject(forKey: relativePath as NSString)
        let url = fileStore.drawingURL(relativePath: relativePath)
        queue.async { self.fileStore.removeItemIfExists(url) }
    }

    func deleteNotebook(_ notebookID: UUID) {
        cache.removeAllObjects()
        let url = fileStore.drawingsDirectory.appendingPathComponent(notebookID.uuidString, isDirectory: true)
        queue.async { self.fileStore.removeItemIfExists(url) }
    }

    /// Attende il completamento delle scritture in coda.
    func flush() {
        queue.sync {}
    }
}
