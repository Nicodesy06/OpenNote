import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Richiesta di creazione di un lavoro sul backend gestito.
public struct BackendJobRequest: Codable, Sendable, Equatable {
    public var idempotencyKey: String
    public var mode: SbobinaturaMode
    public var subjectName: String
    public var lessonTitle: String
    public var lessonDate: Date?
    public var documentLanguage: String
    public var transcriptionLanguages: [String]
    public var glossary: [String]
    public var instructions: String?
    public var transcriptionModel: String
    public var generationProvider: String
    public var generationModel: String
    public var includeGeneration: Bool

    public init(idempotencyKey: String, mode: SbobinaturaMode, subjectName: String, lessonTitle: String, lessonDate: Date?, documentLanguage: String, transcriptionLanguages: [String], glossary: [String], instructions: String?, transcriptionModel: String, generationProvider: String, generationModel: String, includeGeneration: Bool) {
        self.idempotencyKey = idempotencyKey
        self.mode = mode
        self.subjectName = subjectName
        self.lessonTitle = lessonTitle
        self.lessonDate = lessonDate
        self.documentLanguage = documentLanguage
        self.transcriptionLanguages = transcriptionLanguages
        self.glossary = glossary
        self.instructions = instructions
        self.transcriptionModel = transcriptionModel
        self.generationProvider = generationProvider
        self.generationModel = generationModel
        self.includeGeneration = includeGeneration
    }
}

public struct BackendJobStatus: Codable, Sendable, Equatable {
    public var id: String
    public var status: String
    public var progress: Double
    public var step: String
    public var error: String?

    public init(id: String, status: String, progress: Double, step: String, error: String?) {
        self.id = id
        self.status = status
        self.progress = progress
        self.step = step
        self.error = error
    }

    public var isFinished: Bool { status == "completed" || status == "failed" || status == "cancelled" }
}

/// Risultato di un lavoro: trascrizione e (se richiesta) sbobinatura, negli
/// stessi formati prodotti dalla pipeline locale.
public struct BackendJobResult: Codable, Sendable, Equatable {
    public var transcript: MergedTranscript
    public var transcriptionProviderID: String
    public var transcriptionModel: String
    public var document: GeneratedDocumentDTO?

    public init(transcript: MergedTranscript, transcriptionProviderID: String, transcriptionModel: String, document: GeneratedDocumentDTO?) {
        self.transcript = transcript
        self.transcriptionProviderID = transcriptionProviderID
        self.transcriptionModel = transcriptionModel
        self.document = document
    }
}

/// Client del backend gestito (vedi cartella `Backend/`). Il backend
/// conserva i segreti dei provider lato server, esegue la stessa pipeline
/// (QuadernoCore) in un processo persistente e permette di recuperare i
/// risultati anche se l'iPad è stato bloccato durante l'elaborazione.
public struct BackendJobClient: Sendable {
    public let baseURL: URL
    private let token: String
    private let transport: HTTPTransport

    public init(baseURL: URL, token: String, transport: HTTPTransport) {
        self.baseURL = baseURL
        self.token = token
        self.transport = transport
    }

    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: text) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: text) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Data non valida: \(text)")
        }
        return decoder
    }()

    private func headers(json: Bool = true) -> [String: String] {
        var headers = ["Authorization": "Bearer \(token)"]
        if json { headers["Content-Type"] = "application/json" }
        return headers
    }

    private func perform(_ request: HTTPRequest) async throws -> HTTPResponse {
        let response: HTTPResponse
        do {
            response = try await transport.send(request)
        } catch {
            throw AIServiceError.from(error, provider: "Backend")
        }
        guard (200..<300).contains(response.statusCode) else {
            throw AIServiceError.fromHTTP(response, provider: "Backend")
        }
        return response
    }

    public func createJob(_ job: BackendJobRequest) async throws -> BackendJobStatus {
        var request = HTTPRequest(url: baseURL.appendingPathComponent("v1/jobs"), method: "POST", headers: headers(), body: .data(try Self.encoder.encode(job)), timeout: 60)
        request.headers["Idempotency-Key"] = job.idempotencyKey
        let response = try await perform(request)
        return try decode(BackendJobStatus.self, response.body)
    }

    /// Carica l'audio come corpo binario letto da file (nessun caricamento
    /// completo in RAM sul dispositivo).
    public func uploadAudio(jobID: String, fileURL: URL, contentType: String = "audio/mp4") async throws -> BackendJobStatus {
        var headers = headers(json: false)
        headers["Content-Type"] = contentType
        headers["X-File-Name"] = fileURL.lastPathComponent
        let request = HTTPRequest(url: baseURL.appendingPathComponent("v1/jobs/\(jobID)/audio"), method: "PUT", headers: headers, body: .file(fileURL), timeout: 3600, tag: "backend-audio:\(jobID)")
        let response = try await perform(request)
        return try decode(BackendJobStatus.self, response.body)
    }

    public func startJob(jobID: String) async throws -> BackendJobStatus {
        let response = try await perform(HTTPRequest(url: baseURL.appendingPathComponent("v1/jobs/\(jobID)/start"), method: "POST", headers: headers(), body: .data(Data("{}".utf8)), timeout: 60))
        return try decode(BackendJobStatus.self, response.body)
    }

    public func status(jobID: String) async throws -> BackendJobStatus {
        let response = try await perform(HTTPRequest(url: baseURL.appendingPathComponent("v1/jobs/\(jobID)"), headers: headers(json: false), timeout: 30))
        return try decode(BackendJobStatus.self, response.body)
    }

    public func result(jobID: String) async throws -> BackendJobResult {
        let response = try await perform(HTTPRequest(url: baseURL.appendingPathComponent("v1/jobs/\(jobID)/result"), headers: headers(json: false), timeout: 120))
        return try decode(BackendJobResult.self, response.body)
    }

    public func deleteJob(jobID: String) async throws {
        _ = try await perform(HTTPRequest(url: baseURL.appendingPathComponent("v1/jobs/\(jobID)"), method: "DELETE", headers: headers(json: false), timeout: 30))
    }

    public func health() async throws -> Bool {
        let response = try await perform(HTTPRequest(url: baseURL.appendingPathComponent("v1/health"), headers: headers(json: false), timeout: 15))
        return response.statusCode == 200
    }

    /// Attende la conclusione del lavoro con intervalli crescenti.
    public func waitForCompletion(jobID: String, progress: (@Sendable (BackendJobStatus) -> Void)? = nil, sleeper: @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }) async throws -> BackendJobStatus {
        var delay: TimeInterval = 2
        while true {
            try Task.checkCancellation()
            let current = try await RetryPolicy().run(provider: "Backend", sleeper: sleeper) { try await status(jobID: jobID) }
            progress?(current)
            if current.isFinished { return current }
            try await sleeper(delay)
            delay = min(delay * 1.5, 20)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do {
            return try Self.decoder.decode(type, from: data)
        } catch {
            throw AIServiceError.decoding("Risposta del backend non valida: \(error)")
        }
    }
}
