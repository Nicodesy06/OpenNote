import XCTest
@testable import QuadernoCore

final class MarkdownParserTests: XCTestCase {
    func testBlocksAndInlines() {
        let markdown = """
        # Titolo della lezione

        **Materia:** Storia del Design\u{20}\u{20}
        **Data:** 1 ottobre

        ## Il Bauhaus

        Il **Bauhaus** nasce a *Weimar* nel 1919, come spiega ***Gropius***. [[S1-S3]]
        Continua sulla stessa riga logica con `codice` e [[incerto: Stölzl]].

        - primo punto
        - secondo punto
          che continua
        1. uno
        2. due

        > Nota importante

        | Scuola | Città |
        |---|---|
        | Bauhaus | Weimar |

        ![Schema](images/schema.png)

        ---
        """
        let blocks = MarkdownParser.parse(markdown)
        XCTAssertEqual(blocks.count, 10)
        XCTAssertEqual(blocks[0], .heading(level: 1, content: [.text("Titolo della lezione")]))
        guard case .paragraph(let meta) = blocks[1] else { return XCTFail() }
        XCTAssertTrue(meta.contains(.lineBreak), "Due spazi finali = a capo")
        guard case .paragraph(let inlines) = blocks[3] else { return XCTFail() }
        XCTAssertEqual(inlines[0], .text("Il "))
        XCTAssertEqual(inlines[1], .bold([.text("Bauhaus")]))
        XCTAssertEqual(inlines[3], .italic([.text("Weimar")]))
        XCTAssertTrue(inlines.contains(.bold([.italic([.text("Gropius")])])))
        XCTAssertTrue(inlines.contains(.sourceReference(1...3)))
        XCTAssertTrue(inlines.contains(.code("codice")))
        XCTAssertTrue(inlines.contains(.uncertain("Stölzl")))
        XCTAssertEqual(blocks[4], .bulletList([[.text("primo punto")], [.text("secondo punto che continua")]]))
        XCTAssertEqual(blocks[5], .orderedList(start: 1, items: [[.text("uno")], [.text("due")]]))
        XCTAssertEqual(blocks[6], .blockquote([.text("Nota importante")]))
        XCTAssertEqual(blocks[7], .table(header: [[.text("Scuola")], [.text("Città")]], rows: [[[.text("Bauhaus")], [.text("Weimar")]]]))
        XCTAssertEqual(blocks[8], .image(alt: "Schema", source: "images/schema.png"))
        XCTAssertEqual(blocks[9], .rule)
    }

    func testUnderscoresInsideWordsAreNotItalic() {
        XCTAssertEqual(MarkdownParser.parseInlines("file_name_test e _corsivo_"), [.text("file_name_test e "), .italic([.text("corsivo")])])
        XCTAssertEqual(MarkdownParser.parseInlines("2 * 3 * 4"), [.text("2 * 3 * 4")])
    }

    func testPlainTextDropsReferences() {
        let blocks = MarkdownParser.parse("Testo con riferimento [[S4]] e **grassetto**.")
        XCTAssertEqual(MarkdownParser.plainText(blocks), "Testo con riferimento e grassetto.")
    }
}

final class DocxExporterTests: XCTestCase {
    let markdown = """
    # Il Bauhaus

    **Materia:** Storia del Design

    ## La fondazione

    Il **Bauhaus** nasce a *Weimar* nel 1919 & cresce. [[S1-S2]] Un nome [[incerto: Stölzl]].

    - punto uno
    - punto due

    1. primo
    2. secondo

    | A | B |
    |---|---|
    | 1 | 2 |

    > Citazione

    ![Figura](img.png)
    """

    // PNG 1×1 valido.
    let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0xF8, 0xCF, 0xC0, 0xF0, 0x1F, 0x00, 0x05, 0x00, 0x01, 0xFF, 0x89, 0x99, 0x3D, 0x1D, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82])

    func testDocxIsValidZipAndOpensInPythonDocx() throws {
        let image = DocxImage(data: png, fileExtension: "png", pixelWidth: 1, pixelHeight: 1)
        let data = DocxExporter(title: "Il Bauhaus", imageResolver: { $0 == "img.png" ? image : nil }).export(markdown: markdown)
        let directory = makeTemporaryDirectory()
        let url = directory.appendingPathComponent("test.docx")
        try data.write(to: url)

        // Integrità ZIP con unzip -t (se disponibile).
        if let unzip = which("unzip") {
            let output = try run(unzip, ["-t", url.path])
            XCTAssertTrue(output.contains("No errors detected"), output)
        }
        // Lettura con python-docx (se installato): verifica stili e testo.
        if let python = which("python3") {
            let script = """
            import sys
            try:
                import docx
            except ImportError:
                print("SKIP"); sys.exit(0)
            d = docx.Document(sys.argv[1])
            for p in d.paragraphs:
                print(p.style.name + "|" + p.text)
            print("TABLES|" + str(len(d.tables)))
            print("IMAGES|" + str(len(d.inline_shapes)))
            """
            let scriptURL = directory.appendingPathComponent("check.py")
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            let output = try run(python, ["-I", scriptURL.path, url.path])
            if !output.contains("SKIP") {
                XCTAssertTrue(output.contains("Title|Il Bauhaus"), output)
                XCTAssertTrue(output.contains("Heading 1|La fondazione"), output)
                XCTAssertTrue(output.contains("Normal|Il Bauhaus nasce a Weimar nel 1919 & cresce. Un nome [incerto: Stölzl]."), output)
                XCTAssertFalse(output.contains("[[S1"), "Riferimenti ai segmenti esclusi dall'export")
                XCTAssertTrue(output.contains("List Paragraph|punto uno"), output)
                XCTAssertTrue(output.contains("Quote|Citazione"), output)
                XCTAssertTrue(output.contains("TABLES|1"), output)
                XCTAssertTrue(output.contains("IMAGES|1"), output)
            }
        }
    }

    func testCRC32KnownValue() {
        XCTAssertEqual(CRC32.checksum(Data("123456789".utf8)), 0xCBF43926)
    }

    func testEscapingRemovesInvalidControlCharacters() {
        XCTAssertEqual(DocxExporter.escape("a<b>&\"c\u{0001}"), "a&lt;b&gt;&amp;&quot;c")
    }

    func which(_ tool: String) -> String? {
        for directory in ["/usr/bin", "/usr/local/bin", "/opt/homebrew/bin"] {
            let path = directory + "/" + tool
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    func run(_ executable: String, _ arguments: [String]) throws -> String {
        #if os(Linux) || os(macOS)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #else
        return "SKIP"
        #endif
    }
}
