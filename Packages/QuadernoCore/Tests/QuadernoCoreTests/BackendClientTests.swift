import XCTest
@testable import QuadernoCore

final class BackendClientTests: XCTestCase {
    let base = URL(string: "https://backend.example/")!

    func request() -> BackendJobRequest {
        BackendJobRequest(idempotencyKey: "job-1", mode: .integrale, subjectName: "Storia del Design", lessonTitle: "Lezione 1", lessonDate: Date(timeIntervalSince1970: 1_760_000_000), documentLanguage: "italiano", transcriptionLanguages: ["it"], glossary: ["Bauhaus"], instructions: nil, transcriptionModel: "gpt-transcribe", generationProvider: "anthropic", generationModel: "claude-opus-5-5", includeGeneration: true)
    }

    func testCreateUploadStartAndPoll() async throws {
        let statuses = ["created", "uploaded", "queued", "running", "completed"]
        let counter = LockedCounter()
        let transport = MockTransport { request, body in
            XCTAssertEqual(request.headers["Authorization"], "Bearer tok")
            switch (request.method, request.url.path) {
            case ("POST", "/v1/jobs"):
                XCTAssertEqual(request.headers["Idempotency-Key"], "job-1")
                let json = try JSONSerialization.jsonObject(with: body) as! [String: Any]
                XCTAssertEqual(json["lessonDate"] as? String, "2025-10-09T08:53:20Z")
                XCTAssertEqual(json["mode"] as? String, "integrale")
                return jsonResponse(["id": "abc", "status": statuses[0], "progress": 0, "step": ""])
            case ("PUT", "/v1/jobs/abc/audio"):
                XCTAssertEqual(request.headers["Content-Type"], "audio/mp4")
                XCTAssertEqual(String(decoding: body, as: UTF8.self), "AUDIO")
                return jsonResponse(["id": "abc", "status": statuses[1], "progress": 0, "step": "Audio ricevuto"])
            case ("POST", "/v1/jobs/abc/start"):
                return jsonResponse(["id": "abc", "status": statuses[2], "progress": 0, "step": "In coda"])
            case ("GET", "/v1/jobs/abc"):
                let call = counter.next()
                let state = call < 2 ? "running" : "completed"
                return jsonResponse(["id": "abc", "status": state, "progress": call < 2 ? 0.5 : 1, "step": "x", "error": NSNull()])
            default:
                return jsonResponse(["detail": "?"], status: 404)
            }
        }
        let client = BackendJobClient(baseURL: base, token: "tok", transport: transport)
        let created = try await client.createJob(request())
        XCTAssertEqual(created.status, "created")
        let directory = makeTemporaryDirectory()
        let file = directory.appendingPathComponent("audio.m4a")
        try Data("AUDIO".utf8).write(to: file)
        let uploaded = try await client.uploadAudio(jobID: "abc", fileURL: file)
        XCTAssertEqual(uploaded.status, "uploaded")
        _ = try await client.startJob(jobID: "abc")
        let final = try await client.waitForCompletion(jobID: "abc", sleeper: { _ in })
        XCTAssertEqual(final.status, "completed")
        XCTAssertTrue(final.isFinished)
    }

    func testResultDecodingMatchesWorkerEncoding() throws {
        let merged = MergedTranscript(segments: [TranscriptSegmentDTO(index: 0, start: 0, end: 2, text: "Ciao", chunkIndex: 0, precision: .interpolated)], report: TranscriptMergeReport(chunkCount: 1, coverageGaps: [], unresolvedOverlapChunks: [], emptyChunks: [], removedSuspectPhrases: [], precision: .interpolated), detectedLanguages: ["it"])
        let document = GeneratedDocumentDTO(title: "T", mode: .integrale, headerMarkdown: "# T", sections: [], outline: LessonOutline(lessonTitle: "T", sections: []), promptVersion: "v", providerID: "anthropic", model: "m", usage: GenerationUsage())
        let result = BackendJobResult(transcript: merged, transcriptionProviderID: "openai", transcriptionModel: "gpt-transcribe", document: document)
        let data = try BackendJobClient.encoder.encode(result)
        let decoded = try BackendJobClient.decoder.decode(BackendJobResult.self, from: data)
        XCTAssertEqual(decoded.transcript, merged)
        XCTAssertEqual(decoded.document?.title, "T")
        // Le date con frazioni di secondo (Python) sono accettate.
        let status = try BackendJobClient.decoder.decode([String: Date].self, from: Data(#"{"d":"2026-10-15T08:00:00.123456Z"}"#.utf8))
        XCTAssertNotNil(status["d"])
    }

    func testHTTPErrorsAreMapped() async {
        let transport = MockTransport { _, _ in jsonResponse(["detail": "Token non valido"], status: 401) }
        let client = BackendJobClient(baseURL: base, token: "x", transport: transport)
        await XCTAssertThrowsErrorAsync(try await client.health()) { error in
            XCTAssertEqual(error as? AIServiceError, .invalidCredentials(provider: "Backend"))
        }
    }
}

final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    /// Restituisce il valore corrente e lo incrementa.
    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value - 1
    }
}
