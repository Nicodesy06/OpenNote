import Foundation

/// Utilità testuali condivise da merge, verifica e statistiche.
public enum TextTokenizer {
    /// Normalizza una parola per il confronto: minuscole, senza accenti e
    /// senza punteggiatura. Le cifre vengono preservate.
    public static func normalize(_ word: Substring) -> String {
        normalize(String(word))
    }

    public static func normalize(_ word: String) -> String {
        let folded = word.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "it_IT"))
        var result = ""
        result.reserveCapacity(folded.count)
        for scalar in folded.unicodeScalars where CharacterSet.alphanumerics.contains(scalar) {
            result.unicodeScalars.append(scalar)
        }
        return result
    }

    /// Divide in parole su spazi bianchi, preservando la punteggiatura
    /// attaccata alle parole.
    public static func whitespaceWords(_ text: String) -> [Substring] {
        text.split(whereSeparator: { $0.isWhitespace })
    }

    /// Token normalizzati non vuoti.
    public static func tokens(_ text: String) -> [String] {
        whitespaceWords(text).map(normalize).filter { !$0.isEmpty }
    }

    public static func wordCount(_ text: String) -> Int {
        tokens(text).count
    }

    /// Divide un testo in frasi. Conservativo: taglia dopo . ? ! … seguiti da
    /// spazio e da una lettera maiuscola, una cifra o un'apertura di virgolette.
    public static func sentences(_ text: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        let characters = Array(text)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            current.append(character)
            if ".?!…".contains(character) {
                var lookahead = index + 1
                // Include eventuali virgolette o parentesi di chiusura.
                while lookahead < characters.count, "\"”»)’'".contains(characters[lookahead]) {
                    current.append(characters[lookahead])
                    lookahead += 1
                }
                if lookahead < characters.count, characters[lookahead].isWhitespace {
                    var next = lookahead
                    while next < characters.count, characters[next].isWhitespace { next += 1 }
                    if next >= characters.count || characters[next].isUppercase || characters[next].isNumber || "\"“«(".contains(characters[next]) {
                        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty { sentences.append(trimmed) }
                        current = ""
                        index = next
                        continue
                    }
                }
                index = lookahead
                continue
            }
            index += 1
        }
        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { sentences.append(trimmed) }
        return sentences
    }
}
