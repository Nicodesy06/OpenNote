import XCTest
@testable import QuadernoCore

final class ChunkPlannerTests: XCTestCase {
    func testShortFileIsSingleChunk() throws {
        let plan = try ChunkPlanner.plan(duration: 120, configuration: ChunkPlanConfiguration(targetDuration: 360))
        XCTAssertEqual(plan.count, 1)
        XCTAssertEqual(plan[0].coreStart, 0)
        XCTAssertEqual(plan[0].coreEnd, 120)
        XCTAssertEqual(plan[0].extractStart, 0)
    }

    func testThreeHourLecturePartitionIsComplete() throws {
        let duration: TimeInterval = 3 * 3600 + 17
        let plan = try ChunkPlanner.plan(duration: duration, configuration: ChunkPlanConfiguration(targetDuration: 360, maxDuration: 1200, overlap: 4))
        XCTAssertTrue(ChunkPlanner.coverageGaps(of: plan, duration: duration).isEmpty)
        XCTAssertEqual(plan.first?.coreStart, 0)
        XCTAssertEqual(plan.last?.coreEnd, duration)
        for (previous, next) in zip(plan, plan.dropFirst()) {
            XCTAssertEqual(previous.coreEnd, next.coreStart, accuracy: 1e-9, "I core devono essere contigui")
            XCTAssertEqual(next.extractStart, next.coreStart - 4, accuracy: 1e-9, "Sovrapposizione prima del chunk")
        }
        for spec in plan {
            XCTAssertLessThanOrEqual(spec.extractDuration, 1200 + 1e-9)
        }
        XCTAssertEqual(plan.map(\.index), Array(0..<plan.count))
    }

    func testCutsSnapToNearbySilence() throws {
        let plan = try ChunkPlanner.plan(duration: 1000, silences: [352, 371, 718], configuration: ChunkPlanConfiguration(targetDuration: 360, maxDuration: 1200, overlap: 4, silenceSearchWindow: 25))
        XCTAssertEqual(plan[0].coreEnd, 352, "Sceglie la pausa più vicina al taglio ideale (360)")
        XCTAssertTrue(plan[0].endsOnSilence)
        XCTAssertEqual(plan[1].coreEnd, 718)
        XCTAssertTrue(ChunkPlanner.coverageGaps(of: plan, duration: 1000).isEmpty)
    }

    func testSilenceOutsideWindowIsIgnored() throws {
        let plan = try ChunkPlanner.plan(duration: 1000, silences: [300], configuration: ChunkPlanConfiguration(targetDuration: 360, silenceSearchWindow: 25))
        XCTAssertEqual(plan[0].coreEnd, 360)
        XCTAssertFalse(plan[0].endsOnSilence)
    }

    func testTinyTailIsMergedIntoPreviousChunk() throws {
        let plan = try ChunkPlanner.plan(duration: 380, configuration: ChunkPlanConfiguration(targetDuration: 360, maxDuration: 1200, minimumTailDuration: 45))
        XCTAssertEqual(plan.count, 1, "20 s finali non meritano un chunk separato")
        XCTAssertEqual(plan[0].coreEnd, 380)
    }

    func testMaxDurationFromByteLimit() {
        // 25 MB a 64 kbps ≈ 3277 s; con margine del 15% ≈ 2785 s.
        let seconds = ChunkPlanConfiguration.maxDuration(forByteLimit: 25 * 1024 * 1024, bitrate: 64_000, providerMaxDuration: nil)
        XCTAssertEqual(seconds, 25 * 1024 * 1024 * 0.85 / 8000, accuracy: 0.01)
        let capped = ChunkPlanConfiguration.maxDuration(forByteLimit: 25 * 1024 * 1024, bitrate: 64_000, providerMaxDuration: 1500)
        XCTAssertEqual(capped, 1500)
    }

    func testInvalidInputs() {
        XCTAssertThrowsError(try ChunkPlanner.plan(duration: 0, configuration: ChunkPlanConfiguration()))
        XCTAssertThrowsError(try ChunkPlanner.plan(duration: .nan, configuration: ChunkPlanConfiguration()))
        XCTAssertThrowsError(try ChunkPlanner.plan(duration: 100, configuration: ChunkPlanConfiguration(maxDuration: 3, overlap: 4)))
    }

    func testCoverageGapDetection() {
        let specs = [
            ChunkSpec(index: 0, coreStart: 0, coreEnd: 100, extractStart: 0, extractEnd: 100, endsOnSilence: false),
            ChunkSpec(index: 1, coreStart: 110, coreEnd: 200, extractStart: 106, extractEnd: 200, endsOnSilence: false)
        ]
        let gaps = ChunkPlanner.coverageGaps(of: specs, duration: 210)
        XCTAssertEqual(gaps, [100...110, 200...210])
    }
}

final class OverlapDeduplicatorTests: XCTestCase {
    func testRemovesExactOverlap() {
        let previous = "Il Bauhaus fu fondato a Weimar nel 1919 da Walter Gropius che voleva unire arte e artigianato"
        let current = "Gropius che voleva unire arte e artigianato. In seguito la scuola si trasferì a Dessau."
        let result = OverlapDeduplicator.trim(previous: previous, current: current, minMatch: 4)
        XCTAssertTrue(result.resolved)
        XCTAssertEqual(result.current, "In seguito la scuola si trasferì a Dessau.")
        XCTAssertEqual(result.previous, previous)
    }

    func testToleratesPunctuationCaseAndTruncatedEdgeWords() {
        let previous = "quindi il funzionalismo, come diceva Sullivan, la forma segue la funz"
        let current = "ivan la forma segue la funzione. Questo principio è fondamentale."
        let result = OverlapDeduplicator.trim(previous: previous, current: current, minMatch: 4)
        XCTAssertTrue(result.resolved)
        // "funz" (troncata) esce dal precedente, "funzione" resta nel corrente:
        // il testo unito è "... la forma segue la funzione. Questo ...".
        XCTAssertEqual(result.previous, "quindi il funzionalismo, come diceva Sullivan, la forma segue la")
        XCTAssertEqual(result.current, "funzione. Questo principio è fondamentale.")
        XCTAssertEqual(result.previous + " " + result.current, "quindi il funzionalismo, come diceva Sullivan, la forma segue la funzione. Questo principio è fondamentale.")
    }

    func testDoesNotTrimWithoutRealOverlap() {
        let previous = "Parliamo ora del Deutscher Werkbund e della sua fondazione nel 1907."
        let current = "La Wiener Werkstätte nasce invece a Vienna nel 1903."
        let result = OverlapDeduplicator.trim(previous: previous, current: current, minMatch: 4)
        XCTAssertFalse(result.resolved)
        XCTAssertEqual(result.current, current)
        XCTAssertEqual(result.previous, previous)
    }

    func testAllowsSmallTranscriptionDifferencesInLongOverlap() {
        let previous = "a b c d e f g h uno due tre quattro cinque sei sette otto nove dieci undici dodici"
        let current = "uno due tre quattro cinque sei SETE otto nove dieci undici dodici poi continua il discorso"
        let result = OverlapDeduplicator.trim(previous: previous, current: current, minMatch: 4)
        XCTAssertTrue(result.resolved)
        XCTAssertEqual(result.current, "poi continua il discorso")
    }
}
