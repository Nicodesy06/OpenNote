import SwiftUI
import UIKit

/// Comandi di formattazione inviati all'editor.
@MainActor
final class MarkdownEditorCommands {
    weak var textView: UITextView?

    func wrapSelection(prefix: String, suffix: String) {
        guard let textView, let range = textView.selectedTextRange else { return }
        let selected = textView.text(in: range) ?? ""
        textView.replace(range, withText: prefix + selected + suffix)
        if selected.isEmpty, let position = textView.position(from: range.start, offset: prefix.count) {
            textView.selectedTextRange = textView.textRange(from: position, to: position)
        }
    }

    /// Applica un prefisso di riga (titolo, elenco) alla riga corrente.
    func toggleLinePrefix(_ prefix: String) {
        guard let textView else { return }
        let text = textView.text as NSString
        let selection = textView.selectedRange
        let lineRange = text.lineRange(for: NSRange(location: selection.location, length: 0))
        let line = text.substring(with: lineRange)
        var stripped = line
        for marker in ["### ", "## ", "# ", "- ", "1. "] where stripped.hasPrefix(marker) {
            stripped = String(stripped.dropFirst(marker.count))
            break
        }
        let newLine = line.hasPrefix(prefix) ? stripped : prefix + stripped
        if let start = textView.position(from: textView.beginningOfDocument, offset: lineRange.location),
           let end = textView.position(from: start, offset: lineRange.length),
           let range = textView.textRange(from: start, to: end) {
            textView.replace(range, withText: newLine)
        }
    }

    func insert(_ text: String) {
        guard let textView, let range = textView.selectedTextRange else { return }
        textView.replace(range, withText: text)
    }

    func showFind() {
        textView?.findInteraction?.presentFindNavigator(showingReplace: true)
    }
}

/// Editor Markdown nativo (UITextView) con evidenziazione leggera della
/// sintassi, ricerca e sostituzione di sistema. Il testo resta Markdown, così
/// le modifiche sono preservate fedelmente in tutti gli export.
struct MarkdownEditorView: UIViewRepresentable {
    @Binding var text: String
    let commands: MarkdownEditorCommands
    var onFocusLost: (() -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.font = MarkdownHighlighter.bodyFont
        textView.backgroundColor = .clear
        textView.isFindInteractionEnabled = true
        textView.autocorrectionType = .default
        textView.smartQuotesType = .no
        textView.textContainerInset = UIEdgeInsets(top: 20, left: 24, bottom: 120, right: 24)
        textView.alwaysBounceVertical = true
        textView.keyboardDismissMode = .interactive
        textView.text = text
        MarkdownHighlighter.highlight(textView.textStorage)
        commands.textView = textView
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        commands.textView = textView
        if textView.text != text && !context.coordinator.isEditing {
            textView.text = text
            MarkdownHighlighter.highlight(textView.textStorage)
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: MarkdownEditorView
        var isEditing = false
        private var highlightWork: DispatchWorkItem?

        init(_ parent: MarkdownEditorView) { self.parent = parent }

        func textViewDidBeginEditing(_ textView: UITextView) { isEditing = true }

        func textViewDidEndEditing(_ textView: UITextView) {
            isEditing = false
            parent.onFocusLost?()
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            highlightWork?.cancel()
            let work = DispatchWorkItem { [weak textView] in
                guard let textView else { return }
                let selection = textView.selectedRange
                MarkdownHighlighter.highlight(textView.textStorage)
                textView.selectedRange = selection
            }
            highlightWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        }
    }
}

/// Evidenziazione: titoli più grandi, grassetto/corsivo visibili, marcatori
/// dei segmenti attenuati, passaggi incerti evidenziati.
enum MarkdownHighlighter {
    static var bodyFont: UIFont {
        let descriptor = UIFont.preferredFont(forTextStyle: .body).fontDescriptor.withDesign(.serif) ?? UIFont.preferredFont(forTextStyle: .body).fontDescriptor
        return UIFont(descriptor: descriptor, size: 18)
    }

    private static let patterns: [(NSRegularExpression, (NSTextStorage, NSTextCheckingResult) -> Void)] = {
        func regex(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
            try! NSRegularExpression(pattern: pattern, options: options)
        }
        return [
            (regex(#"^(#{1,6})\s.*$"#, .anchorsMatchLines), { storage, match in
                let level = match.range(at: 1).length
                let size: CGFloat = level == 1 ? 28 : level == 2 ? 23 : 20
                storage.addAttribute(.font, value: UIFont.systemFont(ofSize: size, weight: .bold), range: match.range)
                storage.addAttribute(.foregroundColor, value: UIColor.label, range: match.range)
            }),
            (regex(#"\*\*[^*\n]+\*\*"#), { storage, match in
                storage.addAttribute(.font, value: UIFont.systemFont(ofSize: 18, weight: .bold), range: match.range)
            }),
            (regex(#"(?<![\*\w])\*[^*\n]+\*(?!\*)"#), { storage, match in
                let descriptor = bodyFont.fontDescriptor.withSymbolicTraits(.traitItalic) ?? bodyFont.fontDescriptor
                storage.addAttribute(.font, value: UIFont(descriptor: descriptor, size: 18), range: match.range)
            }),
            (regex(#"\[\[\s*S\d+(?:\s*[-–]\s*S?\d+)?\s*\]\]"#), { storage, match in
                storage.addAttribute(.foregroundColor, value: UIColor.tertiaryLabel, range: match.range)
                storage.addAttribute(.font, value: UIFont.systemFont(ofSize: 12, weight: .medium), range: match.range)
            }),
            (regex(#"\[\[\s*incerto\s*:[^\]]*\]\]"#, .caseInsensitive), { storage, match in
                storage.addAttribute(.backgroundColor, value: UIColor.systemYellow.withAlphaComponent(0.35), range: match.range)
            }),
            (regex(#"^\s*(?:[-*•]|\d+\.)\s"#, .anchorsMatchLines), { storage, match in
                storage.addAttribute(.foregroundColor, value: UIColor.tintColor, range: match.range)
            }),
            (regex(#"^>.*$"#, .anchorsMatchLines), { storage, match in
                storage.addAttribute(.foregroundColor, value: UIColor.secondaryLabel, range: match.range)
            })
        ]
    }()

    static func highlight(_ storage: NSTextStorage) {
        let full = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.25
        paragraph.paragraphSpacing = 6
        storage.setAttributes([.font: bodyFont, .foregroundColor: UIColor.label, .paragraphStyle: paragraph], range: full)
        let string = storage.string
        for (regex, apply) in patterns {
            for match in regex.matches(in: string, range: full) {
                apply(storage, match)
            }
        }
        storage.endEditing()
    }
}

/// Lettura del documento renderizzato; i riferimenti ai segmenti sono
/// collegamenti che portano al punto corrispondente dell'audio.
struct RenderedTextView: UIViewRepresentable {
    let attributedText: NSAttributedString
    var onSegmentTap: ((ClosedRange<Int>) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(onSegmentTap: onSegmentTap) }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isFindInteractionEnabled = true
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 24, left: 32, bottom: 120, right: 32)
        textView.delegate = context.coordinator
        textView.linkTextAttributes = [:]
        textView.attributedText = attributedText
        textView.adjustsFontForContentSizeCategory = true
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.onSegmentTap = onSegmentTap
        if !textView.attributedText.isEqual(to: attributedText) {
            textView.attributedText = attributedText
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var onSegmentTap: ((ClosedRange<Int>) -> Void)?
        init(onSegmentTap: ((ClosedRange<Int>) -> Void)?) { self.onSegmentTap = onSegmentTap }

        func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem, defaultAction: UIAction) -> UIAction? {
            if case .link(let url) = textItem.content, let range = MarkdownRenderer.segmentRange(from: url) {
                return UIAction { [weak self] _ in self?.onSegmentTap?(range) }
            }
            return defaultAction
        }
    }
}
