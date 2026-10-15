import Foundation
@testable import QuadernoCore

/// Trasporto HTTP finto: registra le richieste e restituisce risposte
/// predefinite. Nessuna chiamata di rete reale nei test.
final class MockTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var requests: [HTTPRequest] = []
    private(set) var bodies: [Data] = []
    var handler: (HTTPRequest, Data) throws -> HTTPResponse
    var streamHandler: ((HTTPRequest, Data) throws -> [String])?

    init(handler: @escaping (HTTPRequest, Data) throws -> HTTPResponse) {
        self.handler = handler
    }

    private func record(_ request: HTTPRequest) -> Data {
        var body = Data()
        switch request.body {
        case .none: break
        case .data(let data): body = data
        case .file(let url): body = (try? Data(contentsOf: url)) ?? Data()
        }
        lock.lock()
        requests.append(request)
        bodies.append(body)
        lock.unlock()
        return body
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let body = record(request)
        return try handler(request, body)
    }

    func streamLines(_ request: HTTPRequest) -> AsyncThrowingStream<String, Error> {
        let body = record(request)
        return AsyncThrowingStream { continuation in
            do {
                if let streamHandler {
                    for line in try streamHandler(request, body) { continuation.yield(line) }
                } else {
                    let response = try handler(request, body)
                    guard (200..<300).contains(response.statusCode) else { throw HTTPStatusFailure(response: response) }
                    for line in String(decoding: response.body, as: UTF8.self).components(separatedBy: "\n") { continuation.yield(line) }
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests.count
    }
}

func jsonResponse(_ object: Any, status: Int = 200, headers: [String: String] = [:]) -> HTTPResponse {
    let data = try! JSONSerialization.data(withJSONObject: object)
    return HTTPResponse(statusCode: status, headers: headers, body: data)
}

/// Estrattore audio finto: crea file di dimensione proporzionale alla
/// durata, senza AVFoundation.
final class MockExtractor: AudioChunkExtractor, @unchecked Sendable {
    let bitrate: Int
    let silences: [TimeInterval]
    private let lock = NSLock()
    private(set) var extracted: [ChunkSpec] = []
    private(set) var silenceQueries: [[TimeInterval]] = []

    init(bitrate: Int = 64_000, silences: [TimeInterval] = []) {
        self.bitrate = bitrate
        self.silences = silences
    }

    func estimatedBitrate(of source: URL) async throws -> Int { bitrate }

    func silenceCandidates(in source: URL, around times: [TimeInterval], window: TimeInterval) async throws -> [TimeInterval] {
        lock.lock()
        silenceQueries.append(times)
        lock.unlock()
        return silences.filter { silence in times.contains { abs($0 - silence) <= window } }
    }

    func extract(_ spec: ChunkSpec, from source: URL, into directory: URL) async throws -> AudioChunkFile {
        lock.lock()
        extracted.append(spec)
        lock.unlock()
        let url = directory.appendingPathComponent("chunk-\(spec.index)-\(UUID().uuidString).m4a")
        let size = Int(spec.extractDuration * Double(bitrate) / 8 / 1000) // file ridotto per i test
        try Data(repeating: 0, count: max(1, size)).write(to: url)
        return AudioChunkFile(spec: spec, url: url, byteSize: Int(spec.extractDuration * Double(bitrate) / 8))
    }
}

/// Provider di trascrizione finto con risultati programmabili per chunk.
final class MockTranscriptionProvider: TranscriptionProvider, @unchecked Sendable {
    let id = "mock"
    let displayName = "Mock STT"
    let model = "mock-1"
    var capabilities = TranscriptionCapabilities(maxUploadBytes: 25 * 1024 * 1024, maxChunkDuration: nil, returnsSegmentTimestamps: false, supportsDiarization: false, supportsPrompt: true, supportsKeywords: true, requiresNetwork: true, supportedFileExtensions: ["m4a"])
    private let lock = NSLock()
    private(set) var calls: [Int] = []
    var failures: [Int: AIServiceError] = [:]
    var textForChunk: (ChunkSpec) -> String = { "Testo del chunk \($0.index)." }

    func transcribe(chunk: AudioChunkFile, options: TranscriptionOptions) async throws -> ChunkTranscription {
        lock.lock()
        calls.append(chunk.spec.index)
        let failure = failures[chunk.spec.index]
        lock.unlock()
        if let failure { throw failure }
        return ChunkTranscription(text: textForChunk(chunk.spec), model: model, providerID: id)
    }

    func estimateCost(durationSeconds: TimeInterval) -> CostEstimate? {
        CostEstimate(amountUSD: durationSeconds / 60 * 0.005, basis: "mock")
    }
}

/// Provider di generazione programmabile: sceglie la risposta in base al
/// contenuto della richiesta (scaletta, sezione, verifica, correzione).
final class ScriptedTextProvider: TextGenerationProvider, @unchecked Sendable {
    let id = "scripted"
    let displayName = "Scripted LLM"
    let model = "scripted-1"
    var inputCharacterBudget = 600_000
    var indicativePricePerMillion: (input: Double, output: Double)? = (1, 5)
    private let lock = NSLock()
    private(set) var requests: [GenerationRequest] = []
    var responder: (GenerationRequest) throws -> GenerationResult

    init(responder: @escaping (GenerationRequest) throws -> GenerationResult) {
        self.responder = responder
    }

    func generate(_ request: GenerationRequest, onTextDelta: (@Sendable (String) -> Void)?) async throws -> GenerationResult {
        lock.lock()
        requests.append(request)
        lock.unlock()
        let result = try responder(request)
        onTextDelta?(result.text)
        return result
    }

    func listModels() async throws -> [String] { [model] }

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests.count
    }

    func requests(containing marker: String) -> [GenerationRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests.filter { $0.messages.first?.text.contains(marker) == true }
    }
}

func makeTemporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("QuadernoCoreTests-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func result(_ text: String, stop: GenerationStopReason = .complete) -> GenerationResult {
    GenerationResult(text: text, stopReason: stop, usage: GenerationUsage(inputTokens: 100, outputTokens: 50), model: "scripted-1")
}
