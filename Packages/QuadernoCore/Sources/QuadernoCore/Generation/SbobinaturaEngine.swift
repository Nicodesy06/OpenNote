import Foundation

/// Checkpoint della generazione: scaletta e sezioni completate vengono
/// salvate appena pronte, così un'interruzione (rete, sospensione dell'app)
/// non obbliga a ripartire da capo né a pagare di nuovo il lavoro svolto.
public protocol SbobinaturaCheckpointStore: Sendable {
    func load(fingerprint: String) throws -> SbobinaturaCheckpoint?
    func save(_ checkpoint: SbobinaturaCheckpoint) throws
    func reset() throws
}

public struct SbobinaturaCheckpoint: Codable, Sendable, Equatable {
    public var fingerprint: String
    public var outline: LessonOutline?
    public var sections: [GeneratedSectionDTO]
    public var usage: GenerationUsage

    public init(fingerprint: String, outline: LessonOutline? = nil, sections: [GeneratedSectionDTO] = [], usage: GenerationUsage = GenerationUsage()) {
        self.fingerprint = fingerprint
        self.outline = outline
        self.sections = sections
        self.usage = usage
    }
}

public struct FileSbobinaturaCheckpointStore: SbobinaturaCheckpointStore {
    public let url: URL

    public init(url: URL) { self.url = url }

    public func load(fingerprint: String) throws -> SbobinaturaCheckpoint? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let checkpoint = try JSONDecoder().decode(SbobinaturaCheckpoint.self, from: Data(contentsOf: url))
        return checkpoint.fingerprint == fingerprint ? checkpoint : nil
    }

    public func save(_ checkpoint: SbobinaturaCheckpoint) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(checkpoint).write(to: url, options: .atomic)
    }

    public func reset() throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}

public struct SbobinaturaConfiguration: Sendable, Equatable {
    public var writingEffort: GenerationEffort
    public var analysisEffort: GenerationEffort
    public var verificationEffort: GenerationEffort
    /// Caratteri massimi di trascrizione per una singola chiamata di
    /// scrittura; sezioni più lunghe vengono suddivise in parti.
    public var maxSectionCharacters: Int
    /// Passaggio E: verifica di completezza con il modello.
    public var verifyWithModel: Bool
    /// Correzione automatica dei problemi gravi trovati dalla verifica.
    public var autoRepair: Bool
    /// Dopo una correzione, ripete la verifica con il modello (più costoso).
    public var reverifyAfterRepair: Bool
    /// Rapporto minimo parole prodotte/parole sorgente in modalità integrale
    /// sotto il quale la sezione viene segnalata come troppo compressa.
    public var minimumIntegralLengthRatio: Double

    public init(writingEffort: GenerationEffort = .high, analysisEffort: GenerationEffort = .medium, verificationEffort: GenerationEffort = .medium, maxSectionCharacters: Int = 24_000, verifyWithModel: Bool = true, autoRepair: Bool = true, reverifyAfterRepair: Bool = false, minimumIntegralLengthRatio: Double = 0.45) {
        self.writingEffort = writingEffort
        self.analysisEffort = analysisEffort
        self.verificationEffort = verificationEffort
        self.maxSectionCharacters = maxSectionCharacters
        self.verifyWithModel = verifyWithModel
        self.autoRepair = autoRepair
        self.reverifyAfterRepair = reverifyAfterRepair
        self.minimumIntegralLengthRatio = minimumIntegralLengthRatio
    }
}

public enum SbobinaturaError: Error, Equatable, Sendable {
    case emptyTranscript
    case allSectionsFailed(String)
    case sectionNotFound
}

/// Motore della sbobinatura a più passaggi:
///
/// A. Preparazione — segmenti numerati con tempi (`TranscriptFormatter`).
/// B. Analisi tematica — scaletta JSON con elementi chiave per sezione.
/// C. Rielaborazione — una chiamata per sezione (o parte), in streaming.
/// D. Assemblaggio — locale e deterministico, con intestazione.
/// E. Controllo di completezza — verifica del modello + controllo euristico
///    locale, con eventuale correzione automatica.
/// F. Controllo editoriale — normalizzazione locale di titoli e spaziature;
///    la qualità stilistica è affidata al passaggio C (vedi documentazione:
///    una passata editoriale con il modello su tutto il documento
///    raddoppierebbe i costi e rischierebbe di comprimere il testo).
public struct SbobinaturaEngine: Sendable {
    public var provider: TextGenerationProvider
    public var prompts: PromptLibrary
    public var configuration: SbobinaturaConfiguration
    public var store: SbobinaturaCheckpointStore?
    public var retryPolicy: RetryPolicy

    public init(provider: TextGenerationProvider, prompts: PromptLibrary, configuration: SbobinaturaConfiguration = SbobinaturaConfiguration(), store: SbobinaturaCheckpointStore? = nil, retryPolicy: RetryPolicy = RetryPolicy()) {
        self.provider = provider
        self.prompts = prompts
        self.configuration = configuration
        self.store = store
        self.retryPolicy = retryPolicy
    }

    // MARK: - Impronta per la ripresa

    public func fingerprint(segments: [TranscriptSegmentDTO], context: LessonContext, mode: SbobinaturaMode) -> String {
        var hasher = Data()
        hasher.append(Data(TranscriptFormatter.format(segments).utf8))
        hasher.append(Data("|\(context.subjectName)|\(context.lessonTitle)|\(context.language)|\(context.glossary.joined(separator: ","))|\(context.userInstructions ?? "")".utf8))
        hasher.append(Data("|\(mode.rawValue)|\(provider.id)|\(provider.model)|\(prompts.effectiveVersion)".utf8))
        hasher.append(Data("|\(configuration.verifyWithModel)|\(configuration.autoRepair)|\(configuration.maxSectionCharacters)".utf8))
        return String(format: "%08x-%d", StableHash.fnv1a32(hasher), segments.count)
    }

    // MARK: - Generazione completa

    public func generate(
        segments: [TranscriptSegmentDTO],
        context: LessonContext,
        mode: SbobinaturaMode = .integrale,
        progress: (@Sendable (SbobinaturaProgress) -> Void)? = nil,
        onSectionText: (@Sendable (Int, String) -> Void)? = nil
    ) async throws -> GeneratedDocumentDTO {
        let segments = segments.enumerated().map { offset, segment -> TranscriptSegmentDTO in
            var copy = segment
            copy.index = offset
            return copy
        }
        guard !segments.isEmpty, segments.contains(where: { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            throw SbobinaturaError.emptyTranscript
        }
        progress?(SbobinaturaProgress(phase: .preparing))
        let fingerprint = self.fingerprint(segments: segments, context: context, mode: mode)
        var checkpoint = (try? store?.load(fingerprint: fingerprint)) ?? SbobinaturaCheckpoint(fingerprint: fingerprint)

        // B. Analisi tematica
        let outline: LessonOutline
        if let saved = checkpoint.outline {
            outline = saved
        } else {
            progress?(SbobinaturaProgress(phase: .analyzing, detail: "Analisi della struttura della lezione"))
            let (built, usage) = try await buildOutline(segments: segments, context: context)
            outline = built
            checkpoint.outline = outline
            checkpoint.usage = checkpoint.usage + usage
            try? store?.save(checkpoint)
        }

        // C + E per ciascuna sezione
        let total = outline.sections.count
        for (order, _) in outline.sections.enumerated() {
            if checkpoint.sections.contains(where: { $0.order == order && $0.state == .generated }) { continue }
            checkpoint.sections.removeAll { $0.order == order }
            let previousTail = checkpoint.sections.first { $0.order == order - 1 }.map { Self.lastParagraph(of: $0.markdown) }
            let section = await produceSection(order: order, outline: outline, segments: segments, context: context, mode: mode, previousTail: previousTail, extraInstructions: nil, progress: { phase, detail in
                progress?(SbobinaturaProgress(phase: phase, currentSection: order, totalSections: total, detail: detail))
            }, onText: { text in onSectionText?(order, text) })
            checkpoint.sections.append(section)
            checkpoint.usage = checkpoint.usage + section.usage
            try? store?.save(checkpoint)
        }

        // D. Assemblaggio
        progress?(SbobinaturaProgress(phase: .assembling, currentSection: total, totalSections: total))
        let sections = checkpoint.sections.sorted { $0.order < $1.order }
        if !sections.isEmpty, sections.allSatisfy({ $0.state == .failed }) {
            throw SbobinaturaError.allSectionsFailed(sections.first?.errorMessage ?? "errore sconosciuto")
        }
        let title = outline.lessonTitle.isEmpty ? context.lessonTitle : outline.lessonTitle
        let document = GeneratedDocumentDTO(
            title: title,
            mode: mode,
            headerMarkdown: Self.header(title: title, context: context, mode: mode, model: provider.model, duration: segments.last?.end ?? 0),
            sections: sections,
            outline: outline,
            promptVersion: prompts.effectiveVersion,
            providerID: provider.id,
            model: provider.model,
            usage: checkpoint.usage
        )
        try? store?.reset()
        progress?(SbobinaturaProgress(phase: .completed, currentSection: total, totalSections: total))
        return document
    }

    // MARK: - Rigenerazione di una singola sezione

    /// Rigenera una sola sezione, lasciando intatte le altre (comprese quelle
    /// modificate manualmente dall'utente).
    public func regenerateSection(
        order: Int,
        outline: LessonOutline,
        segments: [TranscriptSegmentDTO],
        context: LessonContext,
        mode: SbobinaturaMode,
        previousSectionMarkdown: String?,
        instructions: String?,
        progress: (@Sendable (SbobinaturaProgress) -> Void)? = nil,
        onText: (@Sendable (String) -> Void)? = nil
    ) async throws -> GeneratedSectionDTO {
        guard outline.sections.indices.contains(order) else { throw SbobinaturaError.sectionNotFound }
        let segments = segments.enumerated().map { offset, segment -> TranscriptSegmentDTO in
            var copy = segment
            copy.index = offset
            return copy
        }
        return await produceSection(order: order, outline: outline, segments: segments, context: context, mode: mode, previousTail: previousSectionMarkdown.map(Self.lastParagraph(of:)), extraInstructions: instructions, progress: { phase, detail in
            progress?(SbobinaturaProgress(phase: phase, currentSection: order, totalSections: outline.sections.count, detail: detail))
        }, onText: onText)
    }

    // MARK: - B. Scaletta

    func buildOutline(segments: [TranscriptSegmentDTO], context: LessonContext) async throws -> (LessonOutline, GenerationUsage) {
        let budget = max(20_000, min(provider.inputCharacterBudget, 400_000))
        let windows = TranscriptFormatter.windows(segments, budget: budget)
        var sections: [OutlineSection] = []
        var lessonTitle = ""
        var usage = GenerationUsage()
        var notes: [String] = []
        do {
            for (windowIndex, window) in windows.enumerated() {
                var continuation = ""
                if windows.count > 1 {
                    continuation = "Questa è la parte \(windowIndex + 1) di \(windows.count) della trascrizione (segmenti S\(window.lowerBound)–S\(window.upperBound - 1))."
                    if let lastTitle = sections.last?.title {
                        continuation += " L'ultima sezione individuata nella parte precedente è «\(lastTitle)»: se il discorso prosegue sullo stesso argomento, inizia comunque una nuova sezione con un titolo coerente."
                    }
                }
                let prompt = prompts.render(.outline, [
                    "MATERIA": context.subjectName,
                    "TITOLO_LEZIONE": context.lessonTitle,
                    "CONTINUAZIONE": continuation,
                    "LINGUA": context.language,
                    "GLOSSARIO": Self.glossaryText(context.glossary),
                    "TRASCRIZIONE": TranscriptFormatter.format(Array(segments[window]))
                ])
                let result = try await call(GenerationRequest(system: systemPrompt(context), messages: [.user(prompt)], maxOutputTokens: 16_000, jsonSchema: SbobinaturaSchemas.outline, effort: configuration.analysisEffort, stream: false))
                usage = usage + result.usage
                let payload = try SbobinaturaSchemas.decodeOutline(result.text)
                if lessonTitle.isEmpty { lessonTitle = payload.lessonTitle }
                // Limita le sezioni alla finestra corrente.
                let windowRange = window.lowerBound...(window.upperBound - 1)
                for var section in payload.sections {
                    section.firstSegment = min(max(section.firstSegment, windowRange.lowerBound), windowRange.upperBound)
                    section.lastSegment = min(max(section.lastSegment, windowRange.lowerBound), windowRange.upperBound)
                    sections.append(section)
                }
            }
        } catch let error as AIServiceError where error == .cancelled {
            throw error
        } catch let error as AIServiceError where !error.isRetryable && !Self.isFatal(error) {
            // Scaletta non ottenibile (rifiuto o JSON non valido): si ripiega
            // su sezioni temporali, segnalandolo in modo trasparente.
            notes.append("Analisi tematica non riuscita (\(error.userMessage)): la lezione è stata divisa in parti di durata simile.")
            sections = Self.timeBasedSections(segments: segments, maxCharacters: configuration.maxSectionCharacters)
        }
        let outline = OutlineNormalizer.normalize(LessonOutline(lessonTitle: lessonTitle, sections: sections, normalizationNotes: notes), segmentCount: segments.count, fallbackTitle: context.lessonTitle)
        return (outline, usage)
    }

    static func isFatal(_ error: AIServiceError) -> Bool {
        switch error {
        case .invalidCredentials, .missingCredentials, .quotaExceeded, .permissionDenied, .cancelled: return true
        default: return false
        }
    }

    static func timeBasedSections(segments: [TranscriptSegmentDTO], maxCharacters: Int) -> [OutlineSection] {
        TranscriptFormatter.windows(segments, budget: max(4000, maxCharacters / 2)).enumerated().map { index, window in
            let start = TranscriptFormatter.timestamp(segments[window.lowerBound].start)
            return OutlineSection(title: "Parte \(index + 1) (dal minuto \(start))", firstSegment: window.lowerBound, lastSegment: window.upperBound - 1)
        }
    }

    // MARK: - C + E. Sezione

    private func produceSection(
        order: Int,
        outline: LessonOutline,
        segments: [TranscriptSegmentDTO],
        context: LessonContext,
        mode: SbobinaturaMode,
        previousTail: String?,
        extraInstructions: String?,
        progress: @Sendable (SbobinaturaProgress.Phase, String) -> Void,
        onText: (@Sendable (String) -> Void)?
    ) async -> GeneratedSectionDTO {
        let outlineSection = outline.sections[order]
        let range = outlineSection.segmentRange
        let source = Array(segments[range])
        let timeRange = (source.first?.start ?? 0)...(source.last?.end ?? 0)
        var usage = GenerationUsage()
        do {
            progress(.writing, "Scrittura di «\(outlineSection.title)»")
            let (written, writeUsage) = try await writeSection(outlineSection: outlineSection, outline: outline, segments: segments, context: context, mode: mode, previousTail: previousTail, extraInstructions: extraInstructions, onText: onText)
            usage = usage + writeUsage
            var markdown = written
            var verification = SectionVerification(status: .notVerified, sourceWordCount: source.reduce(0) { $0 + TextTokenizer.wordCount($1.text) }, outputWordCount: TextTokenizer.wordCount(SourceMarkers.stripForExport(markdown, keepUncertain: false)))

            if configuration.verifyWithModel {
                progress(.verifying, "Verifica di «\(outlineSection.title)»")
                let (checked, verifyUsage) = await verifySection(markdown: markdown, source: source, context: context, mode: mode)
                usage = usage + verifyUsage
                verification = checked
                if configuration.autoRepair, mode != .riassunto, Self.needsRepair(verification) {
                    progress(.repairing, "Correzione di «\(outlineSection.title)»")
                    do {
                        let (repaired, repairUsage) = try await repairSection(markdown: markdown, issues: verification.issues, source: source, context: context, title: outlineSection.title)
                        usage = usage + repairUsage
                        markdown = repaired
                        if configuration.reverifyAfterRepair {
                            let (rechecked, recheckUsage) = await verifySection(markdown: markdown, source: source, context: context, mode: mode)
                            usage = usage + recheckUsage
                            verification = rechecked
                        } else {
                            verification = Self.markRepaired(verification, newMarkdown: markdown, source: source, context: context, mode: mode, minimumRatio: configuration.minimumIntegralLengthRatio)
                        }
                    } catch {
                        // La correzione è facoltativa: si mantiene il testo
                        // originale con i problemi segnalati.
                    }
                }
            } else {
                verification = Self.localVerification(markdown: markdown, source: source, context: context, mode: mode, minimumRatio: configuration.minimumIntegralLengthRatio)
            }

            return GeneratedSectionDTO(order: order, title: outlineSection.title, markdown: markdown, segmentRange: range, timeRange: timeRange, state: .generated, verification: verification, model: provider.model, promptVersion: prompts.effectiveVersion, usage: usage)
        } catch {
            let mapped = AIServiceError.from(error, provider: provider.displayName)
            let message = mapped.userMessage
            let markdown = "## \(outlineSection.title)\n\n> ⚠️ Questa sezione non è stata generata: \(message) Usa «Rigenera sezione» per riprovare. I contenuti sono nella trascrizione originale (\(TranscriptFormatter.timestamp(timeRange.lowerBound))–\(TranscriptFormatter.timestamp(timeRange.upperBound)))."
            return GeneratedSectionDTO(order: order, title: outlineSection.title, markdown: markdown, segmentRange: range, timeRange: timeRange, state: .failed, errorMessage: message, verification: SectionVerification(status: .failed), model: provider.model, promptVersion: prompts.effectiveVersion, usage: usage)
        }
    }

    func writeSection(outlineSection: OutlineSection, outline: LessonOutline, segments: [TranscriptSegmentDTO], context: LessonContext, mode: SbobinaturaMode, previousTail: String?, extraInstructions: String?, onText: (@Sendable (String) -> Void)?) async throws -> (String, GenerationUsage) {
        let parts = OutlineNormalizer.parts(of: outlineSection.segmentRange, segments: segments, maxCharacters: configuration.maxSectionCharacters)
        var usage = GenerationUsage()
        var pieces: [String] = []
        var tail = previousTail
        let streamedSoFar = TextBox()
        for (partIndex, part) in parts.enumerated() {
            let partNote = parts.count > 1
                ? "Questa è la parte \(partIndex + 1) di \(parts.count) della sezione." + (partIndex > 0 ? " Prosegui il discorso della parte precedente senza ripeterne il contenuto." : "")
                : ""
            let (text, partUsage) = try await writePart(range: part, outlineSection: outlineSection, outline: outline, segments: segments, context: context, mode: mode, previousTail: tail, partNote: partNote, extraInstructions: extraInstructions, depth: 0, onText: { delta in
                streamedSoFar.append(delta)
                onText?(streamedSoFar.value)
            })
            usage = usage + partUsage
            pieces.append(partIndex == 0 ? text : EditorialNormalizer.removingSectionHeading(text))
            tail = Self.lastParagraph(of: text)
            streamedSoFar.append("\n\n")
        }
        let combined = pieces.joined(separator: "\n\n")
        return (EditorialNormalizer.normalizeSection(combined, title: outlineSection.title), usage)
    }

    private func writePart(range: ClosedRange<Int>, outlineSection: OutlineSection, outline: LessonOutline, segments: [TranscriptSegmentDTO], context: LessonContext, mode: SbobinaturaMode, previousTail: String?, partNote: String, extraInstructions: String?, depth: Int, onText: @escaping @Sendable (String) -> Void) async throws -> (String, GenerationUsage) {
        let source = Array(segments[range])
        let sourceText = TranscriptFormatter.format(source)
        var instructions = ""
        if let user = context.userInstructions?.trimmingCharacters(in: .whitespacesAndNewlines), !user.isEmpty {
            instructions += "\nIndicazioni dello studente per questa materia: \(user)\n"
        }
        if let extra = extraInstructions?.trimmingCharacters(in: .whitespacesAndNewlines), !extra.isEmpty {
            instructions += "\nIndicazioni per questa rigenerazione: \(extra)\n"
        }
        let prompt = prompts.render(mode.sectionTemplate, [
            "MATERIA": context.subjectName,
            "TITOLO_LEZIONE": outline.lessonTitle.isEmpty ? context.lessonTitle : outline.lessonTitle,
            "SCALETTA": Self.outlineText(outline, highlighting: outlineSection.title),
            "TITOLO_SEZIONE": outlineSection.title,
            "NOTA_TITOLO": "",
            "PARTE": partNote.isEmpty ? "" : partNote + "\n",
            "ELEMENTI_CHIAVE": Self.keyItemsText(outlineSection.keyItems),
            "CONTESTO_PRECEDENTE": previousTail?.isEmpty == false ? previousTail! : "(inizio della lezione)",
            "GLOSSARIO": Self.glossaryText(context.glossary),
            "ISTRUZIONI_UTENTE": instructions,
            "TRASCRIZIONE": sourceText,
            "LINGUA": context.language
        ])
        let expectedTokens = Int(Double(sourceText.count) * mode.expectedOutputRatio / 2.8)
        let maxTokens = min(64_000, max(8_000, expectedTokens * 2))
        let result = try await call(GenerationRequest(system: systemPrompt(context), messages: [.user(prompt)], maxOutputTokens: maxTokens, effort: configuration.writingEffort, stream: true), onTextDelta: onText)
        switch result.stopReason {
        case .refusal:
            throw AIServiceError.refused(category: result.refusalCategory)
        case .maxTokens where depth < 3 && range.count > 1:
            // Output troncato: si divide la parte a metà e si riprova, così
            // nessun contenuto viene perso per un limite di lunghezza.
            let middle = range.lowerBound + range.count / 2
            let first = range.lowerBound...(middle - 1)
            let second = middle...range.upperBound
            let (a, usageA) = try await writePart(range: first, outlineSection: outlineSection, outline: outline, segments: segments, context: context, mode: mode, previousTail: previousTail, partNote: partNote, extraInstructions: extraInstructions, depth: depth + 1, onText: onText)
            let (b, usageB) = try await writePart(range: second, outlineSection: outlineSection, outline: outline, segments: segments, context: context, mode: mode, previousTail: Self.lastParagraph(of: a), partNote: "Prosegui la sezione dal punto in cui si interrompe il testo precedente, senza ripeterlo.", extraInstructions: extraInstructions, depth: depth + 1, onText: onText)
            return (a + "\n\n" + EditorialNormalizer.removingSectionHeading(b), result.usage + usageA + usageB)
        case .maxTokens:
            throw AIServiceError.truncated
        default:
            guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AIServiceError.decoding("Il modello ha restituito un testo vuoto")
            }
            // Normalizza subito ogni parte (preamboli, titoli), così l'unione
            // di più parti non duplica titoli né introduzioni.
            return (EditorialNormalizer.normalizeSection(result.text, title: outlineSection.title), result.usage)
        }
    }

    // MARK: - E. Verifica

    func verifySection(markdown: String, source: [TranscriptSegmentDTO], context: LessonContext, mode: SbobinaturaMode) async -> (SectionVerification, GenerationUsage) {
        var verification = Self.localVerification(markdown: markdown, source: source, context: context, mode: mode, minimumRatio: configuration.minimumIntegralLengthRatio)
        let prompt = prompts.render(.verify, [
            "MATERIA": context.subjectName,
            "TRASCRIZIONE": TranscriptFormatter.format(source),
            "SEZIONE": markdown
        ])
        do {
            let result = try await call(GenerationRequest(system: "Sei un revisore accurato di testi universitari. Rispondi solo con il JSON richiesto.", messages: [.user(prompt)], maxOutputTokens: 8_000, jsonSchema: SbobinaturaSchemas.verification, effort: configuration.verificationEffort, stream: false))
            let payload = try SbobinaturaSchemas.decodeVerification(result.text)
            let modelIssues = payload.issues.map { issue in
                VerificationIssue(type: VerificationIssueType(rawValue: issue.type) ?? .other,
                                  severity: VerificationSeverity(rawValue: issue.severity) ?? .medium,
                                  description: issue.description, sourceSegments: issue.sourceSegments, excerpt: issue.excerpt)
            }
            verification.issues = modelIssues + verification.issues
            verification.unverifiable = payload.unverifiable
            verification.status = verification.issues.isEmpty ? .noIssuesFound : .issuesFound
            return (verification, result.usage)
        } catch {
            verification.unverifiable.append("Verifica con il modello non riuscita: \(AIServiceError.from(error, provider: provider.displayName).userMessage)")
            verification.status = verification.issues.isEmpty ? .notVerified : .issuesFound
            return (verification, GenerationUsage())
        }
    }

    static func localVerification(markdown: String, source: [TranscriptSegmentDTO], context: LessonContext, mode: SbobinaturaMode, minimumRatio: Double) -> SectionVerification {
        let sourceWords = source.reduce(0) { $0 + TextTokenizer.wordCount($1.text) }
        let outputWords = TextTokenizer.wordCount(SourceMarkers.stripForExport(markdown, keepUncertain: false))
        var issues: [VerificationIssue] = []
        if mode != .riassunto {
            issues += FactConsistencyChecker.issues(from: FactConsistencyChecker.check(source: source, output: markdown, glossary: context.glossary))
        }
        if mode == .integrale, sourceWords >= 150, Double(outputWords) / Double(max(1, sourceWords)) < minimumRatio {
            issues.append(VerificationIssue(type: .omission, severity: .medium,
                                            description: "Il testo prodotto (\(outputWords) parole) è molto più breve della trascrizione (\(sourceWords) parole): possibile compressione eccessiva.",
                                            sourceSegments: source.first.map { [$0.index] } ?? []))
        }
        if let first = source.first?.index, let last = source.last?.index {
            let invalid = SourceMarkers.invalidReferences(in: markdown, allowed: first...last)
            if !invalid.isEmpty {
                issues.append(VerificationIssue(type: .other, severity: .low, description: "Alcuni riferimenti ai segmenti non appartengono a questa sezione: i collegamenti all'audio potrebbero essere imprecisi."))
            }
        }
        return SectionVerification(status: issues.isEmpty ? .noIssuesFound : .issuesFound, issues: issues, sourceWordCount: sourceWords, outputWordCount: outputWords)
    }

    static func needsRepair(_ verification: SectionVerification) -> Bool {
        verification.issues.contains { issue in
            issue.type != .heuristicMissingFact && (issue.severity == .high || (issue.severity == .medium && [.omission, .alteredValue, .dateChanged, .nameChanged, .wrongCorrection].contains(issue.type)))
        }
    }

    static func markRepaired(_ verification: SectionVerification, newMarkdown: String, source: [TranscriptSegmentDTO], context: LessonContext, mode: SbobinaturaMode, minimumRatio: Double) -> SectionVerification {
        let local = localVerification(markdown: newMarkdown, source: source, context: context, mode: mode, minimumRatio: minimumRatio)
        var modelIssues = verification.issues.filter { $0.type != .heuristicMissingFact && !($0.type == .omission && $0.description.contains("possibile compressione")) }
        for index in modelIssues.indices { modelIssues[index].repairAttempted = true }
        var result = verification
        result.issues = modelIssues + local.issues
        result.outputWordCount = local.outputWordCount
        result.status = .repairedNeedsReview
        return result
    }

    func repairSection(markdown: String, issues: [VerificationIssue], source: [TranscriptSegmentDTO], context: LessonContext, title: String) async throws -> (String, GenerationUsage) {
        let issueText = issues.filter { $0.type != .heuristicMissingFact }.enumerated().map { index, issue in
            "\(index + 1). [\(issue.type.rawValue), \(issue.severity.rawValue)] \(issue.description)" + (issue.sourceSegments.isEmpty ? "" : " (segmenti: \(issue.sourceSegments.map { "S\($0)" }.joined(separator: ", ")))")
        }.joined(separator: "\n")
        let prompt = prompts.render(.repair, [
            "PROBLEMI": issueText,
            "TRASCRIZIONE": TranscriptFormatter.format(source),
            "SEZIONE": markdown
        ])
        let sourceChars = source.reduce(0) { $0 + $1.text.count }
        let result = try await call(GenerationRequest(system: systemPrompt(context), messages: [.user(prompt)], maxOutputTokens: min(64_000, max(8_000, sourceChars / 2)), effort: configuration.writingEffort, stream: true))
        guard result.stopReason == .complete, !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIServiceError.truncated
        }
        let repaired = EditorialNormalizer.normalizeSection(result.text, title: title)
        // Salvaguardia: una "correzione" che accorcia molto il testo viene
        // scartata, perché probabilmente ha perso contenuto.
        let before = TextTokenizer.wordCount(markdown)
        let after = TextTokenizer.wordCount(repaired)
        guard Double(after) >= Double(before) * 0.85 else {
            throw AIServiceError.decoding("La correzione automatica ha accorciato il testo: scartata")
        }
        return (repaired, result.usage)
    }

    // MARK: - Utilità

    private func call(_ request: GenerationRequest, onTextDelta: (@Sendable (String) -> Void)? = nil) async throws -> GenerationResult {
        let provider = self.provider
        return try await retryPolicy.run(provider: provider.displayName) {
            try await provider.generate(request, onTextDelta: onTextDelta)
        }
    }

    func systemPrompt(_ context: LessonContext) -> String {
        prompts.render(.system, ["LINGUA": context.language])
    }

    static func glossaryText(_ glossary: [String]) -> String {
        glossary.isEmpty ? "(nessun glossario)" : glossary.map { "- \($0)" }.joined(separator: "\n")
    }

    static func keyItemsText(_ items: [OutlineKeyItem]) -> String {
        items.isEmpty ? "(nessuno individuato: basati sulla trascrizione)" : items.map { "- [\($0.kind)] \($0.text)" }.joined(separator: "\n")
    }

    static func outlineText(_ outline: LessonOutline, highlighting title: String) -> String {
        outline.sections.enumerated().map { index, section in
            let marker = section.title == title ? " ← sezione da scrivere" : ""
            let summary = section.summary.isEmpty ? "" : " — \(section.summary)"
            return "\(index + 1). \(section.title)\(summary)\(marker)"
        }.joined(separator: "\n")
    }

    static func lastParagraph(of markdown: String) -> String {
        let paragraphs = markdown.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
        return String((paragraphs.last ?? "").suffix(1500))
    }

    static func header(title: String, context: LessonContext, mode: SbobinaturaMode, model: String, duration: TimeInterval) -> String {
        var lines = ["# \(title)", ""]
        var meta = ["**Materia:** \(context.subjectName)"]
        if let date = context.lessonDate {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "it_IT")
            formatter.dateStyle = .long
            formatter.timeStyle = .none
            meta.append("**Data:** \(formatter.string(from: date))")
        }
        if duration > 0 { meta.append("**Durata della registrazione:** \(TranscriptFormatter.timestamp(duration))") }
        meta.append("**Tipo:** \(mode.displayName)")
        lines.append(meta.joined(separator: "  \n"))
        lines.append("")
        lines.append("> Documento generato con un modello AI (\(model)) a partire dalla trascrizione automatica. I passaggi segnalati come incerti e gli avvisi dei controlli di completezza vanno ricontrollati sull'audio: i controlli automatici non garantiscono l'assenza di omissioni o errori.")
        return lines.joined(separator: "\n")
    }
}

/// Contenitore thread-safe per accumulare testo in streaming.
final class TextBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = ""

    func append(_ text: String) {
        lock.lock()
        storage += text
        lock.unlock()
    }

    var value: String {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
