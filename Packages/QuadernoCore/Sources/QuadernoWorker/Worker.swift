import Foundation
import QuadernoCore

#if os(Linux) || os(macOS)

/// File di un lavoro nella cartella condivisa con il backend FastAPI:
/// - `job.json`: richiesta (`BackendJobRequest`) + nome del file audio
/// - `status.json`: stato aggiornato dal worker (scrittura atomica)
/// - `result.json`: risultato finale (`BackendJobResult`)
/// - `checkpoints/`: checkpoint per riprendere dopo un riavvio
struct WorkerJobFile: Codable {
    var request: BackendJobRequest
    var audioFileName: String
}

struct WorkerStatus: Codable, Equatable {
    var status: String
    var progress: Double
    var step: String
    var error: String?
    var retryable: Bool
    var updatedAt: Date
}

final class StatusWriter: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var lastWrite = Date.distantPast

    init(directory: URL) {
        url = directory.appendingPathComponent("status.json")
    }

    func write(_ status: String, progress: Double, step: String, error: String? = nil, retryable: Bool = false, force: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        guard force || Date().timeIntervalSince(lastWrite) > 0.5 else { return }
        lastWrite = Date()
        let value = WorkerStatus(status: status, progress: min(1, max(0, progress)), step: step, error: error, retryable: retryable, updatedAt: Date())
        if let data = try? BackendJobClient.encoder.encode(value) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

/// Esecuzione completa di un lavoro con QuadernoCore: la stessa pipeline
/// dell'app (chunking, trascrizione, merge, scaletta, sezioni, verifica).
struct Worker {
    let directory: URL
    let environment: [String: String]

    func run() async -> Int32 {
        let status = StatusWriter(directory: directory)
        do {
            let jobData = try Data(contentsOf: directory.appendingPathComponent("job.json"))
            let job = try BackendJobClient.decoder.decode(WorkerJobFile.self, from: jobData)
            let request = job.request
            let audio = directory.appendingPathComponent(job.audioFileName)
            status.write("running", progress: 0.01, step: "Preparazione dell'audio", force: true)

            let extractor = FFmpegChunkExtractor()
            let duration = try extractor.duration(of: audio)
            let transport = URLSessionTransport()
            let openAIKey = environment["OPENAI_API_KEY"] ?? ""
            let openAIBase = URL(string: environment["OPENAI_BASE_URL"] ?? "") ?? URL(string: "https://api.openai.com/v1")!
            let provider = OpenAITranscriptionProvider(apiKey: openAIKey, model: OpenAITranscriptionModel(identifier: request.transcriptionModel.isEmpty ? "gpt-transcribe" : request.transcriptionModel), transport: transport, baseURL: openAIBase, temporaryDirectory: directory)
            let checkpoints = directory.appendingPathComponent("checkpoints", isDirectory: true)
            let pipeline = TranscriptionPipeline(
                provider: provider,
                extractor: extractor,
                store: FileTranscriptionCheckpointStore(directory: checkpoints.appendingPathComponent("transcription")),
                workingDirectory: directory.appendingPathComponent("chunks"),
                targetChunkDuration: Double(environment["CHUNK_SECONDS"] ?? "") ?? 360
            )
            let share = request.includeGeneration ? 0.4 : 0.95
            let options = TranscriptionOptions(languages: request.transcriptionLanguages, prompt: "Lezione universitaria di \(request.subjectName): \(request.lessonTitle).", keywords: request.glossary, diarize: provider.capabilities.supportsDiarization)
            let audioFingerprint = "\(job.audioFileName)-\(Int(duration * 1000))"
            let merged = try await pipeline.run(source: audio, sourceFingerprint: audioFingerprint, duration: duration, options: options) { progress in
                status.write("running", progress: 0.02 + progress.fraction * share, step: "Trascrizione: \(progress.completedChunks) di \(progress.totalChunks) parti")
            }

            var document: GeneratedDocumentDTO?
            if request.includeGeneration {
                let generation: TextGenerationProvider
                if request.generationProvider == OpenAIResponsesProvider.providerID {
                    generation = OpenAIResponsesProvider(apiKey: openAIKey, model: request.generationModel, transport: transport, baseURL: openAIBase)
                } else {
                    let base = URL(string: environment["ANTHROPIC_BASE_URL"] ?? "") ?? URL(string: "https://api.anthropic.com/v1")!
                    generation = AnthropicProvider(apiKey: environment["ANTHROPIC_API_KEY"] ?? "", model: request.generationModel.isEmpty ? AnthropicProvider.defaultModel : request.generationModel, transport: transport, baseURL: base)
                }
                var prompts = try PromptLibrary.load(from: environment["PROMPTS_DIR"].map { URL(fileURLWithPath: $0) })
                prompts.systemOverride = nil
                let engine = SbobinaturaEngine(provider: generation, prompts: prompts, store: FileSbobinaturaCheckpointStore(url: checkpoints.appendingPathComponent("generation.json")))
                let context = LessonContext(subjectName: request.subjectName, lessonTitle: request.lessonTitle, lessonDate: request.lessonDate, language: request.documentLanguage, glossary: request.glossary, userInstructions: request.instructions)
                document = try await engine.generate(segments: merged.segments, context: context, mode: request.mode) { progress in
                    let label: String
                    switch progress.phase {
                    case .writing: label = "Scrittura: sezione \(progress.currentSection + 1) di \(progress.totalSections)"
                    case .verifying: label = "Verifica: sezione \(progress.currentSection + 1) di \(progress.totalSections)"
                    case .repairing: label = "Correzione: sezione \(progress.currentSection + 1) di \(progress.totalSections)"
                    case .analyzing: label = "Analisi della lezione"
                    default: label = "Sbobinatura"
                    }
                    status.write("running", progress: 0.02 + share + progress.fraction * (0.97 - share), step: label)
                }
            }

            let result = BackendJobResult(transcript: merged, transcriptionProviderID: provider.id, transcriptionModel: provider.model, document: document)
            try BackendJobClient.encoder.encode(result).write(to: directory.appendingPathComponent("result.json"), options: .atomic)
            status.write("completed", progress: 1, step: "Completato", force: true)
            return 0
        } catch {
            let (message, retryable) = Self.describe(error)
            status.write("failed", progress: 0, step: "Non riuscito", error: message, retryable: retryable, force: true)
            FileHandle.standardError.write(Data("Errore: \(message)\n".utf8))
            return 1
        }
    }

    static func describe(_ error: Error) -> (String, Bool) {
        if let error = error as? TranscriptionPipelineError {
            switch error {
            case .chunksFailed(let failures):
                let first = failures.sorted { $0.key < $1.key }.first?.value
                return ("\(failures.count) parti non trascritte: \(first?.userMessage ?? "errore")", failures.values.allSatisfy(\.isRetryable))
            case .incompleteCoverage: return ("Copertura della trascrizione incompleta", false)
            case .sourceMissing: return ("File audio mancante", false)
            }
        }
        if let error = error as? SbobinaturaError {
            switch error {
            case .emptyTranscript: return ("Trascrizione vuota", false)
            case .allSectionsFailed(let message): return ("Nessuna sezione generata: \(message)", false)
            case .sectionNotFound: return ("Sezione non trovata", false)
            }
        }
        if let error = error as? AIServiceError { return (error.userMessage, error.isRetryable) }
        return (error.localizedDescription, false)
    }
}

@main
struct WorkerCommand {
    static func main() async {
        let arguments = CommandLine.arguments
        guard arguments.count >= 4, arguments[1] == "run", arguments[2] == "--job-dir" else {
            FileHandle.standardError.write(Data("Uso: quaderno-worker run --job-dir <cartella>\n".utf8))
            exit(2)
        }
        let worker = Worker(directory: URL(fileURLWithPath: arguments[3], isDirectory: true), environment: ProcessInfo.processInfo.environment)
        exit(await worker.run())
    }
}

#else

@main
struct WorkerCommand {
    static func main() {
        print("quaderno-worker è disponibile solo su Linux e macOS.")
    }
}

#endif
