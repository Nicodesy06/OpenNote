import Foundation
import os
import QuadernoCore

/// Trasporto per gli upload dei chunk audio basato su una URLSession in
/// background: il sistema completa l'invio anche se l'app viene sospesa a
/// schermo bloccato. Se l'app viene terminata e riavviata dal sistema, la
/// risposta viene interpretata e salvata direttamente nel checkpoint del
/// lavoro, così la ripresa non ripaga un chunk già trascritto.
///
/// Le richieste di generazione testuale (streaming) usano invece il
/// trasporto ordinario: le sessioni in background non supportano lo
/// streaming e il lavoro di generazione riprende per sezioni.
final class BackgroundUploadTransport: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let shared = BackgroundUploadTransport()

    struct Context: Codable {
        var checkpointDirectory: String
        var model: String
        var chunkIndex: Int?
        var bodyFile: String?
    }

    private struct Pending {
        var data = Data()
        var continuation: CheckedContinuation<HTTPResponse, Error>?
    }

    private let logger = Logger(subsystem: "QuadernoAI", category: "BackgroundUpload")
    private let lock = NSLock()
    private var pending: [Int: Pending] = [:]
    private var completionHandler: (() -> Void)?
    private lazy var session: URLSession = {
        let identifier = (Bundle.main.bundleIdentifier ?? "it.quadernoai.app") + ".uploads"
        let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        configuration.timeoutIntervalForResource = 60 * 60
        configuration.allowsCellularAccess = true
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    private var uploadsDirectory: URL {
        let url = FileStore.defaultRoot().appendingPathComponent("Jobs/Uploads", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Da chiamare all'avvio per ricollegarsi agli upload in corso.
    func reconnect() {
        _ = session
    }

    func setBackgroundCompletionHandler(_ handler: @escaping () -> Void) {
        lock.lock()
        completionHandler = handler
        lock.unlock()
        reconnect()
    }

    /// Trasporto legato a un lavoro specifico.
    func scoped(checkpointDirectory: URL, model: String, fallback: HTTPTransport) -> HTTPTransport {
        ScopedTransport(owner: self, checkpointDirectory: checkpointDirectory.path, model: model, fallback: fallback)
    }

    fileprivate func upload(_ request: HTTPRequest, bodyURL: URL, context: Context) async throws -> HTTPResponse {
        // Copia persistente del corpo: il file originale viene rimosso dal
        // provider al termine della chiamata.
        let copy = uploadsDirectory.appendingPathComponent(UUID().uuidString + ".multipart")
        try FileManager.default.copyItem(at: bodyURL, to: copy)
        var context = context
        context.bodyFile = copy.path

        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.timeoutInterval = request.timeout
        for (key, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: key) }
        let task = session.uploadTask(with: urlRequest, fromFile: copy)
        task.taskDescription = (try? JSONEncoder().encode(context)).map { String(decoding: $0, as: UTF8.self) }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                pending[task.taskIdentifier] = Pending(continuation: continuation)
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        var entry = pending[dataTask.taskIdentifier] ?? Pending()
        entry.data.append(data)
        pending[dataTask.taskIdentifier] = entry
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let entry = pending.removeValue(forKey: task.taskIdentifier) ?? Pending()
        lock.unlock()
        let context = task.taskDescription.flatMap { try? JSONDecoder().decode(Context.self, from: Data($0.utf8)) }
        if let file = context?.bodyFile { try? FileManager.default.removeItem(atPath: file) }

        let http = task.response as? HTTPURLResponse
        let response = HTTPResponse(statusCode: http?.statusCode ?? 0, headers: http.map(Self.headers) ?? [:], body: entry.data)

        if let continuation = entry.continuation {
            if let error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume(returning: response)
            }
            return
        }
        // Nessuno in attesa: l'app è stata riavviata dal sistema. Si salva il
        // risultato nel checkpoint del lavoro, se valido.
        guard error == nil, (200..<300).contains(response.statusCode), let context, let chunkIndex = context.chunkIndex else { return }
        do {
            let result = try OpenAITranscriptionProvider.parse(response.body, model: OpenAITranscriptionModel(identifier: context.model))
            let store = FileTranscriptionCheckpointStore(directory: URL(fileURLWithPath: context.checkpointDirectory))
            try store.saveResult(result, chunk: chunkIndex)
            logger.info("Risultato di un chunk salvato dopo riavvio in background")
        } catch {
            logger.error("Risultato in background non salvato: \(error.localizedDescription, privacy: .public)")
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        lock.lock()
        let handler = completionHandler
        completionHandler = nil
        lock.unlock()
        DispatchQueue.main.async { handler?() }
    }

    static func headers(_ response: HTTPURLResponse) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            result[String(describing: key)] = String(describing: value)
        }
        return result
    }
}

/// Instrada gli upload con corpo su file alla sessione in background e il
/// resto (JSON, streaming) al trasporto ordinario.
private struct ScopedTransport: HTTPTransport {
    let owner: BackgroundUploadTransport
    let checkpointDirectory: String
    let model: String
    let fallback: HTTPTransport

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard case .file(let bodyURL) = request.body else {
            return try await fallback.send(request)
        }
        var chunkIndex: Int?
        if let tag = request.tag, tag.hasPrefix("chunk:") {
            chunkIndex = Int(tag.dropFirst("chunk:".count))
        }
        let context = BackgroundUploadTransport.Context(checkpointDirectory: checkpointDirectory, model: model, chunkIndex: chunkIndex, bodyFile: nil)
        return try await owner.upload(request, bodyURL: bodyURL, context: context)
    }

    func streamLines(_ request: HTTPRequest) -> AsyncThrowingStream<String, Error> {
        fallback.streamLines(request)
    }
}
