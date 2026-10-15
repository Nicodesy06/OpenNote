import UIKit
import QuadernoCore

/// Trasforma l'albero Markdown della sbobinatura in `NSAttributedString`,
/// usato per la lettura, il confronto con l'audio e l'export PDF.
struct MarkdownRenderer {
    struct Style {
        var baseSize: CGFloat = 17
        var serif = true
        var textColor: UIColor = .label
        var secondaryColor: UIColor = .secondaryLabel
        var accentColor: UIColor = .systemBlue
        var uncertainBackground: UIColor = UIColor.systemYellow.withAlphaComponent(0.35)
        /// Mostra i riferimenti ai segmenti come piccoli collegamenti
        /// (lettura/confronto); nell'export vengono omessi.
        var showSourceReferences = true
        var maxImageWidth: CGFloat = 600
        var maxImageHeight: CGFloat = 800

        static let print = Style(baseSize: 11.5, serif: true, textColor: .black, secondaryColor: .darkGray, accentColor: UIColor(red: 0.12, green: 0.23, blue: 0.54, alpha: 1), uncertainBackground: UIColor(red: 1, green: 0.95, blue: 0.6, alpha: 1), showSourceReferences: false, maxImageWidth: 460, maxImageHeight: 600)
    }

    var style = Style()
    /// Risolve il percorso di un'immagine Markdown.
    var imageResolver: ((String) -> UIImage?)?

    static let segmentURLScheme = "quaderno-segment"

    func render(_ markdown: String) -> NSAttributedString {
        render(MarkdownParser.parse(markdown))
    }

    func render(_ blocks: [MarkdownBlock]) -> NSAttributedString {
        let output = NSMutableAttributedString()
        for (index, block) in blocks.enumerated() {
            if index > 0 { output.append(NSAttributedString(string: "\n")) }
            output.append(render(block))
        }
        return output
    }

    // MARK: - Font

    private func font(size: CGFloat, weight: UIFont.Weight = .regular, italic: Bool = false, serifOverride: Bool? = nil) -> UIFont {
        var descriptor = UIFont.systemFont(ofSize: size, weight: weight).fontDescriptor
        if serifOverride ?? style.serif, let serif = descriptor.withDesign(.serif) {
            descriptor = serif
        }
        if italic, let italicDescriptor = descriptor.withSymbolicTraits(descriptor.symbolicTraits.union(.traitItalic)) {
            descriptor = italicDescriptor
        }
        return UIFont(descriptor: descriptor, size: size)
    }

    private func paragraphStyle(spacingBefore: CGFloat = 0, spacingAfter: CGFloat, indent: CGFloat = 0, headIndent: CGFloat? = nil, alignment: NSTextAlignment = .natural, lineHeight: CGFloat = 1.25) -> NSParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacingBefore = spacingBefore
        paragraph.paragraphSpacing = spacingAfter
        paragraph.firstLineHeadIndent = indent
        paragraph.headIndent = headIndent ?? indent
        paragraph.alignment = alignment
        paragraph.lineHeightMultiple = lineHeight
        paragraph.hyphenationFactor = 0.6
        return paragraph
    }

    // MARK: - Blocchi

    private func render(_ block: MarkdownBlock) -> NSAttributedString {
        let base = style.baseSize
        switch block {
        case .heading(let level, let content):
            let size: CGFloat
            let weight: UIFont.Weight
            switch level {
            case 1: size = base * 1.75; weight = .bold
            case 2: size = base * 1.35; weight = .bold
            case 3: size = base * 1.15; weight = .semibold
            default: size = base * 1.05; weight = .semibold
            }
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font(size: size, weight: weight, serifOverride: false),
                .foregroundColor: level <= 2 ? style.textColor : style.textColor,
                .paragraphStyle: paragraphStyle(spacingBefore: level == 1 ? 0 : base * 0.9, spacingAfter: base * 0.45, lineHeight: 1.1)
            ]
            let result = NSMutableAttributedString(attributedString: inline(content, attributes: attributes))
            if level == 2 {
                result.addAttribute(.accessibilityTextHeadingLevel, value: 1, range: NSRange(location: 0, length: result.length))
            }
            return result
        case .paragraph(let content):
            return inline(content, attributes: bodyAttributes(paragraphStyle(spacingAfter: base * 0.7, alignment: .justified)))
        case .blockquote(let content):
            var attributes = bodyAttributes(paragraphStyle(spacingAfter: base * 0.7, indent: base * 1.2))
            attributes[.foregroundColor] = style.secondaryColor
            attributes[.font] = font(size: base * 0.95, italic: true)
            return inline(content, attributes: attributes)
        case .bulletList(let items):
            return list(items.map { ("•", $0) })
        case .orderedList(let start, let items):
            return list(items.enumerated().map { ("\(start + $0.offset).", $0.element) })
        case .table(let header, let rows):
            return table(header: header, rows: rows)
        case .image(let alt, let source):
            return image(alt: alt, source: source)
        case .rule:
            return NSAttributedString(string: "⸻", attributes: [.font: font(size: base), .foregroundColor: style.secondaryColor, .paragraphStyle: paragraphStyle(spacingAfter: base * 0.7, alignment: .center)])
        }
    }

    private func bodyAttributes(_ paragraph: NSParagraphStyle) -> [NSAttributedString.Key: Any] {
        [.font: font(size: style.baseSize), .foregroundColor: style.textColor, .paragraphStyle: paragraph]
    }

    private func list(_ items: [(marker: String, content: [MarkdownInline])]) -> NSAttributedString {
        let output = NSMutableAttributedString()
        let indent = style.baseSize * 1.6
        for (index, item) in items.enumerated() {
            let paragraph = NSMutableParagraphStyle()
            paragraph.headIndent = indent
            paragraph.firstLineHeadIndent = 0
            paragraph.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
            paragraph.paragraphSpacing = style.baseSize * (index == items.count - 1 ? 0.7 : 0.25)
            paragraph.lineHeightMultiple = 1.2
            var attributes = bodyAttributes(paragraph)
            if index > 0 { output.append(NSAttributedString(string: "\n", attributes: attributes)) }
            output.append(NSAttributedString(string: "\(item.marker)\t", attributes: attributes))
            attributes[.paragraphStyle] = paragraph
            output.append(inline(item.content, attributes: attributes))
        }
        return output
    }

    /// Tabella resa come righe con tabulazioni (adeguata per tabelle brevi).
    private func table(header: [[MarkdownInline]], rows: [[[MarkdownInline]]]) -> NSAttributedString {
        let columns = max(header.count, rows.map(\.count).max() ?? 0)
        guard columns > 0 else { return NSAttributedString() }
        let width = (style.maxImageWidth) / CGFloat(columns)
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = (1..<columns).map { NSTextTab(textAlignment: .left, location: CGFloat($0) * width) }
        paragraph.paragraphSpacing = 2
        paragraph.lineBreakMode = .byTruncatingTail
        let output = NSMutableAttributedString()
        func appendRow(_ cells: [[MarkdownInline]], bold: Bool) {
            var attributes = bodyAttributes(paragraph)
            attributes[.font] = font(size: style.baseSize * 0.92, weight: bold ? .semibold : .regular, serifOverride: false)
            for column in 0..<columns {
                if column > 0 { output.append(NSAttributedString(string: "\t", attributes: attributes)) }
                if column < cells.count { output.append(inline(cells[column], attributes: attributes)) }
            }
        }
        appendRow(header, bold: true)
        for row in rows {
            output.append(NSAttributedString(string: "\n"))
            appendRow(row, bold: false)
        }
        return output
    }

    private func image(alt: String, source: String) -> NSAttributedString {
        guard let image = imageResolver?(source) else {
            return NSAttributedString(string: "[Immagine: \(alt)]", attributes: [.font: font(size: style.baseSize * 0.9, italic: true), .foregroundColor: style.secondaryColor])
        }
        let attachment = NSTextAttachment()
        attachment.image = image
        let scale = min(1, style.maxImageWidth / max(image.size.width, 1), style.maxImageHeight / max(image.size.height, 1))
        attachment.bounds = CGRect(x: 0, y: 0, width: image.size.width * scale, height: image.size.height * scale)
        let output = NSMutableAttributedString(attachment: attachment)
        output.addAttribute(.paragraphStyle, value: paragraphStyle(spacingAfter: 4, alignment: .center), range: NSRange(location: 0, length: output.length))
        if !alt.isEmpty {
            output.append(NSAttributedString(string: "\n" + alt, attributes: [.font: font(size: style.baseSize * 0.85, italic: true), .foregroundColor: style.secondaryColor, .paragraphStyle: paragraphStyle(spacingAfter: style.baseSize * 0.7, alignment: .center)]))
        }
        return output
    }

    // MARK: - Inline

    private func inline(_ inlines: [MarkdownInline], attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let output = NSMutableAttributedString()
        for inline in inlines {
            switch inline {
            case .text(let text):
                output.append(NSAttributedString(string: text, attributes: attributes))
            case .bold(let children):
                output.append(self.inline(children, attributes: adjusting(attributes, bold: true)))
            case .italic(let children):
                output.append(self.inline(children, attributes: adjusting(attributes, italic: true)))
            case .code(let text):
                var codeAttributes = attributes
                codeAttributes[.font] = UIFont.monospacedSystemFont(ofSize: style.baseSize * 0.9, weight: .regular)
                output.append(NSAttributedString(string: text, attributes: codeAttributes))
            case .link(let text, let url):
                var linkAttributes = attributes
                if let link = URL(string: url) { linkAttributes[.link] = link }
                output.append(self.inline(text, attributes: linkAttributes))
            case .sourceReference(let range):
                guard style.showSourceReferences else { continue }
                var referenceAttributes = attributes
                referenceAttributes[.font] = UIFont.systemFont(ofSize: style.baseSize * 0.62, weight: .medium)
                referenceAttributes[.foregroundColor] = style.accentColor
                referenceAttributes[.baselineOffset] = style.baseSize * 0.35
                referenceAttributes[.link] = URL(string: "\(Self.segmentURLScheme)://\(range.lowerBound)-\(range.upperBound)")
                let label = range.lowerBound == range.upperBound ? " ▸\(range.lowerBound)" : " ▸\(range.lowerBound)–\(range.upperBound)"
                output.append(NSAttributedString(string: label, attributes: referenceAttributes))
            case .uncertain(let text):
                var uncertainAttributes = adjusting(attributes, italic: true)
                uncertainAttributes[.backgroundColor] = style.uncertainBackground
                output.append(NSAttributedString(string: text.isEmpty ? "[incerto]" : "[incerto: \(text)]", attributes: uncertainAttributes))
            case .lineBreak:
                output.append(NSAttributedString(string: "\u{2028}", attributes: attributes))
            }
        }
        return output
    }

    private func adjusting(_ attributes: [NSAttributedString.Key: Any], bold: Bool = false, italic: Bool = false) -> [NSAttributedString.Key: Any] {
        guard let current = attributes[.font] as? UIFont else { return attributes }
        var traits = current.fontDescriptor.symbolicTraits
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        var updated = attributes
        if let descriptor = current.fontDescriptor.withSymbolicTraits(traits) {
            updated[.font] = UIFont(descriptor: descriptor, size: current.pointSize)
        }
        return updated
    }

    /// Estrae l'intervallo di segmenti da un URL di riferimento.
    static func segmentRange(from url: URL) -> ClosedRange<Int>? {
        guard url.scheme == segmentURLScheme, let host = url.host else { return nil }
        let parts = host.split(separator: "-").compactMap { Int($0) }
        guard let first = parts.first else { return nil }
        return first...(parts.last ?? first)
    }
}
