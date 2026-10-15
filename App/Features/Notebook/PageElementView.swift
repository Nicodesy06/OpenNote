import UIKit

/// Vista di un elemento della pagina (testo digitato o immagine), con
/// spostamento, ridimensionamento ed eliminazione in modalità «Elementi».
final class PageElementView: UIView, UITextViewDelegate {
    let element: PageElement
    private let textView = UITextView()
    private let imageView = UIImageView()
    private let resizeHandle = UIView()
    private var panStart: CGPoint = .zero
    private var resizeStart: CGRect = .zero

    var onChange: (() -> Void)?
    var onDelete: (() -> Void)?

    var isArranging = false {
        didSet { updateAppearance() }
    }

    var isTextEditable = false {
        didSet { textView.isEditable = isTextEditable && element.kind == .text }
    }

    init(element: PageElement, image: UIImage?) {
        self.element = element
        super.init(frame: element.frame)
        clipsToBounds = false

        switch element.kind {
        case .text:
            textView.text = element.text
            textView.font = .systemFont(ofSize: element.fontSize)
            textView.textColor = .black
            textView.backgroundColor = .clear
            textView.isScrollEnabled = false
            textView.delegate = self
            textView.textContainerInset = UIEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
            textView.frame = bounds
            textView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(textView)
        case .image:
            imageView.image = image ?? UIImage(systemName: "photo")
            imageView.contentMode = .scaleAspectFit
            imageView.frame = bounds
            imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(imageView)
        }

        resizeHandle.backgroundColor = .systemBlue
        resizeHandle.layer.cornerRadius = 9
        resizeHandle.frame = CGRect(x: bounds.width - 9, y: bounds.height - 9, width: 18, height: 18)
        resizeHandle.autoresizingMask = [.flexibleLeftMargin, .flexibleTopMargin]
        addSubview(resizeHandle)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        addGestureRecognizer(pan)
        let resize = UIPanGestureRecognizer(target: self, action: #selector(handleResize(_:)))
        resizeHandle.addGestureRecognizer(resize)
        addInteraction(UIContextMenuInteraction(delegate: self))
        isAccessibilityElement = element.kind == .image
        accessibilityLabel = element.kind == .image ? "Immagine" : nil
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func updateAppearance() {
        resizeHandle.isHidden = !isArranging
        layer.borderWidth = isArranging ? 1.5 : 0
        layer.borderColor = UIColor.systemBlue.withAlphaComponent(0.7).cgColor
    }

    func beginEditing() {
        textView.isEditable = true
        textView.becomeFirstResponder()
    }

    func updateRenderingScale(_ scale: CGFloat) {
        contentScaleFactor = scale
        textView.contentScaleFactor = scale
        for subview in textView.subviews { subview.contentScaleFactor = scale }
        imageView.contentScaleFactor = scale
    }

    // MARK: - Testo

    func textViewDidChange(_ textView: UITextView) {
        element.text = textView.text
        let fitting = textView.sizeThatFits(CGSize(width: bounds.width, height: .greatestFiniteMagnitude))
        if abs(fitting.height - bounds.height) > 1 {
            frame.size.height = max(44, fitting.height)
            element.frame = frame
        }
        onChange?()
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        if element.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            onDelete?()
        }
    }

    // MARK: - Gesti

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        guard isArranging, let container = superview else { return }
        switch recognizer.state {
        case .began:
            panStart = frame.origin
        case .changed:
            let translation = recognizer.translation(in: container)
            let size = NotebookCanvasController.pageSize
            frame.origin = CGPoint(x: min(max(-frame.width / 2, panStart.x + translation.x), size.width - frame.width / 2),
                                   y: min(max(-frame.height / 2, panStart.y + translation.y), size.height - frame.height / 2))
        case .ended, .cancelled:
            element.frame = frame
            onChange?()
        default:
            break
        }
    }

    @objc private func handleResize(_ recognizer: UIPanGestureRecognizer) {
        guard isArranging, let container = superview else { return }
        switch recognizer.state {
        case .began:
            resizeStart = frame
        case .changed:
            let translation = recognizer.translation(in: container)
            var width = max(60, resizeStart.width + translation.x)
            var height = max(40, resizeStart.height + translation.y)
            if element.kind == .image, resizeStart.width > 0 {
                // Le immagini mantengono le proporzioni.
                let ratio = resizeStart.height / resizeStart.width
                height = width * ratio
                width = max(60, width)
            }
            frame.size = CGSize(width: width, height: height)
        case .ended, .cancelled:
            element.frame = frame
            onChange?()
        default:
            break
        }
    }
}

extension PageElementView: UIContextMenuInteractionDelegate {
    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard isArranging || element.kind == .text && isTextEditable else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            var actions: [UIMenuElement] = []
            if self?.element.kind == .text {
                let sizes: [CGFloat] = [14, 18, 24, 32]
                let sizeActions = sizes.map { size in
                    UIAction(title: "\(Int(size)) pt", state: self?.element.fontSize == Double(size) ? .on : .off) { _ in
                        self?.element.fontSize = Double(size)
                        self?.textView.font = .systemFont(ofSize: size)
                        if let textView = self?.textView { self?.textViewDidChange(textView) }
                    }
                }
                actions.append(UIMenu(title: "Dimensione testo", image: UIImage(systemName: "textformat.size"), children: sizeActions))
            }
            actions.append(UIAction(title: "Elimina", image: UIImage(systemName: "trash"), attributes: .destructive) { _ in
                self?.onDelete?()
            })
            return UIMenu(children: actions)
        }
    }
}
