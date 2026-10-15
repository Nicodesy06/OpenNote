import AVFoundation
import Accelerate
import QuadernoCore

/// Estrazione dei chunk audio con AVFoundation.
///
/// - Sorgenti AAC (M4A, MP4, MOV): passthrough senza ricodifica, solo la
///   traccia audio (anche da video).
/// - Altri formati (MP3, WAV, AIFF): ricodifica in AAC/M4A, formato
///   accettato da tutti i provider.
/// - La ricerca delle pause analizza solo brevi finestre attorno ai tagli,
///   decodificando a 16 kHz mono: costo contenuto anche per lezioni di 3 ore.
struct AVAudioChunkExtractor: AudioChunkExtractor {
    enum ExtractionError: Error, LocalizedError {
        case noAudioTrack
        case exportFailed(String)

        var errorDescription: String? {
            switch self {
            case .noAudioTrack: return "Il file non contiene una traccia audio."
            case .exportFailed(let message): return "Estrazione del frammento audio non riuscita: \(message)"
            }
        }
    }

    static let passthroughExtensions: Set<String> = ["m4a", "mp4", "m4v", "mov", "aac"]

    func estimatedBitrate(of source: URL) async throws -> Int {
        if !Self.passthroughExtensions.contains(source.pathExtension.lowercased()) {
            // Ricodifica con il preset AppleM4A: stima prudente.
            return 256_000
        }
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw ExtractionError.noAudioTrack }
        let rate = try await track.load(.estimatedDataRate)
        // Margine per sorgenti a bitrate variabile.
        return max(Int(Double(rate) * 1.15), 24_000)
    }

    func silenceCandidates(in source: URL, around times: [TimeInterval], window: TimeInterval) async throws -> [TimeInterval] {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return [] }
        var candidates: [TimeInterval] = []
        for time in times {
            try Task.checkCancellation()
            let start = max(0, time - window)
            if let silence = try? findQuietPoint(asset: asset, track: track, start: start, duration: window * 2) {
                candidates.append(silence)
            }
        }
        return candidates
    }

    /// Centro della pausa più lunga (≥ 300 ms) nella finestra.
    private func findQuietPoint(asset: AVAsset, track: AVAssetTrack, start: TimeInterval, duration: TimeInterval) throws -> TimeInterval? {
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), duration: CMTime(seconds: duration, preferredTimescale: 600))
        let sampleRate = 16_000.0
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }

        // Livelli RMS su finestre di 100 ms.
        let frameSize = Int(sampleRate / 10)
        var levels: [Float] = []
        var pending: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == kCMBlockBufferNoErr, let pointer else { continue }
            let count = length / MemoryLayout<Float>.size
            pointer.withMemoryRebound(to: Float.self, capacity: count) { floats in
                pending.append(contentsOf: UnsafeBufferPointer(start: floats, count: count))
            }
            while pending.count >= frameSize {
                var rms: Float = 0
                pending.withUnsafeBufferPointer { vDSP_rmsqv($0.baseAddress!, 1, &rms, vDSP_Length(frameSize)) }
                levels.append(20 * log10(max(rms, 1e-8)))
                pending.removeFirst(frameSize)
            }
        }
        guard levels.count > 5 else { return nil }
        let sorted = levels.sorted()
        let floor = sorted[Int(Double(sorted.count) * 0.2)]
        let threshold = min(floor + 6, -35)
        var bestStart = -1
        var bestLength = 0
        var runStart = -1
        for (index, level) in levels.enumerated() {
            if level <= threshold {
                if runStart < 0 { runStart = index }
                let length = index - runStart + 1
                if length > bestLength {
                    bestLength = length
                    bestStart = runStart
                }
            } else {
                runStart = -1
            }
        }
        guard bestLength >= 3, bestStart >= 0 else { return nil }
        let center = Double(bestStart) + Double(bestLength) / 2
        return start + center * 0.1
    }

    func extract(_ spec: ChunkSpec, from source: URL, into directory: URL) async throws -> AudioChunkFile {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw ExtractionError.noAudioTrack }
        let assetDuration = try await asset.load(.duration)
        // Composizione con la sola traccia audio (scarta l'eventuale video).
        let composition = AVMutableComposition()
        guard let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ExtractionError.exportFailed("traccia non creata")
        }
        let start = CMTime(seconds: spec.extractStart, preferredTimescale: 44_100)
        var end = CMTime(seconds: spec.extractEnd, preferredTimescale: 44_100)
        if CMTimeCompare(end, assetDuration) > 0 { end = assetDuration }
        try audioTrack.insertTimeRange(CMTimeRange(start: start, end: end), of: track, at: .zero)

        let output = directory.appendingPathComponent("chunk-\(spec.index)-\(UUID().uuidString.prefix(8)).m4a")
        try? FileManager.default.removeItem(at: output)
        let passthrough = Self.passthroughExtensions.contains(source.pathExtension.lowercased())
        do {
            try await AudioConsolidator.export(composition, preset: passthrough ? AVAssetExportPresetPassthrough : AVAssetExportPresetAppleM4A, to: output)
        } catch {
            guard passthrough else { throw ExtractionError.exportFailed(error.localizedDescription) }
            try? FileManager.default.removeItem(at: output)
            try await AudioConsolidator.export(composition, preset: AVAssetExportPresetAppleM4A, to: output)
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? NSNumber)?.intValue ?? 0
        return AudioChunkFile(spec: spec, url: output, byteSize: size, mimeType: "audio/mp4")
    }
}
