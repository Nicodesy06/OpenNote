import XCTest
@testable import QuadernoCore

final class OnDeviceCatalogTests: XCTestCase {
    func testCatalogHasUniqueIDsAndWhisperNotesModels() {
        let ids = OnDeviceModelCatalog.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        for id in ["parakeet-v3", "sensevoice-small", "apple-speech", "whisper-large-v3-turbo", "parakeet-ultra", "canary-1b-v2"] {
            XCTAssertNotNil(OnDeviceModelCatalog.model(id: id), id)
        }
    }

    func testRecommendationForItalianOnModernIPad() {
        let best = OnDeviceModelCatalog.recommended(osMajor: 26, ramGB: 8, languages: ["it"])
        XCTAssertEqual(best?.id, "parakeet-ultra")
        let compatible = OnDeviceModelCatalog.compatible(osMajor: 26, ramGB: 8, languages: ["it"])
        XCTAssertFalse(compatible.contains { $0.id == "sensevoice-small" }, "SenseVoice non è adatto all'italiano")
        XCTAssertTrue(compatible.contains { $0.id == "apple-speech" })
    }

    func testOlderDevicesGetLighterModels() {
        let compatible = OnDeviceModelCatalog.compatible(osMajor: 17, ramGB: 3, languages: ["it"])
        XCTAssertFalse(compatible.contains { $0.id == "parakeet-redux" }, "Redux richiede iPadOS 18")
        XCTAssertFalse(compatible.contains { $0.id == "whisper-large-v3" })
        XCTAssertEqual(compatible.first?.id, "apple-speech")
        XCTAssertEqual(OnDeviceModelCatalog.recommended(osMajor: 26, ramGB: 3, languages: ["it"])?.id, "apple-speech")
    }

    func testLanguageFiltering() {
        let japanese = OnDeviceModelCatalog.compatible(osMajor: 26, ramGB: 8, languages: ["ja"])
        XCTAssertTrue(japanese.contains { $0.id == "sensevoice-small" })
        XCTAssertFalse(japanese.contains { $0.id == "parakeet-v3" })
        XCTAssertTrue(japanese.contains { $0.id == "whisper-large-v3-turbo" })
    }

    func testSentencePieceWordGroupingAndSegments() {
        let tokens = [
            TimedWordGrouper.Word(text: "▁Il", start: 0, end: 0.2),
            TimedWordGrouper.Word(text: "▁Bau", start: 0.3, end: 0.5),
            TimedWordGrouper.Word(text: "haus", start: 0.5, end: 0.8),
            TimedWordGrouper.Word(text: "▁nasce", start: 0.9, end: 1.2),
            TimedWordGrouper.Word(text: "▁nel", start: 1.3, end: 1.4),
            TimedWordGrouper.Word(text: "▁1919.", start: 1.5, end: 3.4),
            TimedWordGrouper.Word(text: "▁Poi", start: 6.0, end: 6.3),
            TimedWordGrouper.Word(text: "▁Dessau", start: 6.4, end: 7.0)
        ]
        let words = TimedWordGrouper.wordsFromSentencePiece(tokens)
        XCTAssertEqual(words.map(\.text), ["Il", "Bauhaus", "nasce", "nel", "1919.", "Poi", "Dessau"])
        let segments = TimedWordGrouper.segments(from: words)
        XCTAssertEqual(segments.map(\.text), ["Il Bauhaus nasce nel 1919.", "Poi Dessau"])
        XCTAssertEqual(segments[1].start, 6.0)
    }

    /// FluidAudio sostituisce "▁" con uno spazio nei token temporizzati.
    func testSpacePrefixedTokensAsProducedByFluidAudio() {
        let tokens = [
            TimedWordGrouper.Word(text: " La", start: 0.0, end: 0.2),
            TimedWordGrouper.Word(text: " termo", start: 0.3, end: 0.5),
            TimedWordGrouper.Word(text: "dina", start: 0.5, end: 0.7),
            TimedWordGrouper.Word(text: "mica", start: 0.7, end: 0.9),
            TimedWordGrouper.Word(text: ".", start: 0.9, end: 1.0)
        ]
        let words = TimedWordGrouper.wordsFromSentencePiece(tokens)
        XCTAssertEqual(words.map(\.text), ["La", "termodinamica."])
        XCTAssertEqual(words[1].start, 0.3)
        XCTAssertEqual(words[1].end, 1.0)
    }
}
