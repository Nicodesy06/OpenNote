#if os(Linux) || os(macOS)
import Foundation
import QuadernoCore

/// Estrattore di chunk per il server, basato su ffmpeg/ffprobe. I chunk sono
/// ricodificati in AAC mono 16 kHz a 48 kbps: qualità adatta al parlato e
/// file piccoli, ben sotto il limite di 25 MB per chunk.
struct FFmpegChunkExtractor: AudioChunkExtractor {
    var ffmpeg: String = ProcessInfo.processInfo.environment["FFMPEG_PATH"] ?? "ffmpeg"
    var ffprobe: String = ProcessInfo.processInfo.environment["FFPROBE_PATH"] ?? "ffprobe"
    static let outputBitrate = 48_000

    enum FFmpegError: Error, LocalizedError {
        case failed(String)
        var errorDescription: String? {
            if case .failed(let message) = self { return "ffmpeg: \(message)" }
            return nil
        }
    }

    func estimatedBitrate(of source: URL) async throws -> Int {
        // Margine per l'overhead del contenitore e la variabilità dell'AAC.
        Int(Double(Self.outputBitrate) * 1.2)
    }

    func duration(of source: URL) throws -> TimeInterval {
        let output = try Self.run(ffprobe, ["-v", "error", "-show_entries", "format=duration", "-of", "default=noprint_wrappers=1:nokey=1", source.path])
        guard let value = Double(output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)), value > 0 else {
            throw FFmpegError.failed("durata non leggibile")
        }
        return value
    }

    func silenceCandidates(in source: URL, around times: [TimeInterval], window: TimeInterval) async throws -> [TimeInterval] {
        var result: [TimeInterval] = []
        for time in times {
            let start = max(0, time - window)
            let output = try Self.run(ffmpeg, ["-hide_banner", "-nostats", "-ss", String(format: "%.3f", start), "-t", String(format: "%.3f", window * 2), "-i", source.path, "-af", "silencedetect=noise=-35dB:d=0.3", "-f", "null", "-"])
            if let center = Self.longestSilenceCenter(in: output.stderr) {
                result.append(start + center)
            }
        }
        return result
    }

    /// Interpreta l'output di `silencedetect` e restituisce il centro della
    /// pausa più lunga (in secondi relativi all'inizio della finestra).
    static func longestSilenceCenter(in log: String) -> TimeInterval? {
        var best: (center: TimeInterval, duration: TimeInterval)?
        var currentStart: TimeInterval?
        for line in log.split(separator: "\n") {
            if let range = line.range(of: "silence_start: ") {
                currentStart = Double(line[range.upperBound...].split(separator: " ").first ?? "")
            } else if let range = line.range(of: "silence_end: "), let start = currentStart {
                let parts = line[range.upperBound...].split(separator: " ")
                if let end = Double(parts.first ?? "") {
                    let duration = end - start
                    if duration > (best?.duration ?? 0) {
                        best = ((start + end) / 2, duration)
                    }
                }
                currentStart = nil
            }
        }
        return best?.center
    }

    func extract(_ spec: ChunkSpec, from source: URL, into directory: URL) async throws -> AudioChunkFile {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory.appendingPathComponent("chunk-\(spec.index)-\(UUID().uuidString.prefix(8)).m4a")
        _ = try Self.run(ffmpeg, Self.extractArguments(spec: spec, source: source, output: output))
        let size = (try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? NSNumber)?.intValue ?? 0
        guard size > 0 else { throw FFmpegError.failed("chunk vuoto") }
        return AudioChunkFile(spec: spec, url: output, byteSize: size, mimeType: "audio/mp4")
    }

    static func extractArguments(spec: ChunkSpec, source: URL, output: URL) -> [String] {
        ["-hide_banner", "-nostats", "-y",
         "-ss", String(format: "%.3f", spec.extractStart),
         "-t", String(format: "%.3f", spec.extractDuration),
         "-i", source.path,
         "-vn", "-ac", "1", "-ar", "16000", "-c:a", "aac", "-b:a", "\(outputBitrate / 1000)k",
         output.path]
    }

    struct ProcessOutput {
        var stdout: String
        var stderr: String
    }

    static func run(_ executable: String, _ arguments: [String]) throws -> ProcessOutput {
        let process = Process()
        if executable.contains("/") {
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [executable] + arguments
        }
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        // Lettura prima dell'attesa per evitare blocchi con output voluminosi.
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let result = ProcessOutput(stdout: String(decoding: outData, as: UTF8.self), stderr: String(decoding: errData, as: UTF8.self))
        guard process.terminationStatus == 0 else {
            throw FFmpegError.failed(String(result.stderr.suffix(400)))
        }
        return result
    }
}
#endif
