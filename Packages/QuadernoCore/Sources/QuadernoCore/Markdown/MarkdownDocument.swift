import Foundation

/// Sottoinsieme di Markdown usato dalle sbobinature: titoli, paragrafi,
/// grassetto, corsivo, elenchi, citazioni, tabelle, immagini e i marcatori
/// propri dell'app (`[[S12-S15]]`, `[[incerto: ...]]`). Lo stesso albero è
/// usato dall'editor (anteprima), dall'export PDF e dall'export DOCX.
public indirect enum MarkdownInline: Equatable, Sendable {
    case text(String)
    case bold([MarkdownInline])
    case italic([MarkdownInline])
    case code(String)
    case link(text: [MarkdownInline], url: String)
    case sourceReference(ClosedRange<Int>)
    case uncertain(String)
    case lineBreak

    /// Testo semplice (senza riferimenti ai segmenti).
    public var plainText: String {
        switch self {
        case .text(let value): return value
        case .bold(let children), .italic(let children): return children.map(\.plainText).joined()
        case .code(let value): return value
        case .link(let text, _): return text.map(\.plainText).joined()
        case .sourceReference: return ""
        case .uncertain(let value): return "[incerto: \(value)]"
        case .lineBreak: return "\n"
        }
    }
}

public enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, content: [MarkdownInline])
    case paragraph([MarkdownInline])
    case bulletList([[MarkdownInline]])
    case orderedList(start: Int, items: [[MarkdownInline]])
    case blockquote([MarkdownInline])
    case table(header: [[MarkdownInline]], rows: [[[MarkdownInline]]])
    case image(alt: String, source: String)
    case rule
}

public enum MarkdownParser {
    public static func parse(_ markdown: String) -> [MarkdownBlock] {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var index = 0

        func isBlank(_ line: String) -> Bool { line.trimmingCharacters(in: .whitespaces).isEmpty }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { index += 1; continue }

            // Titoli
            if trimmed.hasPrefix("#") {
                let level = trimmed.prefix(while: { $0 == "#" }).count
                let rest = trimmed.dropFirst(level)
                if level <= 6, rest.isEmpty || rest.first == " " {
                    blocks.append(.heading(level: level, content: parseInlines(rest.trimmingCharacters(in: .whitespaces))))
                    index += 1
                    continue
                }
            }
            // Linea orizzontale
            if ["---", "***", "___"].contains(trimmed.replacingOccurrences(of: " ", with: "")) && trimmed.count >= 3 {
                blocks.append(.rule)
                index += 1
                continue
            }
            // Immagine su riga propria
            if let image = parseImage(trimmed) {
                blocks.append(.image(alt: image.alt, source: image.source))
                index += 1
                continue
            }
            // Tabella: riga con | seguita da riga separatrice
            if trimmed.contains("|"), index + 1 < lines.count, isTableSeparator(lines[index + 1]) {
                let header = splitTableRow(trimmed).map(parseInlines)
                var rows: [[[MarkdownInline]]] = []
                index += 2
                while index < lines.count, lines[index].contains("|"), !isBlank(lines[index]) {
                    rows.append(splitTableRow(lines[index].trimmingCharacters(in: .whitespaces)).map(parseInlines))
                    index += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }
            // Citazione
            if trimmed.hasPrefix(">") {
                var parts: [String] = []
                while index < lines.count {
                    let current = lines[index].trimmingCharacters(in: .whitespaces)
                    guard current.hasPrefix(">") else { break }
                    parts.append(String(current.dropFirst()).trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                blocks.append(.blockquote(parseInlines(parts.joined(separator: " "))))
                continue
            }
            // Elenchi puntati
            if bulletContent(trimmed) != nil {
                var items: [[MarkdownInline]] = []
                var current: String?
                while index < lines.count {
                    let raw = lines[index]
                    let candidate = raw.trimmingCharacters(in: .whitespaces)
                    if let content = bulletContent(candidate) {
                        if let current { items.append(parseInlines(current)) }
                        current = content
                    } else if !isBlank(raw), raw.hasPrefix("  ") || raw.hasPrefix("\t"), current != nil {
                        current! += " " + candidate
                    } else {
                        break
                    }
                    index += 1
                }
                if let current { items.append(parseInlines(current)) }
                blocks.append(.bulletList(items))
                continue
            }
            // Elenchi numerati
            if let first = orderedContent(trimmed) {
                var items: [[MarkdownInline]] = []
                var current: String?
                while index < lines.count {
                    let raw = lines[index]
                    let candidate = raw.trimmingCharacters(in: .whitespaces)
                    if let content = orderedContent(candidate) {
                        if let current { items.append(parseInlines(current)) }
                        current = content.text
                    } else if !isBlank(raw), raw.hasPrefix("  ") || raw.hasPrefix("\t"), current != nil {
                        current! += " " + candidate
                    } else {
                        break
                    }
                    index += 1
                }
                if let current { items.append(parseInlines(current)) }
                blocks.append(.orderedList(start: first.number, items: items))
                continue
            }
            // Paragrafo: righe consecutive non vuote che non iniziano un
            // altro blocco.
            var paragraphLines: [String] = []
            while index < lines.count {
                let raw = lines[index]
                let candidate = raw.trimmingCharacters(in: .whitespaces)
                if candidate.isEmpty { break }
                if !paragraphLines.isEmpty && (candidate.hasPrefix("#") || candidate.hasPrefix(">") || bulletContent(candidate) != nil || orderedContent(candidate) != nil || parseImage(candidate) != nil) { break }
                // Due spazi finali o barra rovesciata = a capo esplicito.
                if raw.hasSuffix("  ") || raw.hasSuffix("\\") {
                    paragraphLines.append(candidate.trimmingCharacters(in: CharacterSet(charactersIn: "\\")) + "\u{2028}")
                } else {
                    paragraphLines.append(candidate)
                }
                index += 1
            }
            let text = paragraphLines.joined(separator: " ").replacingOccurrences(of: "\u{2028} ", with: "\u{2028}")
            blocks.append(.paragraph(parseInlines(text)))
        }
        return blocks
    }

    static func bulletContent(_ line: String) -> String? {
        for marker in ["- ", "* ", "+ ", "• "] where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count))
        }
        return nil
    }

    static func orderedContent(_ line: String) -> (number: Int, text: String)? {
        let digits = line.prefix(while: \.isNumber)
        guard !digits.isEmpty, digits.count <= 4 else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return (Int(digits) ?? 1, String(rest.dropFirst(2)))
    }

    static func parseImage(_ line: String) -> (alt: String, source: String)? {
        guard line.hasPrefix("!["), line.hasSuffix(")"),
              let closeBracket = line.range(of: "](") else { return nil }
        let alt = String(line[line.index(line.startIndex, offsetBy: 2)..<closeBracket.lowerBound])
        let source = String(line[closeBracket.upperBound..<line.index(before: line.endIndex)])
        guard !source.isEmpty, !alt.contains("]") else { return nil }
        return (alt, source)
    }

    static func isTableSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("-"), trimmed.contains("|") || trimmed.hasPrefix("-") else { return false }
        return trimmed.allSatisfy { "|-: ".contains($0) }
    }

    static func splitTableRow(_ line: String) -> [String] {
        var content = line
        if content.hasPrefix("|") { content.removeFirst() }
        if content.hasSuffix("|") { content.removeLast() }
        return content.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    // MARK: - Inline

    public static func parseInlines(_ text: String) -> [MarkdownInline] {
        let characters = Array(text)
        var result: [MarkdownInline] = []
        var buffer = ""
        var index = 0

        func flush() {
            if !buffer.isEmpty {
                result.append(.text(buffer))
                buffer = ""
            }
        }

        func find(_ delimiter: [Character], from start: Int) -> Int? {
            guard start < characters.count else { return nil }
            var position = start
            while position <= characters.count - delimiter.count {
                if Array(characters[position..<position + delimiter.count]) == delimiter {
                    return position
                }
                position += 1
            }
            return nil
        }

        while index < characters.count {
            let character = characters[index]

            if character == "\u{2028}" {
                flush()
                result.append(.lineBreak)
                index += 1
                continue
            }

            // Marcatori dell'app [[...]]
            if character == "[", index + 1 < characters.count, characters[index + 1] == "[", let close = find(["]", "]"], from: index + 2) {
                let inner = String(characters[(index + 2)..<close]).trimmingCharacters(in: .whitespaces)
                if let range = parseReference(inner) {
                    flush()
                    // Rimuove lo spazio prima del riferimento.
                    if case .text(let last)? = result.last, last.hasSuffix(" ") {
                        result[result.count - 1] = .text(String(last.dropLast()))
                    }
                    result.append(.sourceReference(range))
                    index = close + 2
                    continue
                }
                let lower = inner.lowercased()
                if lower.hasPrefix("incerto") || lower.hasPrefix("uncertain") {
                    flush()
                    var value = inner
                    if let colon = inner.firstIndex(of: ":") {
                        value = String(inner[inner.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                    } else {
                        value = ""
                    }
                    result.append(.uncertain(value))
                    index = close + 2
                    continue
                }
            }

            // Codice
            if character == "`", let close = find(["`"], from: index + 1) {
                flush()
                result.append(.code(String(characters[(index + 1)..<close])))
                index = close + 1
                continue
            }

            // Grassetto+corsivo / grassetto
            if character == "*" || character == "_" {
                let triple: [Character] = [character, character, character]
                let double: [Character] = [character, character]
                if index + 2 < characters.count, Array(characters[index..<index + 3]) == triple,
                   let close = find(triple, from: index + 3), close > index + 3 {
                    flush()
                    result.append(.bold([.italic(parseInlines(String(characters[(index + 3)..<close])))]))
                    index = close + 3
                    continue
                }
                if index + 1 < characters.count, Array(characters[index..<index + 2]) == double,
                   let close = find(double, from: index + 2), close > index + 2 {
                    flush()
                    result.append(.bold(parseInlines(String(characters[(index + 2)..<close]))))
                    index = close + 2
                    continue
                }
                // Corsivo singolo: il delimitatore di apertura deve precedere
                // un carattere non spazio; per "_" serve un confine di parola
                // (evita di interpretare nomi_file).
                let opensWord = index + 1 < characters.count && !characters[index + 1].isWhitespace
                let boundaryOK = character == "*" || index == 0 || !(characters[index - 1].isLetter || characters[index - 1].isNumber)
                if opensWord, boundaryOK, let close = find([character], from: index + 1), close > index + 1, !characters[close - 1].isWhitespace {
                    let afterOK = character == "*" || close + 1 >= characters.count || !(characters[close + 1].isLetter || characters[close + 1].isNumber)
                    if afterOK {
                        flush()
                        result.append(.italic(parseInlines(String(characters[(index + 1)..<close]))))
                        index = close + 1
                        continue
                    }
                }
            }

            // Link [testo](url)
            if character == "[", let closeBracket = find(["]"], from: index + 1),
               closeBracket + 1 < characters.count, characters[closeBracket + 1] == "(",
               let closeParen = find([")"], from: closeBracket + 2) {
                flush()
                let label = String(characters[(index + 1)..<closeBracket])
                let url = String(characters[(closeBracket + 2)..<closeParen])
                result.append(.link(text: parseInlines(label), url: url))
                index = closeParen + 1
                continue
            }

            buffer.append(character)
            index += 1
        }
        flush()
        return result
    }

    static func parseReference(_ inner: String) -> ClosedRange<Int>? {
        let pattern = #"^S(\d+)\s*(?:[-–—]\s*S?(\d+))?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: inner, range: NSRange(inner.startIndex..<inner.endIndex, in: inner)),
              let firstRange = Range(match.range(at: 1), in: inner),
              let first = Int(inner[firstRange]) else { return nil }
        var second = first
        if let secondRange = Range(match.range(at: 2), in: inner), let value = Int(inner[secondRange]) { second = value }
        return min(first, second)...max(first, second)
    }

    /// Testo semplice dell'intero documento (per ricerca e conteggi).
    public static func plainText(_ blocks: [MarkdownBlock]) -> String {
        blocks.map { block -> String in
            switch block {
            case .heading(_, let content), .paragraph(let content), .blockquote(let content):
                return content.map(\.plainText).joined()
            case .bulletList(let items), .orderedList(_, let items):
                return items.map { $0.map(\.plainText).joined() }.joined(separator: "\n")
            case .table(let header, let rows):
                return ([header] + rows).map { $0.map { $0.map(\.plainText).joined() }.joined(separator: "\t") }.joined(separator: "\n")
            case .image(let alt, _):
                return alt
            case .rule:
                return ""
            }
        }.joined(separator: "\n\n")
    }
}
