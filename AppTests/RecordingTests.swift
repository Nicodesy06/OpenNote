import AVFoundation
import SwiftData
import XCTest
@testable import QuadernoAI

/// Test del sistema di registrazione con audio sintetico (senza microfono):
/// segmentazione senza buchi, finalizzazione, recupero dopo crash.
@MainActor
final class RecordingTests: XCTestCase {
    var env: TestEnvironment!

    override func setUp() async throws {
        env = try TestEnvironment()
    }

    override func tearDown() async throws {
        env.cleanup()
    }

    func testSegmentRotationProducesValidFilesWithoutGaps() async throws {
        let directory = env.fileStore.recordingDirectory(UUID())
        let writer = SegmentedAudioWriter(directory: directory, encoding: EncodingSettings(bitrate: 64_000, segmentDuration: 1))
        var closed: [SegmentedAudioWriter.Segment] = []
        writer.onSegmentClosed = { closed.append($0) }
        try SyntheticAudio.write(seconds: 3.5, to: writer)
        writer.closeCurrentSegment()

        XCTAssertEqual(writer.segments.count, 4, "3,5 s con segmenti da 1 s")
        XCTAssertTrue(writer.segments.allSatisfy(\.closed))
        XCTAssertEqual(closed.count, 4)
        let totalFrames = writer.segments.reduce(Int64(0)) { $0 + $1.frames }
        XCTAssertEqual(totalFrames, Int64(3.5 * 48_000), "Ogni campione acquisito è in un segmento: nessun buco")
        for segment in writer.segments {
            let url = directory.appendingPathComponent(segment.fileName)
            let file = try AVAudioFile(forReading: url)
            XCTAssertEqual(Double(file.length) / file.processingFormat.sampleRate, segment.duration, accuracy: 0.06, "Il file finalizzato è leggibile")
        }
    }

    func testConsolidationPreservesDuration() async throws {
        let directory = env.fileStore.recordingDirectory(UUID())
        let writer = SegmentedAudioWriter(directory: directory, encoding: EncodingSettings(bitrate: 64_000, segmentDuration: 2))
        try SyntheticAudio.write(seconds: 7, to: writer)
        writer.closeCurrentSegment()
        let urls = writer.segments.map { directory.appendingPathComponent($0.fileName) }
        let output = directory.appendingPathComponent("audio.m4a")
        let duration = try await AudioConsolidator.consolidate(segments: urls, output: output)
        XCTAssertEqual(duration, 7, accuracy: 0.3)
    }

    func testRecoveryRebuildsRecordingFromManifestAfterCrash() async throws {
        let recordingID = UUID()
        let subject = env.content.createSubject(name: "Storia del Design", colorHex: "#000000", iconName: "book")
        let directory = env.fileStore.recordingDirectory(recordingID)
        let writer = SegmentedAudioWriter(directory: directory, encoding: EncodingSettings(bitrate: 64_000, segmentDuration: 2))
        try SyntheticAudio.write(seconds: 5, to: writer)
        writer.closeCurrentSegment()
        // Simula un ultimo segmento non finalizzato (crash durante la scrittura).
        let broken = directory.appendingPathComponent(SegmentedAudioWriter.fileName(for: 99))
        try Data(repeating: 0, count: 2048).write(to: broken)
        var segments = writer.segments
        segments.append(.init(index: 99, fileName: broken.lastPathComponent, frames: 48_000, sampleRate: 48_000, closed: false))
        let manifest = RecordingManifest(recordingID: recordingID, subjectID: subject.id, notebookID: nil, title: "Lezione interrotta", startedAt: Date(), updatedAt: Date(), status: .recording, profile: "classroom", bitrate: 64_000, inputDescription: nil, segments: segments, marks: [.init(pageID: UUID(), pageIndex: 2, time: 3.2, kind: "edited")], interruptions: [])
        ManifestWriter(fileStore: env.fileStore).persistSynchronously(manifest)

        // Nessun record nel database: come se l'app fosse stata chiusa prima del salvataggio.
        let maintenance = RecordingMaintenance(fileStore: env.fileStore, modelContainer: env.container)
        await maintenance.recoverInterruptedRecordings()

        let recovered = try XCTUnwrap(env.context.fetch(FetchDescriptor<AudioRecording>(predicate: #Predicate { $0.id == recordingID })).first)
        XCTAssertEqual(recovered.title, "Lezione interrotta")
        XCTAssertEqual(recovered.subject?.id, subject.id)
        XCTAssertEqual(recovered.status, .recovered)
        XCTAssertEqual(recovered.duration, 5, accuracy: 0.3)
        XCTAssertEqual(recovered.pageMarks.count, 1)
        XCTAssertEqual(recovered.audioFileName, RecordingMaintenance.consolidatedFileName, "Segmenti validi uniti in un file")
        XCTAssertNotNil(maintenance.playableURL(for: recovered))
        XCTAssertFalse(FileManager.default.fileExists(atPath: broken.path), "Il segmento non finalizzato viene scartato")
        let updatedManifest = ManifestWriter.load(from: directory.appendingPathComponent(RecordingManifest.fileName))
        XCTAssertEqual(updatedManifest?.status, .finished)
    }

    func testImportAudioCopiesFileAndReadsDuration() async throws {
        let source = env.root.appendingPathComponent("esterno")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let writer = SegmentedAudioWriter(directory: source, encoding: EncodingSettings(bitrate: 64_000, segmentDuration: 60))
        try SyntheticAudio.write(seconds: 4, to: writer)
        writer.closeCurrentSegment()
        let file = source.appendingPathComponent(writer.segments[0].fileName)
        let importer = ImportService(fileStore: env.fileStore, modelContainer: env.container)
        let recording = try await importer.importAudio(from: file, subject: nil, title: "Lezione importata")
        XCTAssertEqual(recording.source, .imported)
        XCTAssertEqual(recording.status, .ready)
        XCTAssertEqual(recording.duration, 4, accuracy: 0.2)
        XCTAssertNotNil(RecordingMaintenance(fileStore: env.fileStore, modelContainer: env.container).playableURL(for: recording))
    }

    func testImportRejectsFilesWithoutAudio() async throws {
        let bogus = env.root.appendingPathComponent("non-audio.m4a")
        try Data("non sono audio".utf8).write(to: bogus)
        let importer = ImportService(fileStore: env.fileStore, modelContainer: env.container)
        do {
            _ = try await importer.importAudio(from: bogus, subject: nil)
            XCTFail("Doveva fallire")
        } catch {
            XCTAssertEqual(try env.context.fetchCount(FetchDescriptor<AudioRecording>()), 0, "Nessun record parziale")
        }
    }

    func testMonoDownmixAndGain() {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
        let stereo = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4)!
        stereo.frameLength = 4
        let left = stereo.floatChannelData![0]
        let right = stereo.floatChannelData![1]
        for index in 0..<4 {
            left[index] = 0.5
            right[index] = 0.1
        }
        let mono = AudioCaptureEngine.makeMono(stereo, gain: 1)!
        XCTAssertEqual(mono.format.channelCount, 1)
        XCTAssertEqual(mono.floatChannelData![0][0], 0.3, accuracy: 1e-6, "Media dei canali")
        let boosted = AudioCaptureEngine.makeMono(stereo, gain: 8)!
        XCTAssertEqual(boosted.floatChannelData![0][0], 1, accuracy: 1e-6, "Guadagno con limitazione a ±1")
    }

    func testSignalQualityEvaluation() {
        let quiet = [Float](repeating: -60, count: 120)
        XCTAssertEqual(SignalAnalyzer.evaluate(history: quiet, recentClips: 0, capacity: 120), .low)
        let speech = (0..<120).map { $0 % 3 == 0 ? Float(-50) : Float(-25) }
        XCTAssertEqual(SignalAnalyzer.evaluate(history: speech, recentClips: 0, capacity: 120), .good)
        XCTAssertEqual(SignalAnalyzer.evaluate(history: speech, recentClips: 4, capacity: 120), .clipping)
        XCTAssertEqual(SignalAnalyzer.evaluate(history: Array(speech.prefix(10)), recentClips: 0, capacity: 120), .unknown)
    }
}
