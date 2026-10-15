import XCTest
@testable import QuadernoCore

final class TranscriptMergerTests: XCTestCase {
    func testTextOnlyChunksAreDedupedAndInterpolated() throws {
        let specs = try ChunkPlanner.plan(duration: 720, configuration: ChunkPlanConfiguration(targetDuration: 360, overlap: 4))
        XCTAssertEqual(specs.count, 2)
        let first = ChunkTranscription(text: "Oggi parliamo del Bauhaus. La scuola nasce a Weimar nel 1919 e il suo fondatore è Walter Gropius.", model: "m", providerID: "p")
        let second = ChunkTranscription(text: "fondatore è Walter Gropius. Nel 1925 la scuola si sposta a Dessau.", model: "m", providerID: "p")
        let merged = try TranscriptMerger.merge(results: [(specs[0], first), (specs[1], second)], plannedChunks: specs, totalDuration: 720)
        XCTAssertEqual(merged.fullText, "Oggi parliamo del Bauhaus. La scuola nasce a Weimar nel 1919 e il suo fondatore è Walter Gropius. Nel 1925 la scuola si sposta a Dessau.")
        XCTAssertTrue(merged.report.isComplete)
        XCTAssertTrue(merged.report.unresolvedOverlapChunks.isEmpty)
        XCTAssertEqual(merged.report.precision, .interpolated)
        // Tempi monotoni, entro i confini del chunk.
        for (a, b) in zip(merged.segments, merged.segments.dropFirst()) {
            XCTAssertLessThanOrEqual(a.end, b.start + 1e-9)
        }
        XCTAssertEqual(merged.segments.first?.start, 0)
        XCTAssertEqual(merged.segments.last?.end ?? 0, 720, accuracy: 1e-6)
        XCTAssertEqual(merged.segments.map(\.index), Array(0..<merged.segments.count))
    }

    func testTimestampedSegmentsUseMidpointOwnership() throws {
        let specs = try ChunkPlanner.plan(duration: 720, configuration: ChunkPlanConfiguration(targetDuration: 360, overlap: 4))
        let first = ChunkTranscription(text: "", segments: [
            TimedText(start: 0, end: 10, text: "Prima frase.", speaker: "A"),
            TimedText(start: 350, end: 358, text: "Frase prima del confine.", speaker: "A")
        ], model: "m", providerID: "p")
        // Il secondo chunk inizia a 356 (4 s di sovrapposizione).
        let second = ChunkTranscription(text: "", segments: [
            TimedText(start: 0, end: 2, text: "confine.", speaker: "A"),     // 356–358: punto medio < 360 → scartato
            TimedText(start: 5, end: 12, text: "Dopo il confine.", speaker: "B")
        ], model: "m", providerID: "p")
        let merged = try TranscriptMerger.merge(results: [(specs[0], first), (specs[1], second)], plannedChunks: specs, totalDuration: 720)
        XCTAssertEqual(merged.segments.map(\.text), ["Prima frase.", "Frase prima del confine.", "Dopo il confine."])
        XCTAssertEqual(merged.segments[2].start, 361, accuracy: 1e-9)
        XCTAssertEqual(merged.segments[2].speaker, "B")
        XCTAssertEqual(merged.report.precision, .exact)
    }

    func testMissingChunkThrows() throws {
        let specs = try ChunkPlanner.plan(duration: 720, configuration: ChunkPlanConfiguration(targetDuration: 360))
        XCTAssertThrowsError(try TranscriptMerger.merge(results: [(specs[0], ChunkTranscription(text: "x", model: "m", providerID: "p"))], plannedChunks: specs, totalDuration: 720)) { error in
            XCTAssertEqual(error as? TranscriptMergeError, .missingChunks([1]))
        }
    }

    func testSilentChunkIsReportedNotDropped() throws {
        let specs = try ChunkPlanner.plan(duration: 720, configuration: ChunkPlanConfiguration(targetDuration: 360))
        let merged = try TranscriptMerger.merge(results: [
            (specs[0], ChunkTranscription(text: "Contenuto reale della lezione.", model: "m", providerID: "p")),
            (specs[1], ChunkTranscription(text: "Sottotitoli creati dalla comunità Amara.org", model: "m", providerID: "p"))
        ], plannedChunks: specs, totalDuration: 720)
        XCTAssertEqual(merged.fullText, "Contenuto reale della lezione.")
        XCTAssertEqual(merged.report.emptyChunks, [1])
        XCTAssertEqual(merged.report.removedSuspectPhrases.count, 1)
    }

    func testUnresolvedOverlapIsFlagged() throws {
        let specs = try ChunkPlanner.plan(duration: 720, configuration: ChunkPlanConfiguration(targetDuration: 360, overlap: 4))
        let merged = try TranscriptMerger.merge(results: [
            (specs[0], ChunkTranscription(text: "Una frase completamente diversa dalla successiva qui.", model: "m", providerID: "p")),
            (specs[1], ChunkTranscription(text: "Altro testo senza parole in comune all'inizio.", model: "m", providerID: "p"))
        ], plannedChunks: specs, totalDuration: 720)
        XCTAssertEqual(merged.report.unresolvedOverlapChunks, [1])
    }

    func testSentenceSplitting() {
        XCTAssertEqual(TextTokenizer.sentences("Prima frase. Seconda frase? «Terza» frase! 1919 è l'anno."),
                       ["Prima frase.", "Seconda frase?", "«Terza» frase!", "1919 è l'anno."])
        XCTAssertEqual(TextTokenizer.sentences("Es. abbreviazioni come ecc. non spezzano se seguite da minuscola."),
                       ["Es. abbreviazioni come ecc. non spezzano se seguite da minuscola."])
    }
}

final class OpenAITranscriptionProviderTests: XCTestCase {
    func makeChunk(directory: URL) throws -> AudioChunkFile {
        let url = directory.appendingPathComponent("c.m4a")
        try Data("AUDIO".utf8).write(to: url)
        return AudioChunkFile(spec: ChunkSpec(index: 3, coreStart: 0, coreEnd: 10, extractStart: 0, extractEnd: 10, endsOnSilence: true), url: url, byteSize: 5)
    }

    func formText(_ provider: OpenAITranscriptionProvider, options: TranscriptionOptions, directory: URL) throws -> String {
        let form = provider.makeForm(chunk: try makeChunk(directory: directory), options: options)
        return String(decoding: try form.encodedData(), as: UTF8.self)
    }

    func testGptTranscribeFormUsesLanguagesKeywordsAndPrompt() throws {
        let directory = makeTemporaryDirectory()
        let provider = OpenAITranscriptionProvider(apiKey: "k", model: .gptTranscribe, transport: MockTransport { _, _ in jsonResponse([:]) })
        let text = try formText(provider, options: TranscriptionOptions(languages: ["it", "en"], prompt: "Lezione di Storia del Design", keywords: ["Bauhaus", "Walter <Gropius>", "bauhaus", "Le\nCorbusier"]), directory: directory)
        XCTAssertTrue(text.contains("name=\"model\"\r\n\r\ngpt-transcribe"))
        XCTAssertTrue(text.contains("name=\"response_format\"\r\n\r\njson"))
        XCTAssertTrue(text.contains("name=\"languages[]\"\r\n\r\nit"))
        XCTAssertTrue(text.contains("name=\"languages[]\"\r\n\r\nen"))
        XCTAssertTrue(text.contains("name=\"keywords[]\"\r\n\r\nBauhaus"))
        XCTAssertTrue(text.contains("name=\"keywords[]\"\r\n\r\nWalter Gropius"), "< e > vengono rimossi")
        XCTAssertTrue(text.contains("name=\"keywords[]\"\r\n\r\nLe Corbusier"), "Gli a capo diventano spazi")
        XCTAssertEqual(text.components(separatedBy: "name=\"keywords[]\"").count - 1, 3, "Duplicati rimossi")
        XCTAssertFalse(text.contains("name=\"language\""), "Non inviare language insieme a languages")
        XCTAssertTrue(text.contains("filename=\"chunk-3.m4a\""))
    }

    func testDiarizeFormRequiresChunkingStrategyAndNoPrompt() throws {
        let directory = makeTemporaryDirectory()
        let provider = OpenAITranscriptionProvider(apiKey: "k", model: .diarize, transport: MockTransport { _, _ in jsonResponse([:]) })
        let text = try formText(provider, options: TranscriptionOptions(languages: ["it"], prompt: "contesto", keywords: ["Bauhaus"]), directory: directory)
        XCTAssertTrue(text.contains("diarized_json"))
        XCTAssertTrue(text.contains("name=\"chunking_strategy\"\r\n\r\nauto"))
        XCTAssertFalse(text.contains("name=\"prompt\""))
        XCTAssertTrue(text.contains("name=\"language\"\r\n\r\nit"))
        XCTAssertTrue(provider.capabilities.returnsSegmentTimestamps)
    }

    func testWhisperFormRequestsSegments() throws {
        let directory = makeTemporaryDirectory()
        let provider = OpenAITranscriptionProvider(apiKey: "k", model: .whisper, transport: MockTransport { _, _ in jsonResponse([:]) })
        let text = try formText(provider, options: TranscriptionOptions(languages: ["it"], keywords: ["Gropius"]), directory: directory)
        XCTAssertTrue(text.contains("verbose_json"))
        XCTAssertTrue(text.contains("name=\"timestamp_granularities[]\"\r\n\r\nsegment"))
        XCTAssertTrue(text.contains("name=\"prompt\"\r\n\r\nGropius"))
    }

    func testParsesAllResponseShapes() throws {
        let plain = try OpenAITranscriptionProvider.parse(try JSONSerialization.data(withJSONObject: ["text": "Ciao", "languages": [["code": "it"]]]), model: .gptTranscribe)
        XCTAssertEqual(plain.text, "Ciao")
        XCTAssertEqual(plain.detectedLanguages, ["it"])
        XCTAssertNil(plain.segments)

        let diarized = try OpenAITranscriptionProvider.parse(try JSONSerialization.data(withJSONObject: ["text": "A B", "segments": [["speaker": "A", "start": 0.5, "end": 2, "text": " Buongiorno "], ["speaker": "B", "start": 2, "end": 3, "text": "Domanda"]]]), model: .diarize)
        XCTAssertEqual(diarized.segments?.count, 2)
        XCTAssertEqual(diarized.segments?.first, TimedText(start: 0.5, end: 2, text: "Buongiorno", speaker: "A"))

        let verbose = try OpenAITranscriptionProvider.parse(try JSONSerialization.data(withJSONObject: ["text": "x", "language": "italian", "segments": [["id": 0, "start": 0, "end": 4, "text": "x"]]]), model: .whisper)
        XCTAssertEqual(verbose.detectedLanguages, ["italian"])
        XCTAssertEqual(verbose.segments?.first?.end, 4)

        XCTAssertThrowsError(try OpenAITranscriptionProvider.parse(Data("not json".utf8), model: .gptTranscribe))
    }

    func testTranscribeSendsAuthorizedMultipartAndMapsErrors() async throws {
        let directory = makeTemporaryDirectory()
        let transport = MockTransport { request, body in
            XCTAssertEqual(request.headers["Authorization"], "Bearer sk-test")
            XCTAssertTrue(request.headers["Content-Type"]?.hasPrefix("multipart/form-data; boundary=") == true)
            XCTAssertEqual(request.url.absoluteString, "https://api.openai.com/v1/audio/transcriptions")
            XCTAssertTrue(String(decoding: body, as: UTF8.self).contains("AUDIO"))
            return jsonResponse(["text": "Buongiorno a tutti."])
        }
        let provider = OpenAITranscriptionProvider(apiKey: "sk-test", transport: transport, temporaryDirectory: directory)
        let result = try await provider.transcribe(chunk: try makeChunk(directory: directory), options: TranscriptionOptions())
        XCTAssertEqual(result.text, "Buongiorno a tutti.")
        // Il file multipart temporaneo viene rimosso.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".multipart") }
        XCTAssertTrue(leftovers.isEmpty)

        transport.handler = { _, _ in jsonResponse(["error": ["message": "Incorrect API key"]], status: 401) }
        do {
            _ = try await provider.transcribe(chunk: try makeChunk(directory: directory), options: TranscriptionOptions())
            XCTFail("Doveva fallire")
        } catch {
            XCTAssertEqual(error as? AIServiceError, .invalidCredentials(provider: "OpenAI"))
        }
    }

    func testMissingKeyAndOversizedChunk() async throws {
        let directory = makeTemporaryDirectory()
        let transport = MockTransport { _, _ in jsonResponse(["text": "x"]) }
        let noKey = OpenAITranscriptionProvider(apiKey: "", transport: transport)
        var chunk = try makeChunk(directory: directory)
        await XCTAssertThrowsErrorAsync(try await noKey.transcribe(chunk: chunk, options: TranscriptionOptions())) { XCTAssertEqual($0 as? AIServiceError, .missingCredentials(provider: "OpenAI")) }
        chunk.byteSize = 26 * 1024 * 1024
        let provider = OpenAITranscriptionProvider(apiKey: "k", transport: transport)
        await XCTAssertThrowsErrorAsync(try await provider.transcribe(chunk: chunk, options: TranscriptionOptions())) { XCTAssertEqual($0 as? AIServiceError, .payloadTooLarge) }
        XCTAssertEqual(transport.requestCount, 0)
    }

    func testCostEstimate() {
        let provider = OpenAITranscriptionProvider(apiKey: "k", transport: MockTransport { _, _ in jsonResponse([:]) })
        XCTAssertEqual(provider.estimateCost(durationSeconds: 90 * 60)?.amountUSD ?? 0, 90 * 0.0045, accuracy: 1e-9)
    }
}

final class ErrorMappingTests: XCTestCase {
    func testHTTPErrorMapping() {
        func map(_ status: Int, _ message: String, headers: [String: String] = [:]) -> AIServiceError {
            AIServiceError.fromHTTP(jsonResponse(["error": ["message": message]], status: status, headers: headers), provider: "X")
        }
        XCTAssertEqual(map(401, "bad key"), .invalidCredentials(provider: "X"))
        XCTAssertEqual(map(429, "Rate limit reached", headers: ["retry-after": "7"]), .rateLimited(retryAfter: 7))
        XCTAssertEqual(map(429, "You exceeded your current quota"), .quotaExceeded(message: "You exceeded your current quota"))
        XCTAssertEqual(map(400, "Your credit balance is too low"), .quotaExceeded(message: "Your credit balance is too low"))
        XCTAssertEqual(map(529, "Overloaded"), .serverUnavailable(status: 529))
        XCTAssertEqual(map(413, "too big"), .payloadTooLarge)
        XCTAssertTrue(map(503, "x").isRetryable)
        XCTAssertFalse(map(400, "x").isRetryable)
        XCTAssertFalse(map(429, "insufficient_quota: check billing").isRetryable)
    }

    func testURLErrorsMapToNetworkOrTimeout() {
        XCTAssertEqual(AIServiceError.from(URLError(.timedOut), provider: "X"), .timeout)
        XCTAssertEqual(AIServiceError.from(URLError(.cancelled), provider: "X"), .cancelled)
        XCTAssertEqual(AIServiceError.from(CancellationError(), provider: "X"), .cancelled)
        if case .network = AIServiceError.from(URLError(.notConnectedToInternet), provider: "X") {} else { XCTFail() }
    }
}

final class RetryPolicyTests: XCTestCase {
    func testDelaysAreExponentialAndCapped() {
        let policy = RetryPolicy(maxAttempts: 6, baseDelay: 2, maxDelay: 10, jitter: 0)
        XCTAssertEqual(policy.delay(forAttempt: 1), 2)
        XCTAssertEqual(policy.delay(forAttempt: 2), 4)
        XCTAssertEqual(policy.delay(forAttempt: 3), 8)
        XCTAssertEqual(policy.delay(forAttempt: 4), 10)
        XCTAssertEqual(policy.delay(forAttempt: 1, retryAfter: 30), 10)
        XCTAssertEqual(policy.delay(forAttempt: 1, retryAfter: 5), 5)
    }

    func testRetriesOnlyTransientErrors() async throws {
        let counter = Counter()
        let policy = RetryPolicy(maxAttempts: 3, baseDelay: 0, jitter: 0)
        let value = try await policy.run(provider: "X", sleeper: { _ in }) {
            if await counter.next() < 3 { throw AIServiceError.serverUnavailable(status: 503) }
            return 42
        }
        XCTAssertEqual(value, 42)
        let attempts = await counter.value
        XCTAssertEqual(attempts, 3)

        let counter2 = Counter()
        await XCTAssertThrowsErrorAsync(try await policy.run(provider: "X", sleeper: { _ in }) { () async throws -> Int in
            _ = await counter2.next()
            throw AIServiceError.invalidCredentials(provider: "X")
        })
        let attempts2 = await counter2.value
        XCTAssertEqual(attempts2, 1, "Credenziali errate: nessun nuovo tentativo")
    }
}

actor Counter {
    var value = 0
    func next() -> Int {
        value += 1
        return value
    }
}

func XCTAssertThrowsErrorAsync<T>(_ expression: @autoclosure () async throws -> T, file: StaticString = #filePath, line: UInt = #line, _ handler: (Error) -> Void = { _ in }) async {
    do {
        _ = try await expression()
        XCTFail("Era atteso un errore", file: file, line: line)
    } catch {
        handler(error)
    }
}
