import AVFoundation
import os

/// Unisce i segmenti di una registrazione in un unico file M4A. Prova prima
/// senza ricodifica (passthrough: veloce e senza perdita di qualità) e, se i
/// segmenti hanno formati diversi (es. cambio di microfono a metà lezione),
/// ripiega su una ricodifica AAC. Verifica la durata del risultato prima di
/// considerare l'operazione riuscita: i segmenti originali vengono eliminati
/// dal chiamante solo dopo questa verifica.
enum AudioConsolidator {
    static let logger = Logger(subsystem: "QuadernoAI", category: "AudioConsolidator")

    enum ConsolidationError: Error, LocalizedError {
        case noSegments
        case unreadableSegment(String)
        case exportFailed(String)
        case durationMismatch(expected: TimeInterval, actual: TimeInterval)

        var errorDescription: String? {
            switch self {
            case .noSegments: return "Nessun segmento audio da unire."
            case .unreadableSegment(let name): return "Segmento audio illeggibile: \(name)."
            case .exportFailed(let message): return "Unione dei segmenti non riuscita: \(message)"
            case .durationMismatch(let expected, let actual): return String(format: "Durata del file unito non coerente (%.1f s invece di %.1f s).", actual, expected)
            }
        }
    }

    /// - Returns: durata del file prodotto.
    static func consolidate(segments: [URL], output: URL) async throws -> TimeInterval {
        guard !segments.isEmpty else { throw ConsolidationError.noSegments }
        if FileManager.default.fileExists(atPath: output.path) {
            try FileManager.default.removeItem(at: output)
        }
        if segments.count == 1 {
            try FileManager.default.copyItem(at: segments[0], to: output)
            return try await duration(of: output)
        }

        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ConsolidationError.exportFailed("traccia non creata")
        }
        var cursor = CMTime.zero
        var expected: TimeInterval = 0
        for url in segments {
            let asset = AVURLAsset(url: url)
            guard let source = try await asset.loadTracks(withMediaType: .audio).first else {
                throw ConsolidationError.unreadableSegment(url.lastPathComponent)
            }
            let segmentDuration = try await asset.load(.duration)
            guard segmentDuration.isValid, segmentDuration.seconds > 0 else { continue }
            try track.insertTimeRange(CMTimeRange(start: .zero, duration: segmentDuration), of: source, at: cursor)
            cursor = CMTimeAdd(cursor, segmentDuration)
            expected += segmentDuration.seconds
        }

        do {
            try await export(composition, preset: AVAssetExportPresetPassthrough, to: output)
        } catch {
            logger.notice("Passthrough non riuscito, ricodifica AAC: \(error.localizedDescription, privacy: .public)")
            try? FileManager.default.removeItem(at: output)
            try await export(composition, preset: AVAssetExportPresetAppleM4A, to: output)
        }
        let actual = try await duration(of: output)
        // Tolleranza: priming AAC e arrotondamenti (0,5 s + 0,2%).
        guard abs(actual - expected) <= 0.5 + expected * 0.002 else {
            throw ConsolidationError.durationMismatch(expected: expected, actual: actual)
        }
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: output.path)
        return actual
    }

    static func duration(of url: URL) async throws -> TimeInterval {
        let asset = AVURLAsset(url: url)
        let value = try await asset.load(.duration)
        return value.isValid ? value.seconds : 0
    }

    static func export(_ asset: AVAsset, preset: String, to output: URL) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw ConsolidationError.exportFailed("preset \(preset) non disponibile")
        }
        if #available(iOS 18.0, *) {
            try await session.export(to: output, as: .m4a)
        } else {
            session.outputURL = output
            session.outputFileType = .m4a
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                session.exportAsynchronously {
                    switch session.status {
                    case .completed:
                        continuation.resume()
                    case .cancelled:
                        continuation.resume(throwing: CancellationError())
                    default:
                        continuation.resume(throwing: ConsolidationError.exportFailed(session.error?.localizedDescription ?? "stato \(session.status.rawValue)"))
                    }
                }
            }
        }
    }
}
