import XCTest
@testable import QuadernoCore

final class TranscriptionPipelineTests: XCTestCase {
    func makeSource(_ directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("lezione.m4a")
        try Data("audio".utf8).write(to: url)
        return url
    }

    func testFullRunMergesAllChunksAndCleansUp() async throws {
        let directory = makeTemporaryDirectory()
        let source = try makeSource(directory)
        let provider = MockTranscriptionProvider()
        let extractor = MockExtractor(silences: [355])
        let store = FileTranscriptionCheckpointStore(directory: directory.appendingPathComponent("checkpoints"))
        let pipeline = TranscriptionPipeline(provider: provider, extractor: extractor, store: store, workingDirectory: directory.appendingPathComponent("work"), retryPolicy: RetryPolicy(maxAttempts: 1), targetChunkDuration: 360)
        let progress = ProgressRecorder()
        let merged = try await pipeline.run(source: source, sourceFingerprint: "f1", duration: 1500, options: TranscriptionOptions(), progress: { progress.record($0) })
        let plan = try XCTUnwrap(try store.loadPlan())
        XCTAssertEqual(plan.chunks.count, 5)
        XCTAssertEqual(plan.chunks[0].coreEnd, 355, "Taglio sulla pausa rilevata")
        XCTAssertEqual(provider.calls.sorted(), Array(0..<5), "Ogni chunk inviato una sola volta")
        XCTAssertTrue(merged.report.isComplete)
        XCTAssertTrue(merged.fullText.contains("Testo del chunk 0."))
        XCTAssertTrue(merged.fullText.contains("Testo del chunk 4."))
        XCTAssertEqual(extractor.silenceQueries.count, 1, "Pause cercate solo attorno ai tagli")
        XCTAssertEqual(progress.phases.last, .completed)
        // I file dei chunk estratti vengono eliminati dopo l'invio.
        let work = try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("work").path)
        XCTAssertTrue(work.isEmpty)
    }

    func testFailedChunkCanBeResumedWithoutRepeatingCompletedOnes() async throws {
        let directory = makeTemporaryDirectory()
        let source = try makeSource(directory)
        let provider = MockTranscriptionProvider()
        provider.failures = [2: .serverUnavailable(status: 503)]
        let store = FileTranscriptionCheckpointStore(directory: directory.appendingPathComponent("checkpoints"))
        let pipeline = TranscriptionPipeline(provider: provider, extractor: MockExtractor(), store: store, workingDirectory: directory.appendingPathComponent("work"), retryPolicy: RetryPolicy(maxAttempts: 2, baseDelay: 0, jitter: 0), targetChunkDuration: 360, maxConcurrentUploads: 1)

        do {
            _ = try await pipeline.run(source: source, sourceFingerprint: "f1", duration: 1500, options: TranscriptionOptions())
            XCTFail("Doveva fallire il chunk 2")
        } catch let error as TranscriptionPipelineError {
            guard case .chunksFailed(let failures) = error else { return XCTFail("Errore inatteso \(error)") }
            XCTAssertEqual(Array(failures.keys), [2])
        }
        XCTAssertEqual(provider.calls.filter { $0 == 2 }.count, 2, "Due tentativi per errore transitorio")
        XCTAssertNotNil(try store.loadResult(chunk: 0))
        XCTAssertNil(try store.loadResult(chunk: 2))

        // Seconda esecuzione: il servizio è tornato disponibile.
        provider.failures = [:]
        let callsBefore = provider.calls.count
        let merged = try await pipeline.run(source: source, sourceFingerprint: "f1", duration: 1500, options: TranscriptionOptions())
        XCTAssertEqual(Array(provider.calls.dropFirst(callsBefore)), [2], "Solo il chunk mancante viene ritrasmesso")
        XCTAssertTrue(merged.report.isComplete)
    }

    func testInvalidCredentialsStopEarly() async throws {
        let directory = makeTemporaryDirectory()
        let source = try makeSource(directory)
        let provider = MockTranscriptionProvider()
        provider.failures = Dictionary(uniqueKeysWithValues: (0..<10).map { ($0, AIServiceError.invalidCredentials(provider: "Mock")) })
        let pipeline = TranscriptionPipeline(provider: provider, extractor: MockExtractor(), store: FileTranscriptionCheckpointStore(directory: directory.appendingPathComponent("c")), workingDirectory: directory.appendingPathComponent("w"), retryPolicy: RetryPolicy(maxAttempts: 3, baseDelay: 0), targetChunkDuration: 360, maxConcurrentUploads: 1)
        await XCTAssertThrowsErrorAsync(try await pipeline.run(source: source, sourceFingerprint: "f", duration: 3000, options: TranscriptionOptions()))
        XCTAssertEqual(provider.calls.count, 1, "Nessun altro chunk inviato con credenziali errate")
    }

    func testChangedOptionsInvalidatePlan() async throws {
        let directory = makeTemporaryDirectory()
        let source = try makeSource(directory)
        let provider = MockTranscriptionProvider()
        let store = FileTranscriptionCheckpointStore(directory: directory.appendingPathComponent("c"))
        let pipeline = TranscriptionPipeline(provider: provider, extractor: MockExtractor(), store: store, workingDirectory: directory.appendingPathComponent("w"), targetChunkDuration: 360)
        _ = try await pipeline.run(source: source, sourceFingerprint: "f", duration: 800, options: TranscriptionOptions(keywords: ["A"]))
        let firstCount = provider.calls.count
        _ = try await pipeline.run(source: source, sourceFingerprint: "f", duration: 800, options: TranscriptionOptions(keywords: ["A"]))
        XCTAssertEqual(provider.calls.count, firstCount, "Stesse opzioni: tutto già in checkpoint")
        _ = try await pipeline.run(source: source, sourceFingerprint: "f", duration: 800, options: TranscriptionOptions(keywords: ["B"]))
        XCTAssertEqual(provider.calls.count, firstCount * 2, "Glossario cambiato: nuova trascrizione")
    }

    func testChunkSizeRespectsProviderByteLimit() async throws {
        let directory = makeTemporaryDirectory()
        let source = try makeSource(directory)
        let provider = MockTranscriptionProvider()
        provider.capabilities.maxUploadBytes = 1_000_000 // ~1 MB
        let extractor = MockExtractor(bitrate: 64_000)
        let pipeline = TranscriptionPipeline(provider: provider, extractor: extractor, store: FileTranscriptionCheckpointStore(directory: directory.appendingPathComponent("c")), workingDirectory: directory.appendingPathComponent("w"), targetChunkDuration: 360)
        let plan = try await pipeline.preparePlan(source: source, sourceFingerprint: "f", duration: 1200, options: TranscriptionOptions())
        for chunk in plan.chunks {
            XCTAssertLessThanOrEqual(Double(chunk.extractDuration) * 8000, 1_000_000, "Ogni chunk deve stare nel limite in byte")
        }
        XCTAssertTrue(ChunkPlanner.coverageGaps(of: plan.chunks, duration: 1200).isEmpty)
    }

    func testMissingSourceFails() async {
        let directory = makeTemporaryDirectory()
        let pipeline = TranscriptionPipeline(provider: MockTranscriptionProvider(), extractor: MockExtractor(), store: FileTranscriptionCheckpointStore(directory: directory), workingDirectory: directory)
        await XCTAssertThrowsErrorAsync(try await pipeline.run(source: directory.appendingPathComponent("assente.m4a"), sourceFingerprint: "f", duration: 10, options: TranscriptionOptions())) {
            XCTAssertEqual($0 as? TranscriptionPipelineError, .sourceMissing)
        }
    }
}

final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var phases: [TranscriptionProgress.Phase] = []
    func record(_ progress: TranscriptionProgress) {
        lock.lock()
        phases.append(progress.phase)
        lock.unlock()
    }
}

final class JobStateTests: XCTestCase {
    func testTerminalStatesCannotBeReopened() {
        XCTAssertFalse(ProcessingJobState.cancelled.canTransition(to: .completed))
        XCTAssertFalse(ProcessingJobState.completed.canTransition(to: .generating))
        XCTAssertTrue(ProcessingJobState.failed.canTransition(to: .pending))
        XCTAssertTrue(ProcessingJobState.waiting.canTransition(to: .uploading))
        XCTAssertFalse(ProcessingJobState.failed.canTransition(to: .completed), "Un lavoro fallito non può risultare completato senza rieseguirlo")
        XCTAssertTrue(ProcessingJobState.generating.canTransition(to: .completed))
    }

    func testCostEstimateIncludesBothProviders() {
        let generation = ScriptedTextProvider { _ in result("") }
        let estimate = CostEstimator.estimate(durationSeconds: 90 * 60, transcription: MockTranscriptionProvider(), generation: generation, mode: .integrale, verify: true)
        XCTAssertEqual(estimate.transcriptionUSD ?? 0, 0.45, accuracy: 1e-9)
        XCTAssertNotNil(estimate.generationUSD)
        XCTAssertGreaterThan(estimate.estimatedOutputTokens, 15_000, "Una lezione di 90 minuti produce un testo lungo")
        XCTAssertFalse(estimate.notes.isEmpty)
    }
}
