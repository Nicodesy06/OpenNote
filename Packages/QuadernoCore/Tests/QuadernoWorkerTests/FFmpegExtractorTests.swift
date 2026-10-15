#if os(Linux) || os(macOS)
import XCTest
import QuadernoCore
@testable import QuadernoWorker

final class FFmpegExtractorTests: XCTestCase {
    func testParsesLongestSilence() {
        let log = """
        [silencedetect @ 0x1] silence_start: 3.2
        [silencedetect @ 0x1] silence_end: 3.6 | silence_duration: 0.4
        [silencedetect @ 0x1] silence_start: 20.5
        [silencedetect @ 0x1] silence_end: 22.5 | silence_duration: 2.0
        """
        XCTAssertEqual(FFmpegChunkExtractor.longestSilenceCenter(in: log) ?? 0, 21.5, accuracy: 1e-9)
        XCTAssertNil(FFmpegChunkExtractor.longestSilenceCenter(in: "niente"))
    }

    func testExtractArgumentsUseAbsoluteOffsets() {
        let spec = ChunkSpec(index: 2, coreStart: 720, coreEnd: 1080, extractStart: 716, extractEnd: 1080, endsOnSilence: true)
        let arguments = FFmpegChunkExtractor.extractArguments(spec: spec, source: URL(fileURLWithPath: "/tmp/a.m4a"), output: URL(fileURLWithPath: "/tmp/o.m4a"))
        XCTAssertEqual(arguments[arguments.firstIndex(of: "-ss")! + 1], "716.000")
        XCTAssertEqual(arguments[arguments.firstIndex(of: "-t")! + 1], "364.000")
        XCTAssertTrue(arguments.contains("-vn"))
    }

    /// Prova reale con ffmpeg: audio sintetico con pause note, durata,
    /// pause rilevate ed estrazione dei chunk.
    func testRealAudioWithFFmpeg() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/ffmpeg") else { throw XCTSkip("ffmpeg non installato") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ffmpeg-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("lezione.m4a")
        // 20 s di tono, 2 s di silenzio, 20 s di tono.
        _ = try FFmpegChunkExtractor.run("ffmpeg", ["-hide_banner", "-y", "-f", "lavfi", "-i", "sine=frequency=300:duration=20", "-f", "lavfi", "-i", "anullsrc=r=44100:cl=mono:d=2", "-f", "lavfi", "-i", "sine=frequency=500:duration=20", "-filter_complex", "[0][1][2]concat=n=3:v=0:a=1", "-c:a", "aac", source.path])
        let extractor = FFmpegChunkExtractor()
        let duration = try extractor.duration(of: source)
        XCTAssertEqual(duration, 42, accuracy: 0.3)
        let silences = try await extractor.silenceCandidates(in: source, around: [19], window: 5)
        XCTAssertEqual(silences.first ?? 0, 21, accuracy: 0.4, "Centro della pausa fra 20 e 22 s")
        let spec = ChunkSpec(index: 1, coreStart: 21, coreEnd: 42, extractStart: 17, extractEnd: 42, endsOnSilence: true)
        let chunk = try await extractor.extract(spec, from: source, into: directory)
        XCTAssertGreaterThan(chunk.byteSize, 1000)
        XCTAssertEqual(try extractor.duration(of: chunk.url), 25, accuracy: 0.3)
    }
}
#endif
