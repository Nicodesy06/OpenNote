import Foundation

/// Immagine da incorporare nel DOCX.
public struct DocxImage: Sendable {
    public var data: Data
    public var fileExtension: String // "png" o "jpeg"
    public var pixelWidth: Int
    public var pixelHeight: Int

    public init(data: Data, fileExtension: String, pixelWidth: Int, pixelHeight: Int) {
        self.data = data
        self.fileExtension = fileExtension
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

/// Esporta il Markdown della sbobinatura in Office Open XML (.docx) senza
/// dipendenze: stili per titoli, elenchi numerati/puntati, tabelle,
/// citazioni, immagini e passaggi incerti evidenziati.
public struct DocxExporter {
    public var title: String
    public var author: String
    /// Risolve il percorso di un'immagine Markdown nei suoi dati.
    public var imageResolver: ((String) -> DocxImage?)?

    public init(title: String, author: String = "Quaderno AI", imageResolver: ((String) -> DocxImage?)? = nil) {
        self.title = title
        self.author = author
        self.imageResolver = imageResolver
    }

    private struct Context {
        var images: [(id: String, name: String, image: DocxImage)] = []
        var numberingInstances: [(numId: Int, abstractId: Int)] = []
        var nextDrawingId = 1
    }

    public func export(markdown: String) -> Data {
        let blocks = MarkdownParser.parse(markdown)
        var context = Context()
        var body = ""
        for block in blocks {
            body += render(block, context: &context)
        }
        // Sezione pagina A4 con margini di 2 cm.
        body += "<w:sectPr><w:pgSz w:w=\"11906\" w:h=\"16838\"/><w:pgMar w:top=\"1134\" w:right=\"1134\" w:bottom=\"1134\" w:left=\"1134\" w:header=\"709\" w:footer=\"709\" w:gutter=\"0\"/></w:sectPr>"

        let document = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"><w:body>\(body)</w:body></w:document>
        """

        var zip = ZipWriter()
        zip.add(path: "[Content_Types].xml", text: contentTypes(context))
        zip.add(path: "_rels/.rels", text: rootRelationships)
        zip.add(path: "docProps/core.xml", text: coreProperties)
        zip.add(path: "docProps/app.xml", text: appProperties)
        zip.add(path: "word/document.xml", text: document)
        zip.add(path: "word/styles.xml", text: Self.styles)
        zip.add(path: "word/numbering.xml", text: numbering(context))
        zip.add(path: "word/_rels/document.xml.rels", text: documentRelationships(context))
        for image in context.images {
            zip.add(path: "word/media/\(image.name)", contents: image.image.data)
        }
        return zip.finalize()
    }

    // MARK: - Blocchi

    private func render(_ block: MarkdownBlock, context: inout Context) -> String {
        switch block {
        case .heading(let level, let content):
            let style = level == 1 ? "Title" : "Heading\(min(level - 1, 3))"
            return paragraph(style: style, runs: runs(content))
        case .paragraph(let content):
            return paragraph(style: nil, runs: runs(content))
        case .blockquote(let content):
            return paragraph(style: "Quote", runs: runs(content))
        case .bulletList(let items):
            let numId = newNumbering(abstractId: 1, context: &context)
            return items.map { paragraph(style: "ListParagraph", runs: runs($0), numId: numId) }.joined()
        case .orderedList(_, let items):
            let numId = newNumbering(abstractId: 2, context: &context)
            return items.map { paragraph(style: "ListParagraph", runs: runs($0), numId: numId) }.joined()
        case .table(let header, let rows):
            return table(header: header, rows: rows)
        case .image(let alt, let source):
            guard let image = imageResolver?(source) else {
                return paragraph(style: nil, runs: run("[Immagine non disponibile: \(alt)]", italic: true))
            }
            return imageParagraph(image, alt: alt, context: &context)
        case .rule:
            return "<w:p><w:pPr><w:pBdr><w:bottom w:val=\"single\" w:sz=\"6\" w:space=\"1\" w:color=\"BBBBBB\"/></w:pBdr></w:pPr></w:p>"
        }
    }

    private func newNumbering(abstractId: Int, context: inout Context) -> Int {
        let numId = context.numberingInstances.count + 1
        context.numberingInstances.append((numId, abstractId))
        return numId
    }

    private func paragraph(style: String?, runs: String, numId: Int? = nil) -> String {
        var properties = ""
        if let style { properties += "<w:pStyle w:val=\"\(style)\"/>" }
        if let numId { properties += "<w:numPr><w:ilvl w:val=\"0\"/><w:numId w:val=\"\(numId)\"/></w:numPr>" }
        return "<w:p>" + (properties.isEmpty ? "" : "<w:pPr>\(properties)</w:pPr>") + runs + "</w:p>"
    }

    private func table(header: [[MarkdownInline]], rows: [[[MarkdownInline]]]) -> String {
        let columns = max(header.count, rows.map(\.count).max() ?? 0)
        guard columns > 0 else { return "" }
        let width = 9638 / columns
        var xml = "<w:tbl><w:tblPr><w:tblStyle w:val=\"TableGrid\"/><w:tblW w:w=\"0\" w:type=\"auto\"/><w:tblBorders>"
        for edge in ["top", "left", "bottom", "right", "insideH", "insideV"] {
            xml += "<w:\(edge) w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"999999\"/>"
        }
        xml += "</w:tblBorders></w:tblPr><w:tblGrid>" + String(repeating: "<w:gridCol w:w=\"\(width)\"/>", count: columns) + "</w:tblGrid>"
        func row(_ cells: [[MarkdownInline]], bold: Bool) -> String {
            var rowXML = "<w:tr>"
            for column in 0..<columns {
                let content = column < cells.count ? cells[column] : []
                let cellRuns = bold ? runs([.bold(content)]) : runs(content)
                rowXML += "<w:tc><w:tcPr><w:tcW w:w=\"\(width)\" w:type=\"dxa\"/></w:tcPr><w:p>\(cellRuns)</w:p></w:tc>"
            }
            return rowXML + "</w:tr>"
        }
        xml += row(header, bold: true)
        for cells in rows { xml += row(cells, bold: false) }
        return xml + "</w:tbl><w:p/>"
    }

    private func imageParagraph(_ image: DocxImage, alt: String, context: inout Context) -> String {
        let index = context.images.count + 1
        let relationshipId = "rIdImg\(index)"
        let ext = image.fileExtension.lowercased() == "jpg" ? "jpeg" : image.fileExtension.lowercased()
        let name = "image\(index).\(ext)"
        context.images.append((relationshipId, name, image))
        // Larghezza massima 16 cm (EMU: 360000 per cm).
        let maxWidth = 16.0 * 360_000
        let aspect = image.pixelWidth > 0 ? Double(image.pixelHeight) / Double(image.pixelWidth) : 0.75
        let widthEMU = Int(min(maxWidth, Double(max(1, image.pixelWidth)) * 9525))
        let heightEMU = Int(Double(widthEMU) * aspect)
        let drawingId = context.nextDrawingId
        context.nextDrawingId += 1
        let escapedAlt = Self.escape(alt)
        return """
        <w:p><w:pPr><w:jc w:val="center"/></w:pPr><w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0"><wp:extent cx="\(widthEMU)" cy="\(heightEMU)"/><wp:docPr id="\(drawingId)" name="Immagine \(drawingId)" descr="\(escapedAlt)"/><a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:pic><pic:nvPicPr><pic:cNvPr id="\(drawingId)" name="\(name)"/><pic:cNvPicPr/></pic:nvPicPr><pic:blipFill><a:blip r:embed="\(relationshipId)"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill><pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(widthEMU)" cy="\(heightEMU)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>
        """ + (alt.isEmpty ? "" : paragraph(style: "Caption", runs: run(alt, italic: true)))
    }

    // MARK: - Inline

    private func runs(_ inlines: [MarkdownInline], bold: Bool = false, italic: Bool = false) -> String {
        inlines.map { inline -> String in
            switch inline {
            case .text(let value):
                return run(value, bold: bold, italic: italic)
            case .bold(let children):
                return runs(children, bold: true, italic: italic)
            case .italic(let children):
                return runs(children, bold: bold, italic: true)
            case .code(let value):
                return run(value, bold: bold, italic: italic, monospace: true)
            case .link(let text, _):
                return runs(text, bold: bold, italic: italic)
            case .sourceReference:
                return ""
            case .uncertain(let value):
                return run(value.isEmpty ? "[incerto]" : "[incerto: \(value)]", bold: bold, italic: true, highlight: true)
            case .lineBreak:
                return "<w:r><w:br/></w:r>"
            }
        }.joined()
    }

    private func run(_ text: String, bold: Bool = false, italic: Bool = false, monospace: Bool = false, highlight: Bool = false) -> String {
        guard !text.isEmpty else { return "" }
        var properties = ""
        if monospace { properties += "<w:rFonts w:ascii=\"Courier New\" w:hAnsi=\"Courier New\"/>" }
        if bold { properties += "<w:b/>" }
        if italic { properties += "<w:i/>" }
        if highlight { properties += "<w:highlight w:val=\"yellow\"/>" }
        let props = properties.isEmpty ? "" : "<w:rPr>\(properties)</w:rPr>"
        return "<w:r>\(props)<w:t xml:space=\"preserve\">\(Self.escape(text))</w:t></w:r>"
    }

    static func escape(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            default:
                // Esclude caratteri di controllo non ammessi in XML 1.0.
                if scalar.value < 0x20 && scalar != "\t" && scalar != "\n" && scalar != "\r" { continue }
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    // MARK: - Parti del pacchetto

    private func contentTypes(_ context: Context) -> String {
        var defaults = """
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/>
        """
        let extensions = Set(context.images.map { $0.name.components(separatedBy: ".").last ?? "png" })
        for ext in extensions.sorted() {
            defaults += "<Default Extension=\"\(ext)\" ContentType=\"image/\(ext)\"/>"
        }
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\(defaults)<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/><Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/><Override PartName="/word/numbering.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"/><Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/><Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/></Types>
        """
    }

    private var rootRelationships: String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/><Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/></Relationships>
        """
    }

    private func documentRelationships(_ context: Context) -> String {
        var relationships = """
        <Relationship Id="rIdStyles" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/><Relationship Id="rIdNumbering" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering" Target="numbering.xml"/>
        """
        for image in context.images {
            relationships += "<Relationship Id=\"\(image.id)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" Target=\"media/\(image.name)\"/>"
        }
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\(relationships)</Relationships>
        """
    }

    private var coreProperties: String {
        let formatter = ISO8601DateFormatter()
        let now = formatter.string(from: Date())
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"><dc:title>\(Self.escape(title))</dc:title><dc:creator>\(Self.escape(author))</dc:creator><dc:language>it-IT</dc:language><dcterms:created xsi:type="dcterms:W3CDTF">\(now)</dcterms:created><dcterms:modified xsi:type="dcterms:W3CDTF">\(now)</dcterms:modified></cp:coreProperties>
        """
    }

    private var appProperties: String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties"><Application>Quaderno AI</Application></Properties>
        """
    }

    private func numbering(_ context: Context) -> String {
        let bullet = """
        <w:abstractNum w:abstractNumId="1"><w:multiLevelType w:val="singleLevel"/><w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="bullet"/><w:lvlText w:val="•"/><w:lvlJc w:val="left"/><w:pPr><w:ind w:left="720" w:hanging="360"/></w:pPr></w:lvl></w:abstractNum>
        """
        let decimal = """
        <w:abstractNum w:abstractNumId="2"><w:multiLevelType w:val="singleLevel"/><w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="decimal"/><w:lvlText w:val="%1."/><w:lvlJc w:val="left"/><w:pPr><w:ind w:left="720" w:hanging="360"/></w:pPr></w:lvl></w:abstractNum>
        """
        var instances = ""
        for instance in context.numberingInstances {
            instances += "<w:num w:numId=\"\(instance.numId)\"><w:abstractNumId w:val=\"\(instance.abstractId)\"/>"
            if instance.abstractId == 2 {
                // Ogni elenco numerato riparte da 1.
                instances += "<w:lvlOverride w:ilvl=\"0\"><w:startOverride w:val=\"1\"/></w:lvlOverride>"
            }
            instances += "</w:num>"
        }
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">\(bullet)\(decimal)\(instances)</w:numbering>
        """
    }

    static let styles = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Calibri" w:hAnsi="Calibri" w:eastAsia="Calibri" w:cs="Calibri"/><w:sz w:val="23"/><w:szCs w:val="23"/><w:lang w:val="it-IT"/></w:rPr></w:rPrDefault><w:pPrDefault><w:pPr><w:spacing w:after="160" w:line="300" w:lineRule="auto"/><w:jc w:val="both"/></w:pPr></w:pPrDefault></w:docDefaults><w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style><w:style w:type="paragraph" w:styleId="Title"><w:name w:val="Title"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:spacing w:after="240"/><w:jc w:val="left"/></w:pPr><w:rPr><w:b/><w:sz w:val="44"/><w:color w:val="1F2937"/></w:rPr></w:style><w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:keepNext/><w:spacing w:before="360" w:after="160"/><w:jc w:val="left"/><w:outlineLvl w:val="0"/></w:pPr><w:rPr><w:b/><w:sz w:val="32"/><w:color w:val="1F3A8A"/></w:rPr></w:style><w:style w:type="paragraph" w:styleId="Heading2"><w:name w:val="heading 2"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:keepNext/><w:spacing w:before="240" w:after="120"/><w:jc w:val="left"/><w:outlineLvl w:val="1"/></w:pPr><w:rPr><w:b/><w:sz w:val="27"/><w:color w:val="1F2937"/></w:rPr></w:style><w:style w:type="paragraph" w:styleId="Heading3"><w:name w:val="heading 3"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:keepNext/><w:spacing w:before="200" w:after="80"/><w:jc w:val="left"/><w:outlineLvl w:val="2"/></w:pPr><w:rPr><w:b/><w:i/><w:sz w:val="24"/></w:rPr></w:style><w:style w:type="paragraph" w:styleId="Quote"><w:name w:val="Quote"/><w:basedOn w:val="Normal"/><w:qFormat/><w:pPr><w:ind w:left="567" w:right="567"/><w:pBdr><w:left w:val="single" w:sz="12" w:space="8" w:color="9CA3AF"/></w:pBdr></w:pPr><w:rPr><w:i/><w:color w:val="4B5563"/></w:rPr></w:style><w:style w:type="paragraph" w:styleId="ListParagraph"><w:name w:val="List Paragraph"/><w:basedOn w:val="Normal"/><w:qFormat/><w:pPr><w:spacing w:after="80"/><w:ind w:left="720"/></w:pPr></w:style><w:style w:type="paragraph" w:styleId="Caption"><w:name w:val="caption"/><w:basedOn w:val="Normal"/><w:pPr><w:jc w:val="center"/></w:pPr><w:rPr><w:sz w:val="19"/><w:color w:val="6B7280"/></w:rPr></w:style><w:style w:type="table" w:styleId="TableGrid"><w:name w:val="Table Grid"/><w:tblPr><w:tblCellMar><w:left w:w="108" w:type="dxa"/><w:right w:w="108" w:type="dxa"/></w:tblCellMar></w:tblPr></w:style></w:styles>
    """
}
