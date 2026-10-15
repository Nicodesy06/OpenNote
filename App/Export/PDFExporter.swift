import PDFKit
import PencilKit
import UIKit
import QuadernoCore

/// Esportazioni in PDF: sbobinature (testo impaginato con TextKit),
/// quaderni (pagine con modello, elementi e inchiostro) e PDF annotati.
enum PDFExporter {
    /// A4 in punti tipografici.
    static let a4 = CGSize(width: 595.2, height: 841.8)

    // MARK: - Sbobinatura

    static func exportDocument(markdown: String, title: String, imageResolver: ((String) -> UIImage?)?) -> Data {
        var renderer = MarkdownRenderer(style: .print)
        renderer.imageResolver = imageResolver
        let attributed = renderer.render(SourceMarkers.stripForExport(markdown))
        return paginate(attributed, title: title)
    }

    /// Impagina un testo su pagine A4 con margini di 2 cm e numeri di pagina.
    static func paginate(_ text: NSAttributedString, title: String) -> Data {
        let pageRect = CGRect(origin: .zero, size: a4)
        let margin: CGFloat = 56.7
        let footerHeight: CGFloat = 20
        let contentRect = CGRect(x: margin, y: margin, width: pageRect.width - margin * 2, height: pageRect.height - margin * 2 - footerHeight)

        let storage = NSTextStorage(attributedString: text)
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        var containers: [NSTextContainer] = []
        repeat {
            let container = NSTextContainer(size: contentRect.size)
            container.lineFragmentPadding = 0
            layoutManager.addTextContainer(container)
            containers.append(container)
            let range = layoutManager.glyphRange(for: container)
            if range.length == 0 {
                // Nessun glifo entra nella pagina: si evita una pagina vuota.
                if containers.count > 1 {
                    layoutManager.removeTextContainer(at: containers.count - 1)
                    containers.removeLast()
                }
                break
            }
            if NSMaxRange(range) >= layoutManager.numberOfGlyphs { break }
        } while containers.count < 2_000

        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [kCGPDFContextTitle as String: title, kCGPDFContextCreator as String: "Quaderno AI"]
        let pdfRenderer = UIGraphicsPDFRenderer(bounds: pageRect, format: format)
        return pdfRenderer.pdfData { context in
            for (index, container) in containers.enumerated() {
                context.beginPage()
                let range = layoutManager.glyphRange(for: container)
                layoutManager.drawBackground(forGlyphRange: range, at: contentRect.origin)
                layoutManager.drawGlyphs(forGlyphRange: range, at: contentRect.origin)
                let footer = "\(title) — \(index + 1)/\(containers.count)"
                let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 8.5), .foregroundColor: UIColor.gray]
                let size = (footer as NSString).size(withAttributes: attributes)
                (footer as NSString).draw(at: CGPoint(x: (pageRect.width - size.width) / 2, y: pageRect.height - margin + 6), withAttributes: attributes)
            }
        }
    }

    // MARK: - Quaderno

    /// Esporta le pagine di un quaderno. L'inchiostro è rasterizzato a
    /// risoluzione di stampa (i dati vettoriali restano nell'app).
    static func exportNotebook(pages: [(template: PageTemplate, drawing: PKDrawing, elements: [PageElementSnapshot])], pageSize: CGSize, imageLoader: (String) -> UIImage?) -> Data {
        let pageRect = CGRect(origin: .zero, size: pageSize)
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)
        return renderer.pdfData { context in
            for page in pages {
                context.beginPage()
                let cg = context.cgContext
                UIColor.white.setFill()
                cg.fill(pageRect)
                PageTemplateRenderer.draw(page.template, in: cg, size: pageSize, scale: 1)
                for element in page.elements.sorted(by: { $0.zIndex < $1.zIndex }) {
                    switch element.kind {
                    case .image:
                        if let path = element.imagePath, let image = imageLoader(path) {
                            image.draw(in: element.frame)
                        }
                    case .text:
                        let paragraph = NSMutableParagraphStyle()
                        paragraph.lineBreakMode = .byWordWrapping
                        (element.text as NSString).draw(in: element.frame.insetBy(dx: 4, dy: 4), withAttributes: [.font: UIFont.systemFont(ofSize: element.fontSize), .foregroundColor: UIColor.black, .paragraphStyle: paragraph])
                    }
                }
                // L'inchiostro va reso con aspetto chiaro (carta bianca).
                var image = UIImage()
                UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                    image = page.drawing.image(from: pageRect, scale: 3)
                }
                image.draw(in: pageRect)
            }
        }
    }

    struct PageElementSnapshot {
        var kind: PageElementKind
        var frame: CGRect
        var text: String
        var fontSize: CGFloat
        var imagePath: String?
        var zIndex: Int
    }

    // MARK: - PDF annotato

    /// Combina ogni pagina del PDF con le annotazioni a penna salvate.
    /// `annotations[i]` contiene il disegno e la dimensione della tela su cui
    /// è stato tracciato, per riportarlo esattamente alle coordinate della pagina.
    static func exportAnnotatedPDF(document: PDFDocument, annotations: [Int: (drawing: PKDrawing, canvasSize: CGSize)]) -> Data {
        guard let first = document.page(at: 0) else { return Data() }
        let defaultBounds = first.bounds(for: .mediaBox)
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: defaultBounds.size))
        return renderer.pdfData { context in
            for index in 0..<document.pageCount {
                guard let page = document.page(at: index) else { continue }
                let bounds = page.bounds(for: .mediaBox)
                context.beginPage(withBounds: CGRect(origin: .zero, size: bounds.size), pageInfo: [:])
                let cg = context.cgContext
                cg.saveGState()
                // PDFKit disegna con origine in basso a sinistra.
                cg.translateBy(x: 0, y: bounds.height)
                cg.scaleBy(x: 1, y: -1)
                page.draw(with: .mediaBox, to: cg)
                cg.restoreGState()
                if let annotation = annotations[index], annotation.canvasSize.width > 0 {
                    var image = UIImage()
                    UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                        image = annotation.drawing.image(from: CGRect(origin: .zero, size: annotation.canvasSize), scale: 3)
                    }
                    image.draw(in: CGRect(origin: .zero, size: bounds.size))
                }
            }
        }
    }
}

/// Disegno dei modelli di pagina (righe, quadretti, puntini), condiviso da
/// editor ed export.
enum PageTemplateRenderer {
    static let lineSpacing: CGFloat = 32
    static let gridSpacing: CGFloat = 24
    static let lineColor = UIColor(red: 0.62, green: 0.72, blue: 0.86, alpha: 0.55)
    static let marginColor = UIColor(red: 0.92, green: 0.45, blue: 0.45, alpha: 0.45)

    static func path(for template: PageTemplate, size: CGSize, scale: CGFloat) -> UIBezierPath {
        let path = UIBezierPath()
        switch template {
        case .blank:
            break
        case .lined:
            var y = lineSpacing * 3
            while y < size.height - lineSpacing {
                path.move(to: CGPoint(x: 0, y: y * scale))
                path.addLine(to: CGPoint(x: size.width * scale, y: y * scale))
                y += lineSpacing
            }
        case .grid:
            var x = gridSpacing
            while x < size.width {
                path.move(to: CGPoint(x: x * scale, y: 0))
                path.addLine(to: CGPoint(x: x * scale, y: size.height * scale))
                x += gridSpacing
            }
            var y = gridSpacing
            while y < size.height {
                path.move(to: CGPoint(x: 0, y: y * scale))
                path.addLine(to: CGPoint(x: size.width * scale, y: y * scale))
                y += gridSpacing
            }
        case .dotted:
            var y = gridSpacing
            while y < size.height {
                var x = gridSpacing
                while x < size.width {
                    path.append(UIBezierPath(ovalIn: CGRect(x: (x - 1) * scale, y: (y - 1) * scale, width: 2 * scale, height: 2 * scale)))
                    x += gridSpacing
                }
                y += gridSpacing
            }
        }
        return path
    }

    static func draw(_ template: PageTemplate, in context: CGContext, size: CGSize, scale: CGFloat) {
        let path = self.path(for: template, size: size, scale: scale)
        context.saveGState()
        if template == .dotted {
            lineColor.withAlphaComponent(0.9).setFill()
            path.fill()
        } else {
            lineColor.setStroke()
            path.lineWidth = 0.6 * scale
            path.stroke()
        }
        if template == .lined {
            let margin = UIBezierPath()
            margin.move(to: CGPoint(x: 72 * scale, y: 0))
            margin.addLine(to: CGPoint(x: 72 * scale, y: size.height * scale))
            marginColor.setStroke()
            margin.lineWidth = 0.8 * scale
            margin.stroke()
        }
        context.restoreGState()
    }
}
