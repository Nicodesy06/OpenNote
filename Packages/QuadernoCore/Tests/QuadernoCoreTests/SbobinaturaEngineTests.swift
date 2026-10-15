import XCTest
@testable import QuadernoCore

final class SbobinaturaEngineTests: XCTestCase {
    let segments: [TranscriptSegmentDTO] = [
        "Allora buongiorno a tutti, oggi iniziamo a parlare del Bauhaus.",
        "Il Bauhaus viene fondato a Weimar nel 1919 da Walter Gropius.",
        "Eh, l'idea di Gropius è quella di unire arte e artigianato in un'unica scuola.",
        "Un esempio è il laboratorio di tessitura, dove lavorava Gunta Stölzl.",
        "Nel 1925 la scuola si trasferisce a Dessau, nel nuovo edificio progettato dallo stesso Gropius.",
        "Domanda: professore, perché si trasferiscono? Perché a Weimar il clima politico era diventato ostile.",
        "Passiamo ora al Deutscher Werkbund, fondato nel 1907 a Monaco.",
        "Il Werkbund cercava di collaborare con l'industria, anzi no, correggo: con le industrie e gli artigiani insieme.",
        "Tra i protagonisti c'è Hermann Muthesius.",
        "Per la prossima volta leggete il capitolo 4 del manuale."
    ].enumerated().map { index, text in
        TranscriptSegmentDTO(index: index, start: Double(index) * 30, end: Double(index + 1) * 30, text: text, chunkIndex: 0, precision: .interpolated)
    }

    let context = LessonContext(subjectName: "Storia del Design", lessonTitle: "Lezione 1", lessonDate: Date(timeIntervalSince1970: 1_760_000_000), glossary: ["Bauhaus", "Walter Gropius", "Deutscher Werkbund"])

    func outlineJSON() -> String {
        """
        {"lessonTitle":"Il Bauhaus e il Deutscher Werkbund","sections":[
        {"title":"La fondazione del Bauhaus","firstSegment":0,"lastSegment":5,"summary":"Weimar, Gropius, Dessau","keyItems":[{"kind":"data","text":"1919 fondazione a Weimar"},{"kind":"nome","text":"Walter Gropius"}]},
        {"title":"Il Deutscher Werkbund","firstSegment":6,"lastSegment":9,"summary":"Fondazione e obiettivi","keyItems":[{"kind":"data","text":"1907 Monaco"}]}
        ]}
        """
    }

    /// Risposta di sezione che riporta fedelmente i segmenti ricevuti.
    static func faithfulSection(for request: GenerationRequest) -> String {
        let prompt = request.messages[0].text
        let title = prompt.components(separatedBy: "\n").first { $0.hasPrefix("Sezione da scrivere: ") }?.replacingOccurrences(of: "Sezione da scrivere: ", with: "") ?? "Sezione"
        let lines = prompt.components(separatedBy: "Trascrizione della sezione:\n").last?.components(separatedBy: "\n").filter { $0.hasPrefix("[S") } ?? []
        let ids = lines.compactMap { line -> Int? in Int(line.dropFirst(2).prefix { $0.isNumber }) }
        let body = lines.map { line in line.components(separatedBy: "] ").dropFirst().joined(separator: "] ") }.joined(separator: " ")
        return "Ecco la sbobinatura richiesta:\n\n## \(title)\n\n\(body) [[S\(ids.first ?? 0)-S\(ids.last ?? 0)]]"
    }

    func makeProvider(verificationJSON: String = #"{"issues":[],"unverifiable":[]}"#, sectionResponder: ((GenerationRequest) throws -> GenerationResult)? = nil) -> ScriptedTextProvider {
        let outline = outlineJSON()
        return ScriptedTextProvider { request in
            switch request.jsonSchema?.name {
            case "lesson_outline": return result(outline)
            case "section_verification": return result(verificationJSON)
            default:
                if request.messages[0].text.hasPrefix("Correggi la sezione") {
                    let section = request.messages[0].text.components(separatedBy: "Sezione da correggere:\n").last ?? ""
                    return result(section + "\n\nIntegrazione: il trasferimento avviene per il clima politico ostile. [[S5]]")
                }
                if let sectionResponder { return try sectionResponder(request) }
                return result(Self.faithfulSection(for: request))
            }
        }
    }

    func engine(_ provider: TextGenerationProvider, store: SbobinaturaCheckpointStore? = nil, configuration: SbobinaturaConfiguration = SbobinaturaConfiguration()) throws -> SbobinaturaEngine {
        SbobinaturaEngine(provider: provider, prompts: try PromptLibrary.load(), configuration: configuration, store: store, retryPolicy: RetryPolicy(maxAttempts: 2, baseDelay: 0, jitter: 0))
    }

    func testEndToEndProducesStructuredVerifiedDocument() async throws {
        let provider = makeProvider()
        let document = try await engine(provider).generate(segments: segments, context: context)
        XCTAssertEqual(document.title, "Il Bauhaus e il Deutscher Werkbund")
        XCTAssertEqual(document.sections.count, 2)
        XCTAssertEqual(document.sections.map(\.segmentRange), [0...5, 6...9])
        XCTAssertEqual(document.sections[1].timeRange, 180...300)
        XCTAssertTrue(document.sections.allSatisfy { $0.state == .generated })
        // Preambolo rimosso, titolo di sezione normalizzato.
        XCTAssertTrue(document.sections[0].markdown.hasPrefix("## La fondazione del Bauhaus"))
        XCTAssertFalse(document.markdown.contains("Ecco la sbobinatura"))
        XCTAssertTrue(document.markdown.hasPrefix("# Il Bauhaus e il Deutscher Werkbund"))
        XCTAssertTrue(document.headerMarkdown.contains("**Materia:** Storia del Design"))
        XCTAssertTrue(document.headerMarkdown.contains("non garantiscono"), "L'intestazione non presenta i controlli come garanzia")
        XCTAssertEqual(document.sections[0].verification.status, .noIssuesFound)
        XCTAssertEqual(document.promptVersion, "sbobinatura-it-2026.10.1")
        // 1 scaletta + 2 scritture + 2 verifiche.
        XCTAssertEqual(provider.requestCount, 5)
        XCTAssertEqual(document.usage.inputTokens, 500)

        // La scrittura usa streaming ed effort alto; scaletta e verifica JSON.
        let writes = provider.requests.filter { $0.jsonSchema == nil }
        XCTAssertTrue(writes.allSatisfy { $0.stream && $0.effort == .high })
        XCTAssertTrue(writes[0].system.contains("Conserva tutte le informazioni didatticamente rilevanti"))
        XCTAssertTrue(writes[0].messages[0].text.contains("- Walter Gropius"), "Glossario incluso")
        XCTAssertTrue(writes[1].messages[0].text.contains("Ultimo paragrafo già scritto"), "Contesto della sezione precedente")
        let secondTranscript = writes[1].messages[0].text.components(separatedBy: "Trascrizione della sezione:").last ?? ""
        XCTAssertFalse(secondTranscript.contains("[S1 |"), "Ogni sezione riceve solo i propri segmenti")
        XCTAssertTrue(secondTranscript.contains("[S6 |"))
    }

    func testVerificationIssuesTriggerRepairAndAreFlaggedForReview() async throws {
        let verification = #"{"issues":[{"type":"omission","severity":"high","description":"Manca la motivazione del trasferimento","sourceSegments":[5],"excerpt":"clima politico"}],"unverifiable":["S3: nome incerto"]}"#
        let provider = makeProvider(verificationJSON: verification, sectionResponder: { request in
            // Sezione volutamente incompleta.
            let full = SbobinaturaEngineTests.faithfulSection(for: request)
            return result(full.replacingOccurrences(of: " Perché a Weimar il clima politico era diventato ostile.", with: ""))
        })
        let document = try await engine(provider).generate(segments: segments, context: context)
        let first = document.sections[0]
        XCTAssertEqual(first.verification.status, .repairedNeedsReview)
        XCTAssertTrue(first.markdown.contains("clima politico ostile"))
        XCTAssertTrue(first.verification.issues.contains { $0.type == .omission && $0.repairAttempted })
        XCTAssertEqual(first.verification.unverifiable, ["S3: nome incerto"])
    }

    func testLocalHeuristicFlagsMissingNumbersWithoutModelVerification() async throws {
        let provider = makeProvider(sectionResponder: { request in
            let text = SbobinaturaEngineTests.faithfulSection(for: request).replacingOccurrences(of: "1907", with: "").replacingOccurrences(of: "Muthesius", with: "")
            return result(text)
        })
        let config = SbobinaturaConfiguration(verifyWithModel: false)
        let document = try await engine(provider, configuration: config).generate(segments: segments, context: context)
        let issues = document.sections[1].verification.issues
        XCTAssertTrue(issues.contains { $0.type == .heuristicMissingFact && $0.excerpt == "1907" })
        XCTAssertTrue(issues.contains { $0.type == .heuristicMissingFact && $0.excerpt == "Muthesius" })
        XCTAssertEqual(provider.requests(containing: "Sei un revisore rigoroso").count, 0)
    }

    func testTruncatedOutputIsSplitAndRetried() async throws {
        let calls = Counter()
        let provider = makeProvider(sectionResponder: { request in
            let text = request.messages[0].text
            // La prima richiesta della sezione 1 (6 segmenti) viene troncata.
            if text.contains("Sezione da scrivere: La fondazione del Bauhaus"), text.contains("[S0 |"), text.contains("[S5 |") {
                return result("## La fondazione del Bauhaus\n\nTesto tronc", stop: .maxTokens)
            }
            _ = calls
            return result(SbobinaturaEngineTests.faithfulSection(for: request))
        })
        let document = try await engine(provider).generate(segments: segments, context: context)
        let first = document.sections[0]
        XCTAssertEqual(first.state, .generated)
        XCTAssertTrue(first.markdown.contains("Weimar nel 1919"))
        XCTAssertTrue(first.markdown.contains("clima politico"))
        XCTAssertFalse(first.markdown.contains("Testo tronc"))
        XCTAssertEqual(first.markdown.components(separatedBy: "## La fondazione del Bauhaus").count - 1, 1, "Un solo titolo dopo l'unione delle metà")
    }

    func testRefusalMarksOnlyThatSectionAsFailed() async throws {
        let provider = makeProvider(sectionResponder: { request in
            if request.messages[0].text.contains("Sezione da scrivere: Il Deutscher Werkbund") {
                return GenerationResult(text: "", stopReason: .refusal, usage: GenerationUsage(), model: "m", refusalCategory: "cyber")
            }
            return result(SbobinaturaEngineTests.faithfulSection(for: request))
        })
        let document = try await engine(provider).generate(segments: segments, context: context)
        XCTAssertEqual(document.sections[0].state, .generated)
        XCTAssertEqual(document.sections[1].state, .failed)
        XCTAssertTrue(document.sections[1].markdown.contains("non è stata generata"))
        XCTAssertTrue(document.hasFailures)
    }

    func testResumesFromCheckpointWithoutRepeatingWork() async throws {
        let directory = makeTemporaryDirectory()
        let store = FileSbobinaturaCheckpointStore(url: directory.appendingPathComponent("gen.json"))
        // Prima esecuzione: la seconda sezione fallisce per errore di rete
        // persistente; il lavoro svolto resta nel checkpoint.
        let failing = makeProvider(sectionResponder: { request in
            if request.messages[0].text.contains("Sezione da scrivere: Il Deutscher Werkbund") { throw AIServiceError.network("offline") }
            return result(SbobinaturaEngineTests.faithfulSection(for: request))
        })
        let first = try await engine(failing, store: store).generate(segments: segments, context: context)
        XCTAssertEqual(first.sections[1].state, .failed)

        // Senza checkpoint residuo (il documento parziale è stato restituito),
        // si verifica il caso di interruzione a metà: si salva manualmente.
        let engineA = try engine(failing, store: store)
        let fingerprint = engineA.fingerprint(segments: segments, context: context, mode: .integrale)
        try store.save(SbobinaturaCheckpoint(fingerprint: fingerprint, outline: first.outline, sections: [first.sections[0]], usage: first.usage))

        let healthy = makeProvider()
        let resumed = try await engine(healthy, store: store).generate(segments: segments, context: context)
        XCTAssertEqual(resumed.sections.map(\.state), [.generated, .generated])
        XCTAssertEqual(healthy.requests.filter { $0.jsonSchema?.name == "lesson_outline" }.count, 0, "Scaletta ripresa dal checkpoint")
        XCTAssertEqual(healthy.requests.filter { $0.jsonSchema == nil }.count, 1, "Solo la sezione mancante viene scritta")
        XCTAssertNil(try store.load(fingerprint: fingerprint), "Checkpoint eliminato a lavoro concluso")
    }

    func testOutlineFailureFallsBackToTimeBasedSections() async throws {
        let provider = ScriptedTextProvider { request in
            if request.jsonSchema?.name == "lesson_outline" { return result("non è JSON") }
            if request.jsonSchema?.name == "section_verification" { return result(#"{"issues":[],"unverifiable":[]}"#) }
            return result(SbobinaturaEngineTests.faithfulSection(for: request))
        }
        let document = try await engine(provider).generate(segments: segments, context: context)
        XCTAssertFalse(document.outline.sections.isEmpty)
        XCTAssertTrue(document.outline.normalizationNotes.first?.contains("Analisi tematica non riuscita") == true)
        XCTAssertEqual(document.outline.sections.first?.firstSegment, 0)
        XCTAssertEqual(document.outline.sections.last?.lastSegment, 9)
    }

    func testRegenerateSingleSectionWithInstructions() async throws {
        let provider = makeProvider()
        let engine = try engine(provider)
        let document = try await engine.generate(segments: segments, context: context)
        let section = try await engine.regenerateSection(order: 1, outline: document.outline, segments: segments, context: context, mode: .integrale, previousSectionMarkdown: document.sections[0].markdown, instructions: "Approfondisci la correzione del docente")
        XCTAssertEqual(section.order, 1)
        XCTAssertEqual(section.segmentRange, 6...9)
        let last = provider.requests.filter { $0.jsonSchema == nil }.last!
        XCTAssertTrue(last.messages[0].text.contains("Indicazioni per questa rigenerazione: Approfondisci la correzione del docente"))
        await XCTAssertThrowsErrorAsync(try await engine.regenerateSection(order: 7, outline: document.outline, segments: segments, context: context, mode: .integrale, previousSectionMarkdown: nil, instructions: nil))
    }

    func testEmptyTranscriptIsRejected() async throws {
        let provider = makeProvider()
        await XCTAssertThrowsErrorAsync(try await engine(provider).generate(segments: [], context: context)) {
            XCTAssertEqual($0 as? SbobinaturaError, .emptyTranscript)
        }
        XCTAssertEqual(provider.requestCount, 0)
    }

    func testSummaryModeUsesSummaryTemplateAndSkipsRepair() async throws {
        let verification = #"{"issues":[{"type":"omission","severity":"high","description":"x","sourceSegments":[1],"excerpt":"x"}],"unverifiable":[]}"#
        let provider = makeProvider(verificationJSON: verification)
        let document = try await engine(provider).generate(segments: segments, context: context, mode: .riassunto)
        XCTAssertEqual(document.mode, .riassunto)
        XCTAssertTrue(provider.requests.contains { $0.messages[0].text.hasPrefix("Scrivi un riassunto per il ripasso") })
        XCTAssertFalse(provider.requests.contains { $0.messages[0].text.hasPrefix("Correggi la sezione") })
    }
}

final class OutlineAndMarkersTests: XCTestCase {
    func testOutlineNormalizationRepairsGapsAndOverlaps() {
        let raw = LessonOutline(lessonTitle: "", sections: [
            OutlineSection(title: "B", firstSegment: 5, lastSegment: 9),
            OutlineSection(title: "A", firstSegment: 2, lastSegment: 6),
            OutlineSection(title: "Inclusa", firstSegment: 3, lastSegment: 4, keyItems: [OutlineKeyItem(kind: "data", text: "1919")]),
            OutlineSection(title: "C", firstSegment: 12, lastSegment: 40)
        ])
        let normalized = OutlineNormalizer.normalize(raw, segmentCount: 20, fallbackTitle: "Lezione")
        XCTAssertEqual(normalized.lessonTitle, "Lezione")
        XCTAssertEqual(normalized.sections.map(\.title), ["A", "B", "C"])
        XCTAssertEqual(normalized.sections.map(\.segmentRange), [0...6, 7...11, 12...19])
        XCTAssertEqual(normalized.sections[0].keyItems.count, 1, "Elementi chiave della sezione assorbita conservati")
        XCTAssertFalse(normalized.normalizationNotes.isEmpty)
    }

    func testSectionPartsRespectBudget() {
        let segments = (0..<10).map { TranscriptSegmentDTO(index: $0, start: Double($0), end: Double($0 + 1), text: String(repeating: "a", count: 100), chunkIndex: 0, precision: .exact) }
        let parts = OutlineNormalizer.parts(of: 2...9, segments: segments, maxCharacters: 300)
        XCTAssertEqual(parts.first?.lowerBound, 2)
        XCTAssertEqual(parts.last?.upperBound, 9)
        for (a, b) in zip(parts, parts.dropFirst()) { XCTAssertEqual(a.upperBound + 1, b.lowerBound) }
    }

    func testSourceMarkers() {
        let text = "Il Bauhaus nasce nel 1919. [[S1-S3]] Il nome è [[incerto: Gunta Stölzl]]. [[S4]] Fine [[S99]]"
        XCTAssertEqual(SourceMarkers.references(in: text).map(\.range), [1...3, 4...4, 99...99])
        XCTAssertEqual(SourceMarkers.uncertainPassages(in: text), ["Gunta Stölzl"])
        XCTAssertEqual(SourceMarkers.stripForExport(text), "Il Bauhaus nasce nel 1919. Il nome è [incerto: Gunta Stölzl]. Fine")
        XCTAssertEqual(SourceMarkers.invalidReferences(in: text, allowed: 0...10), [99...99])
    }

    func testEditorialNormalizer() {
        let raw = "Certamente! Ecco il testo.\n\n# Titolo sbagliato\n\nTesto.\n\n\n\n## Sottotitolo\n\nAltro.   "
        let normalized = EditorialNormalizer.normalizeSection(raw, title: "Titolo")
        XCTAssertEqual(normalized, "## Titolo sbagliato\n\nTesto.\n\n### Sottotitolo\n\nAltro.")
        XCTAssertEqual(EditorialNormalizer.normalizeSection("Solo testo.", title: "T"), "## T\n\nSolo testo.")
        XCTAssertEqual(EditorialNormalizer.normalizeSection("```markdown\n## A\n\nB\n```", title: "A"), "## A\n\nB")
    }

    func testPromptFillIsSinglePass() {
        let filled = PromptLibrary.fill("A {{X}} B {{Y}} {{non chiave}}", ["X": "{{Y}}", "Y": "y"])
        XCTAssertEqual(filled, "A {{Y}} B y {{non chiave}}")
    }

    func testAllPromptsLoadAndContainCoreRules() throws {
        let library = try PromptLibrary.load()
        for template in PromptLibrary.Template.allCases {
            XCTAssertFalse(library.raw(template).isEmpty, "\(template) mancante")
        }
        let system = library.raw(.system)
        XCTAssertTrue(system.contains("Non aggiungere informazioni esterne"))
        XCTAssertTrue(system.contains("[[incerto:"))
        XCTAssertTrue(system.contains("Privilegia la completezza"))
        var custom = library
        custom.systemOverride = "Prompt personalizzato"
        XCTAssertEqual(custom.raw(.system), "Prompt personalizzato")
        XCTAssertTrue(custom.effectiveVersion.hasPrefix("sbobinatura-it-2026.10.1+custom-"))
    }

    func testFactCheckerIgnoresSentenceStartsAndFindsMissingFacts() {
        let source = [TranscriptSegmentDTO(index: 0, start: 0, end: 1, text: "Allora, il Bauhaus nasce nel 1919 con Walter Gropius. Quindi passiamo oltre.", chunkIndex: 0, precision: .exact)]
        let complete = FactConsistencyChecker.check(source: source, output: "Il **Bauhaus** nasce nel 1919 per opera di Walter Gropius.")
        XCTAssertTrue(complete.isEmpty, "\(complete)")
        let missing = FactConsistencyChecker.check(source: source, output: "Il Bauhaus nasce per opera di un architetto.", glossary: ["Walter Gropius"])
        XCTAssertEqual(Set(missing.map(\.fact)), ["1919", "Walter", "Gropius", "Walter Gropius"])
    }
}
