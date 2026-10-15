import AVFoundation
import SwiftData
import XCTest
@testable import QuadernoAI

/// Ambiente isolato: database in memoria e cartella temporanea per i file.
@MainActor
struct TestEnvironment {
    let root: URL
    let container: ModelContainer
    let fileStore: FileStore
    let drawingStore: DrawingStore
    let content: ContentManager

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("QuadernoAITests-\(UUID().uuidString)", isDirectory: true)
        container = try AppModelContainer.makeInMemory()
        fileStore = FileStore(root: root)
        drawingStore = DrawingStore(fileStore: fileStore)
        content = ContentManager(fileStore: fileStore, drawingStore: drawingStore, modelContainer: container)
    }

    var context: ModelContext { container.mainContext }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

/// Generatore di audio sintetico (sinusoide con pause) per i test del
/// registratore senza microfono.
enum SyntheticAudio {
    static func buffer(seconds: Double, sampleRate: Double = 48_000, frequency: Double = 440, amplitude: Float = 0.3, silent: Bool = false) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let data = buffer.floatChannelData![0]
        for index in 0..<Int(frames) {
            data[index] = silent ? 0 : amplitude * Float(sin(2 * .pi * frequency * Double(index) / sampleRate))
        }
        return buffer
    }

    /// Scrive `seconds` di audio in blocchi da 4096 frame (come il tap).
    static func write(seconds: Double, to writer: SegmentedAudioWriter, sampleRate: Double = 48_000) throws {
        let full = buffer(seconds: seconds, sampleRate: sampleRate)
        let format = full.format
        var offset: AVAudioFrameCount = 0
        while offset < full.frameLength {
            let count = min(4096, full.frameLength - offset)
            let chunk = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count)!
            chunk.frameLength = count
            chunk.floatChannelData![0].update(from: full.floatChannelData![0].advanced(by: Int(offset)), count: Int(count))
            try writer.write(chunk)
            offset += count
        }
    }
}
