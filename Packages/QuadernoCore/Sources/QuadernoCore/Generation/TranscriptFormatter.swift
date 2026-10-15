import Foundation

/// Passaggio A — Preparazione: normalizza la trascrizione in righe numerate
/// con riferimenti temporali e interlocutori, il formato citato dai prompt.
public enum TranscriptFormatter {
    public static func timestamp(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, secs)
    }

    public static func line(for segment: TranscriptSegmentDTO) -> String {
        var header = "S\(segment.index) | \(timestamp(segment.start))"
        if let speaker = segment.speaker, !speaker.isEmpty {
            header += " | \(speaker)"
        }
        let text = segment.text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "[\(header)] \(text)"
    }

    public static func format(_ segments: [TranscriptSegmentDTO]) -> String {
        segments.map(line(for:)).joined(separator: "\n")
    }

    public static func characterCount(_ segments: ArraySlice<TranscriptSegmentDTO>) -> Int {
        segments.reduce(0) { $0 + $1.text.count + 24 }
    }

    /// Divide gli indici dei segmenti in finestre consecutive che non superano
    /// `budget` caratteri (almeno un segmento per finestra).
    public static func windows(_ segments: [TranscriptSegmentDTO], budget: Int) -> [Range<Int>] {
        var windows: [Range<Int>] = []
        var start = 0
        var size = 0
        for (offset, segment) in segments.enumerated() {
            let cost = segment.text.count + 24
            if size + cost > budget, offset > start {
                windows.append(start..<offset)
                start = offset
                size = 0
            }
            size += cost
        }
        if start < segments.count { windows.append(start..<segments.count) }
        return windows
    }
}

/// Valida e ripara la scaletta restituita dal modello, garantendo che le
/// sezioni coprano tutti i segmenti in modo contiguo.
public enum OutlineNormalizer {
    public static func normalize(_ outline: LessonOutline, segmentCount: Int, fallbackTitle: String) -> LessonOutline {
        guard segmentCount > 0 else {
            return LessonOutline(lessonTitle: outline.lessonTitle.isEmpty ? fallbackTitle : outline.lessonTitle, sections: [], normalizationNotes: outline.normalizationNotes)
        }
        var notes = outline.normalizationNotes
        let last = segmentCount - 1
        var sections = outline.sections
            .map { section -> OutlineSection in
                var section = section
                section.firstSegment = min(max(0, section.firstSegment), last)
                section.lastSegment = min(max(0, section.lastSegment), last)
                if section.lastSegment < section.firstSegment {
                    swap(&section.firstSegment, &section.lastSegment)
                }
                section.title = section.title.trimmingCharacters(in: .whitespacesAndNewlines)
                if section.title.isEmpty { section.title = "Sezione" }
                return section
            }
            .sorted { ($0.firstSegment, $0.lastSegment) < ($1.firstSegment, $1.lastSegment) }

        if sections.isEmpty {
            notes.append("La scaletta non conteneva sezioni: è stata creata una sezione unica.")
            return LessonOutline(lessonTitle: outline.lessonTitle.isEmpty ? fallbackTitle : outline.lessonTitle,
                                 sections: [OutlineSection(title: fallbackTitle, firstSegment: 0, lastSegment: last)],
                                 normalizationNotes: notes)
        }

        var result: [OutlineSection] = []
        for var section in sections {
            if let previous = result.last {
                let expectedStart = previous.lastSegment + 1
                if section.lastSegment <= previous.lastSegment {
                    // Sezione interamente contenuta nella precedente: si
                    // fondono gli elementi chiave per non perderli.
                    notes.append("Sezione «\(section.title)» sovrapposta alla precedente: unita.")
                    result[result.count - 1].keyItems.append(contentsOf: section.keyItems)
                    continue
                }
                if section.firstSegment > expectedStart {
                    notes.append("Segmenti S\(expectedStart)–S\(section.firstSegment - 1) non assegnati: aggiunti a «\(previous.title)».")
                    result[result.count - 1].lastSegment = section.firstSegment - 1
                } else if section.firstSegment < expectedStart {
                    notes.append("Sezione «\(section.title)» sovrapposta: inizio spostato a S\(expectedStart).")
                    section.firstSegment = expectedStart
                }
            } else if section.firstSegment > 0 {
                notes.append("Segmenti iniziali S0–S\(section.firstSegment - 1) assegnati alla prima sezione.")
                section.firstSegment = 0
            }
            result.append(section)
        }
        if let lastSection = result.last, lastSection.lastSegment < last {
            notes.append("Segmenti finali S\(lastSection.lastSegment + 1)–S\(last) assegnati all'ultima sezione.")
            result[result.count - 1].lastSegment = last
        }
        sections = result
        return LessonOutline(lessonTitle: outline.lessonTitle.isEmpty ? fallbackTitle : outline.lessonTitle, sections: sections, normalizationNotes: notes)
    }

    /// Divide l'intervallo di una sezione in parti consecutive entro il
    /// budget di caratteri, per sezioni molto lunghe.
    public static func parts(of range: ClosedRange<Int>, segments: [TranscriptSegmentDTO], maxCharacters: Int) -> [ClosedRange<Int>] {
        let slice = Array(segments[range])
        let windows = TranscriptFormatter.windows(slice, budget: maxCharacters)
        return windows.map { (range.lowerBound + $0.lowerBound)...(range.lowerBound + $0.upperBound - 1) }
    }
}

/// Marcatori inline usati nella sbobinatura:
/// - `[[S12-S15]]` / `[[S12]]` riferimenti ai segmenti sorgente;
/// - `[[incerto: ...]]` passaggi incerti.
public enum SourceMarkers {
    public struct Reference: Equatable, Sendable {
        public var range: ClosedRange<Int>
        public var location: Range<String.Index>
    }

    static let referencePattern = #"\[\[\s*S(\d+)\s*(?:[-–—]\s*S?(\d+))?\s*\]\]"#
    static let uncertainPattern = #"\[\[\s*(?:incerto|uncertain)\s*:\s*([^\]]*?)\s*\]\]"#

    public static func references(in text: String) -> [Reference] {
        guard let regex = try? NSRegularExpression(pattern: referencePattern) else { return [] }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: nsRange).compactMap { match in
            guard let whole = Range(match.range, in: text),
                  let firstRange = Range(match.range(at: 1), in: text),
                  let first = Int(text[firstRange]) else { return nil }
            var second = first
            if let secondRange = Range(match.range(at: 2), in: text), let value = Int(text[secondRange]) {
                second = value
            }
            return Reference(range: min(first, second)...max(first, second), location: whole)
        }
    }

    public static func uncertainPassages(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: uncertainPattern, options: [.caseInsensitive]) else { return [] }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: nsRange).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    /// Rimuove i riferimenti ai segmenti (per esportazione e lettura) e
    /// trasforma i passaggi incerti in una forma leggibile.
    public static func stripForExport(_ text: String, keepUncertain: Bool = true) -> String {
        var result = text
        if let regex = try? NSRegularExpression(pattern: #"[ \t]*"# + referencePattern) {
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..<result.endIndex, in: result), withTemplate: "")
        }
        if let regex = try? NSRegularExpression(pattern: uncertainPattern, options: [.caseInsensitive]) {
            let template = keepUncertain ? "[incerto: $1]" : "$1"
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..<result.endIndex, in: result), withTemplate: template)
        }
        return result
    }

    /// Riferimenti a segmenti inesistenti (possibile allucinazione del
    /// modello sui riferimenti).
    public static func invalidReferences(in text: String, allowed: ClosedRange<Int>) -> [ClosedRange<Int>] {
        references(in: text).map(\.range).filter { !allowed.contains($0.lowerBound) || !allowed.contains($0.upperBound) }
    }
}

/// Passaggio F (parte deterministica) — Controllo editoriale locale:
/// uniforma titoli e spaziature senza toccare il contenuto.
public enum EditorialNormalizer {
    static let preamblePrefixes = [
        "ecco la sbobinatura", "ecco la trascrizione", "ecco il riassunto", "di seguito", "certamente", "ecco la sezione", "ecco il testo"
    ]

    public static func normalizeSection(_ markdown: String, title: String, titleNote: String = "") -> String {
        var lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        // Rimuove eventuali preamboli prima del primo titolo.
        while let first = lines.first {
            let trimmed = first.trimmingCharacters(in: .whitespaces)
            let lower = trimmed.lowercased()
            if trimmed.isEmpty || (!trimmed.hasPrefix("#") && preamblePrefixes.contains { lower.hasPrefix($0) } && trimmed.count < 200) {
                lines.removeFirst()
            } else {
                break
            }
        }
        // Rimuove un eventuale blocco ``` che racchiude l'intero output.
        if let first = lines.first, first.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
            lines.removeFirst()
            if let lastIndex = lines.lastIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
               lines[lastIndex].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                lines.remove(at: lastIndex)
            }
        }
        // Il primo titolo diventa il titolo di sezione (##); i titoli
        // successivi di livello 1-2 scendono a ###.
        var sawSectionHeading = false
        for index in lines.indices {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("#") else { continue }
            let level = trimmed.prefix(while: { $0 == "#" }).count
            let text = trimmed.dropFirst(level).trimmingCharacters(in: .whitespaces)
            if !sawSectionHeading && index == firstContentIndex(lines) {
                lines[index] = "## " + text
                sawSectionHeading = true
            } else if level <= 2 {
                lines[index] = "### " + text
            } else if level > 4 {
                lines[index] = "#### " + text
            }
        }
        if !sawSectionHeading {
            lines.insert("## " + title + titleNote, at: 0)
            lines.insert("", at: 1)
        }
        // Al massimo una riga vuota consecutiva.
        var collapsed: [String] = []
        for line in lines {
            let isBlank = line.trimmingCharacters(in: .whitespaces).isEmpty
            if isBlank, let last = collapsed.last, last.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            collapsed.append(line.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression))
        }
        while let last = collapsed.last, last.isEmpty { collapsed.removeLast() }
        return collapsed.joined(separator: "\n")
    }

    static func firstContentIndex(_ lines: [String]) -> Int {
        lines.firstIndex { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? 0
    }

    /// Estrae il titolo `##` di una sezione.
    public static func sectionTitle(of markdown: String) -> String? {
        for line in markdown.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("## ") { return String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces) }
            if !trimmed.isEmpty { return nil }
        }
        return nil
    }

    /// Rimuove il titolo `##` iniziale (per unire più parti di una sezione).
    public static func removingSectionHeading(_ markdown: String) -> String {
        var lines = markdown.components(separatedBy: "\n")
        if let index = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
           lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("## ") {
            lines.remove(at: index)
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Controllo locale euristico (gratuito, senza rete): numeri, anni e nomi
/// propri presenti nella trascrizione che non compaiono nel testo prodotto.
/// Produce segnalazioni "da controllare", mai certezze: un numero può essere
/// stato legittimamente scritto in lettere o un nome declinato.
public enum FactConsistencyChecker {
    public struct Finding: Equatable, Sendable {
        public var fact: String
        public var kind: Kind
        public var segmentIndex: Int
    }

    public enum Kind: String, Sendable {
        case number
        case properNoun
        case glossaryTerm
    }

    static let italianNumberWords: [String: String] = [
        "uno": "1", "due": "2", "tre": "3", "quattro": "4", "cinque": "5", "sei": "6", "sette": "7", "otto": "8", "nove": "9", "dieci": "10",
        "undici": "11", "dodici": "12", "venti": "20", "trenta": "30", "cento": "100", "mille": "1000"
    ]

    static let commonCapitalized: Set<String> = [
        "allora", "quindi", "però", "pero", "poi", "ecco", "cioè", "cioe", "infatti", "dunque", "anche", "questo", "questa", "questi", "queste", "quello", "quella",
        "il", "lo", "la", "i", "gli", "le", "un", "una", "uno", "e", "ed", "ma", "o", "se", "che", "non", "si", "sì", "no", "per", "con", "in", "di", "da", "su", "a",
        "io", "tu", "lui", "lei", "noi", "voi", "loro", "ok", "okay", "bene", "va", "adesso", "ora", "oggi", "ieri", "domani", "come", "dove", "quando", "perché", "perche",
        "the", "and", "so", "s", "professore", "professoressa", "prof", "domanda", "risposta", "esatto", "vabbè", "insomma", "comunque", "invece", "mentre", "proprio",
        "lunedì", "martedì", "mercoledì", "giovedì", "venerdì", "sabato", "domenica"
    ]

    public static func check(source: [TranscriptSegmentDTO], output: String, glossary: [String] = []) -> [Finding] {
        let outputTokens = Set(TextTokenizer.tokens(SourceMarkers.stripForExport(output, keepUncertain: false)))
        let outputNormalizedText = TextTokenizer.tokens(output).joined(separator: " ")
        var findings: [Finding] = []
        var seen = Set<String>()

        for segment in source {
            let words = TextTokenizer.whitespaceWords(segment.text)
            for (position, word) in words.enumerated() {
                let normalized = TextTokenizer.normalize(word)
                guard !normalized.isEmpty, !seen.contains(normalized) else { continue }
                // Numeri (incluse le date): almeno due cifre o anni.
                if normalized.allSatisfy(\.isNumber) {
                    guard normalized.count >= 2 else { continue }
                    seen.insert(normalized)
                    if !outputTokens.contains(normalized) && !outputNormalizedText.contains(normalized) {
                        findings.append(Finding(fact: String(word).trimmingCharacters(in: .punctuationCharacters), kind: .number, segmentIndex: segment.index))
                    }
                    continue
                }
                // Nomi propri: parola maiuscola non a inizio frase.
                guard let first = word.first, first.isUppercase, normalized.count >= 3 else { continue }
                let previous = position > 0 ? words[position - 1] : ""
                let sentenceStart = position == 0 || previous.last.map { ".?!:…\"«".contains($0) } == true
                guard !sentenceStart, !commonCapitalized.contains(normalized) else { continue }
                seen.insert(normalized)
                if !outputTokens.contains(normalized) && !containsStem(normalized, in: outputTokens) {
                    findings.append(Finding(fact: String(word).trimmingCharacters(in: .punctuationCharacters), kind: .properNoun, segmentIndex: segment.index))
                }
            }
        }

        let sourceText = TextTokenizer.tokens(source.map(\.text).joined(separator: " ")).joined(separator: " ")
        for term in glossary {
            let normalizedTerm = TextTokenizer.tokens(term).joined(separator: " ")
            guard !normalizedTerm.isEmpty, !seen.contains(normalizedTerm) else { continue }
            seen.insert(normalizedTerm)
            if sourceText.contains(normalizedTerm) && !outputNormalizedText.contains(normalizedTerm) {
                let segmentIndex = source.first { TextTokenizer.tokens($0.text).joined(separator: " ").contains(normalizedTerm) }?.index ?? source.first?.index ?? 0
                findings.append(Finding(fact: term, kind: .glossaryTerm, segmentIndex: segmentIndex))
            }
        }
        return findings
    }

    /// Accetta forme flesse (es. "Gropius" vs "Gropiusiano" o plurali) se
    /// condividono le prime lettere.
    static func containsStem(_ word: String, in tokens: Set<String>) -> Bool {
        guard word.count >= 5 else { return false }
        let stem = String(word.prefix(word.count - 1))
        return tokens.contains { $0.hasPrefix(stem) }
    }

    public static func issues(from findings: [Finding]) -> [VerificationIssue] {
        findings.map { finding in
            let what: String
            switch finding.kind {
            case .number: what = "Il numero o la data «\(finding.fact)»"
            case .properNoun: what = "Il nome «\(finding.fact)»"
            case .glossaryTerm: what = "Il termine del glossario «\(finding.fact)»"
            }
            return VerificationIssue(type: .heuristicMissingFact, severity: finding.kind == .properNoun ? .low : .medium,
                                     description: "\(what) compare nella trascrizione (S\(finding.segmentIndex)) ma non è stato ritrovato nel testo. Potrebbe essere stato scritto in altra forma: verifica.",
                                     sourceSegments: [finding.segmentIndex], excerpt: finding.fact)
        }
    }
}
