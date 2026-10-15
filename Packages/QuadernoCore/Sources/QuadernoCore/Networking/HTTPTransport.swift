import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Corpo di una richiesta HTTP: in memoria oppure letto da file (per upload
/// audio grandi, senza caricare l'intero file in RAM).
public enum HTTPBody: Sendable, Equatable {
    case none
    case data(Data)
    case file(URL)
}

public struct HTTPRequest: Sendable {
    public var url: URL
    public var method: String
    public var headers: [String: String]
    public var body: HTTPBody
    public var timeout: TimeInterval

    public init(url: URL, method: String = "GET", headers: [String: String] = [:], body: HTTPBody = .none, timeout: TimeInterval = 120) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.timeout = timeout
    }
}

public struct HTTPResponse: Sendable {
    public var statusCode: Int
    public var headers: [String: String]
    public var body: Data

    public init(statusCode: Int, headers: [String: String] = [:], body: Data) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }

    public func header(_ name: String) -> String? {
        let lower = name.lowercased()
        return headers.first { $0.key.lowercased() == lower }?.value
    }
}

/// Astrazione del trasporto: l'app usa URLSession (anche in background), i
/// test usano un trasporto finto che non effettua chiamate reali.
public protocol HTTPTransport: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
    /// Restituisce le righe del corpo della risposta man mano che arrivano
    /// (Server-Sent Events). Se lo stato HTTP non è 2xx lancia
    /// `HTTPStatusFailure` con il corpo completo.
    func streamLines(_ request: HTTPRequest) -> AsyncThrowingStream<String, Error>
}

public struct HTTPStatusFailure: Error, Sendable {
    public var response: HTTPResponse
    public init(response: HTTPResponse) { self.response = response }
}

/// Trasporto basato su URLSession.
public final class URLSessionTransport: HTTPTransport, @unchecked Sendable {
    private let session: URLSession

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 600
            config.timeoutIntervalForResource = 60 * 60
            #if !canImport(FoundationNetworking)
            config.waitsForConnectivity = false
            #endif
            self.session = URLSession(configuration: config)
        }
    }

    static func makeURLRequest(_ request: HTTPRequest) -> URLRequest {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.timeoutInterval = request.timeout
        for (key, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }
        switch request.body {
        case .none, .file:
            break
        case .data(let data):
            urlRequest.httpBody = data
        }
        return urlRequest
    }

    static func headers(of response: HTTPURLResponse) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            result[String(describing: key)] = String(describing: value)
        }
        return result
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let urlRequest = Self.makeURLRequest(request)
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HTTPResponse, Error>) in
            let completion: @Sendable (Data?, URLResponse?, Error?) -> Void = { data, response, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let http = response as? HTTPURLResponse else {
                    continuation.resume(throwing: AIServiceError.network("Risposta non HTTP"))
                    return
                }
                continuation.resume(returning: HTTPResponse(statusCode: http.statusCode, headers: Self.headers(of: http), body: data ?? Data()))
            }
            let task: URLSessionTask
            if case .file(let fileURL) = request.body {
                task = session.uploadTask(with: urlRequest, fromFile: fileURL, completionHandler: completion)
            } else {
                task = session.dataTask(with: urlRequest, completionHandler: completion)
            }
            task.resume()
        }
    }

    public func streamLines(_ request: HTTPRequest) -> AsyncThrowingStream<String, Error> {
        #if canImport(FoundationNetworking)
        // swift-corelibs-foundation non offre URLSession.bytes: si ripiega su
        // una richiesta bufferizzata, sufficiente per test e strumenti CLI.
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let response = try await self.send(request)
                    guard (200..<300).contains(response.statusCode) else {
                        throw HTTPStatusFailure(response: response)
                    }
                    let text = String(decoding: response.body, as: UTF8.self)
                    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                        continuation.yield(String(line).trimmingCharacters(in: CharacterSet(charactersIn: "\r")))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        #else
        let urlRequest = Self.makeURLRequest(request)
        let session = self.session
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: urlRequest)
                    guard let http = response as? HTTPURLResponse else {
                        throw AIServiceError.network("Risposta non HTTP")
                    }
                    if !(200..<300).contains(http.statusCode) {
                        var body = Data()
                        for try await byte in bytes { body.append(byte) }
                        throw HTTPStatusFailure(response: HTTPResponse(statusCode: http.statusCode, headers: Self.headers(of: http), body: body))
                    }
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        continuation.yield(line)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        #endif
    }
}
