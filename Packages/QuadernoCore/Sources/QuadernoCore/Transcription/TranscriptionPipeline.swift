import Foundation

/// Estrae chunk audio da un file sorgente. Implementato nell'app con
/// AVFoundation (passthrough senza ricodifica quando possibile) e nei test
/// con un estrattore finto.
public protocol AudioChunkExtractor: Sendable {
    /// Bitrate stimato (bit/s) dei chunk estratti, per rispettare il limite
    /// di dimensione del provider.
    func estimatedBitrate(of source: URL) async throws -> Int
    /// Istanti di pausa trovati nelle finestre `[t - window, t + window]`
    /// attorno ai tagli ideali. Deve analizzare solo le finestre, non
    /// l'intero file, per contenere CPU e batteria.
    func silenceCandidates(in source: URL, around times: [TimeInterval], window: TimeInterval) async throws -> [TimeInterval]
    func extract(_ spec: ChunkSpec, from source: URL, into directory: URL) async throws -> AudioChunkFile
}

/// Piano salvato su disco per riprendere una trascrizione interrotta.
public struct TranscriptionPlanCheckpoint: Codable, Sendable, Equatable {
    public var sourceFingerprint: String
    public var providerID: String
    public var model: String
    public var optionsFingerprint: String
    public var duration: TimeInterval
    public var chunks: [ChunkSpec]
    public var createdAt: Date

    public init(sourceFingerprint: String, providerID: String, model: String, optionsFingerprint: String, duration: TimeInterval, chunks: [ChunkSpec], createdAt: Date = Date()) {
        self.sourceFingerprint = sourceFingerprint
        self.providerID = providerID
        self.model = model
        self.optionsFingerprint = optionsFingerprint
        self.duration = duration
        self.chunks = chunks
        self.createdAt = createdAt
    }
}

public protocol TranscriptionCheckpointStore: Sendable {
    func loadPlan() throws -> TranscriptionPlanCheckpoint?
    func savePlan(_ plan: TranscriptionPlanCheckpoint) throws
    func loadResult(chunk index: Int) throws -> ChunkTranscription?
    func saveResult(_ result: ChunkTranscription, chunk index: Int) throws
    func reset() throws
}

/// Checkpoint su file JSON con scritture atomiche: `plan.json` e
/// `chunk-0001.json`. Anche il gestore dei trasferimenti in background
/// dell'app scrive qui i risultati, così sopravvivono alla sospensione.
public struct FileTranscriptionCheckpointStore: TranscriptionCheckpointStore {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    private var planURL: URL { directory.appendingPathComponent("plan.json") }

    public func resultURL(chunk index: Int) -> URL {
        directory.appendingPathComponent(String(format: "chunk-%04d.json", index))
    }

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    public func loadPlan() throws -> TranscriptionPlanCheckpoint? {
        guard FileManager.default.fileExists(atPath: planURL.path) else { return nil }
        return try Self.decoder.decode(TranscriptionPlanCheckpoint.self, from: Data(contentsOf: planURL))
    }

    public func savePlan(_ plan: TranscriptionPlanCheckpoint) throws {
        try ensureDirectory()
        try Self.encoder.encode(plan).write(to: planURL, options: .atomic)
    }

    public func loadResult(chunk index: Int) throws -> ChunkTranscription? {
        let url = resultURL(chunk: index)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Self.decoder.decode(ChunkTranscription.self, from: Data(contentsOf: url))
    }

    public func saveResult(_ result: ChunkTranscription, chunk index: Int) throws {
        try ensureDirectory()
        try Self.encoder.encode(result).write(to: resultURL(chunk: index), options: .atomic)
    }

    public func reset() throws {
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }
}

public struct TranscriptionProgress: Sendable, Equatable {
    public enum Phase: String, Sendable {
        case planning, extracting, uploading, merging, completed
    }
    public var phase: Phase
    public var completedChunks: Int
    public var totalChunks: Int

    public var fraction: Double {
        totalChunks == 0 ? 0 : Double(completedChunks) / Double(totalChunks)
    }
}

public enum TranscriptionPipelineError: Error, Equatable, Sendable {
    case chunksFailed([Int: AIServiceError])
    case incompleteCoverage([ClosedRange<TimeInterval>])
    case sourceMissing
}

/// Orchestratore della trascrizione di file lunghi: pianifica i chunk,
/// li estrae, li invia, salva ogni risultato appena disponibile, ricompone e
/// verifica la copertura. Un nuovo avvio riprende dai chunk mancanti.
public struct TranscriptionPipeline: Sendable {
    public var provider: TranscriptionProvider
    public var extractor: AudioChunkExtractor
    public var store: TranscriptionCheckpointStore
    public var retryPolicy: RetryPolicy
    public var targetChunkDuration: TimeInterval
    public var overlap: TimeInterval
    public var maxConcurrentUploads: Int
    public var workingDirectory: URL

    public init(provider: TranscriptionProvider, extractor: AudioChunkExtractor, store: TranscriptionCheckpointStore, workingDirectory: URL, retryPolicy: RetryPolicy = RetryPolicy(), targetChunkDuration: TimeInterval = 6 * 60, overlap: TimeInterval = 4, maxConcurrentUploads: Int = 2) {
        self.provider = provider
        self.extractor = extractor
        self.store = store
        self.workingDirectory = workingDirectory
        self.retryPolicy = retryPolicy
        self.targetChunkDuration = targetChunkDuration
        self.overlap = overlap
        self.maxConcurrentUploads = max(1, maxConcurrentUploads)
    }

    public static func optionsFingerprint(_ options: TranscriptionOptions) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(options)) ?? Data()
        return String(format: "%08x", StableHash.fnv1a32(data))
    }

    /// Prepara (o riprende) il piano dei chunk.
    public func preparePlan(source: URL, sourceFingerprint: String, duration: TimeInterval, options: TranscriptionOptions) async throws -> TranscriptionPlanCheckpoint {
        let optionsFingerprint = Self.optionsFingerprint(options)
        if let existing = try? store.loadPlan(),
           existing.sourceFingerprint == sourceFingerprint,
           existing.providerID == provider.id,
           existing.model == provider.model,
           existing.optionsFingerprint == optionsFingerprint {
            return existing
        }
        try store.reset()
        let capabilities = provider.capabilities
        var maxDuration = capabilities.maxChunkDuration ?? 20 * 60
        if let limit = capabilities.maxUploadBytes {
            let bitrate = try await extractor.estimatedBitrate(of: source)
            maxDuration = min(maxDuration, ChunkPlanConfiguration.maxDuration(forByteLimit: limit, bitrate: bitrate, providerMaxDuration: capabilities.maxChunkDuration))
        }
        let configuration = ChunkPlanConfiguration(targetDuration: min(targetChunkDuration, maxDuration - overlap), maxDuration: maxDuration, overlap: overlap)
        // Prima pianificazione senza pause per conoscere i tagli ideali, poi
        // analisi mirata delle sole finestre attorno ai tagli.
        let rough = try ChunkPlanner.plan(duration: duration, configuration: configuration)
        let idealCuts = rough.dropLast().map(\.coreEnd)
        var silences: [TimeInterval] = []
        if !idealCuts.isEmpty {
            silences = (try? await extractor.silenceCandidates(in: source, around: idealCuts, window: configuration.silenceSearchWindow)) ?? []
        }
        let chunks = try ChunkPlanner.plan(duration: duration, silences: silences, configuration: configuration)
        let plan = TranscriptionPlanCheckpoint(sourceFingerprint: sourceFingerprint, providerID: provider.id, model: provider.model, optionsFingerprint: optionsFingerprint, duration: duration, chunks: chunks)
        try store.savePlan(plan)
        return plan
    }

    public func run(
        source: URL,
        sourceFingerprint: String,
        duration: TimeInterval,
        options: TranscriptionOptions,
        progress: (@Sendable (TranscriptionProgress) -> Void)? = nil
    ) async throws -> MergedTranscript {
        guard FileManager.default.fileExists(atPath: source.path) else { throw TranscriptionPipelineError.sourceMissing }
        progress?(TranscriptionProgress(phase: .planning, completedChunks: 0, totalChunks: 0))
        let plan = try await preparePlan(source: source, sourceFingerprint: sourceFingerprint, duration: duration, options: options)
        let gaps = ChunkPlanner.coverageGaps(of: plan.chunks, duration: duration)
        guard gaps.isEmpty else { throw TranscriptionPipelineError.incompleteCoverage(gaps) }

        let pending = plan.chunks.filter { (try? store.loadResult(chunk: $0.index)) == nil }
        let alreadyDone = plan.chunks.count - pending.count
        progress?(TranscriptionProgress(phase: .uploading, completedChunks: alreadyDone, totalChunks: plan.chunks.count))

        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        let counter = ProgressCounter(start: alreadyDone)
        var failures: [Int: AIServiceError] = [:]

        try await withThrowingTaskGroup(of: (Int, AIServiceError?).self) { group in
            var iterator = pending.makeIterator()
            var running = 0
            func launchNext() {
                guard let spec = iterator.next() else { return }
                running += 1
                group.addTask {
                    do {
                        try Task.checkCancellation()
                        let file = try await extractor.extract(spec, from: source, into: workingDirectory)
                        defer { try? FileManager.default.removeItem(at: file.url) }
                        let result = try await retryPolicy.run(provider: provider.displayName) {
                            try await provider.transcribe(chunk: file, options: options)
                        }
                        try store.saveResult(result, chunk: spec.index)
                        let done = await counter.increment()
                        progress?(TranscriptionProgress(phase: .uploading, completedChunks: done, totalChunks: plan.chunks.count))
                        return (spec.index, nil)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        let mapped = AIServiceError.from(error, provider: provider.displayName)
                        if mapped == .cancelled { throw CancellationError() }
                        return (spec.index, mapped)
                    }
                }
            }
            for _ in 0..<maxConcurrentUploads { launchNext() }
            while running > 0, let (index, error) = try await group.next() {
                running -= 1
                if let error {
                    failures[index] = error
                    // Credenziali errate o quota esaurita: inutile proseguire.
                    if case .invalidCredentials = error { group.cancelAll(); break }
                    if case .quotaExceeded = error { group.cancelAll(); break }
                    if case .missingCredentials = error { group.cancelAll(); break }
                }
                launchNext()
            }
        }

        guard failures.isEmpty else { throw TranscriptionPipelineError.chunksFailed(failures) }

        progress?(TranscriptionProgress(phase: .merging, completedChunks: plan.chunks.count, totalChunks: plan.chunks.count))
        var results: [(spec: ChunkSpec, transcription: ChunkTranscription)] = []
        for spec in plan.chunks {
            guard let result = try store.loadResult(chunk: spec.index) else {
                throw TranscriptionPipelineError.chunksFailed([spec.index: .decoding("Risultato del chunk mancante")])
            }
            results.append((spec, result))
        }
        let merged = try TranscriptMerger.merge(results: results, plannedChunks: plan.chunks, totalDuration: duration)
        guard merged.report.isComplete else { throw TranscriptionPipelineError.incompleteCoverage(merged.report.coverageGaps) }
        progress?(TranscriptionProgress(phase: .completed, completedChunks: plan.chunks.count, totalChunks: plan.chunks.count))
        return merged
    }
}

actor ProgressCounter {
    private var value: Int
    init(start: Int) { value = start }
    func increment() -> Int {
        value += 1
        return value
    }
}

/// Hash stabile fra esecuzioni (a differenza di `Hasher`).
public enum StableHash {
    public static func fnv1a32(_ data: Data) -> UInt32 {
        var hash: UInt32 = 2_166_136_261
        for byte in data {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return hash
    }

    public static func fnv1a32(_ string: String) -> UInt32 {
        fnv1a32(Data(string.utf8))
    }
}
