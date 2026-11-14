import Foundation
import Testing
import ZIPFoundation
@testable import AvenraCore

@Suite("EPUB documents")
struct EPUBDocumentTests {

    @Test("A minimal EPUB opens with spine order and titles")
    func opensMinimalBook() throws {
        let url = try Self.writeMinimalEPUB()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let book = try EPUBDocument.open(url)
        #expect(book.title == "Sample Book")
        #expect(book.chapters.count == 2)
        #expect(book.chapters[0].title == "Chapter One")
        #expect(book.chapters[1].title == "Chapter Two")
        #expect(FileManager.default.fileExists(atPath: book.chapters[0].fileURL.path))
    }

    @Test("Continuous reader concatenates chapters for scrolling")
    func continuousReader() throws {
        let url = try Self.writeMinimalEPUB()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let book = try EPUBDocument.open(url)
        var settings = EPUBReadingSettings()
        settings.fontSize = 20
        settings.paragraphSpacing = 18
        let reader = try book.continuousReaderURL(settings: settings)
        let html = try String(contentsOf: reader, encoding: .utf8)
        #expect(html.contains(EPUBDocument.anchorID(forChapterIndex: 0)))
        #expect(html.contains(EPUBDocument.anchorID(forChapterIndex: 1)))
        #expect(html.contains("One"))
        #expect(html.contains("Two"))
        #expect(html.contains("20.00pt"))
        #expect(html.contains("18.00pt"))
    }

    @Test("An encrypted EPUB is refused")
    func refusesEncryption() throws {
        let url = try Self.writeMinimalEPUB(includeEncryption: true)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        #expect(throws: EPUBDocument.OpenError.encrypted) {
            _ = try EPUBDocument.open(url)
        }
    }

    @Test("A non-zip file is refused")
    func refusesGarbage() throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "avenra-epub-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "fake.epub")
        try Data("not a zip".utf8).write(to: url)

        #expect(throws: EPUBDocument.OpenError.notAZip) {
            _ = try EPUBDocument.open(url)
        }
    }

    /// Builds a tiny EPUB 3 under a temp folder and returns the `.epub` URL.
    private static func writeMinimalEPUB(includeEncryption: Bool = false) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "avenra-epub-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let epubURL = dir.appending(path: "sample.epub")

        let archive = try Archive(url: epubURL, accessMode: .create)

        try add(archive, path: "mimetype", contents: Data("application/epub+zip".utf8))
        try add(
            archive,
            path: "META-INF/container.xml",
            contents: Data(
                """
                <?xml version="1.0"?>
                <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
                  <rootfiles>
                    <rootfile full-path="OEBPS/content.opf"
                      media-type="application/oebps-package+xml"/>
                  </rootfiles>
                </container>
                """.utf8
            )
        )
        if includeEncryption {
            try add(
                archive,
                path: "META-INF/encryption.xml",
                contents: Data("<encryption/>".utf8)
            )
        }
        try add(
            archive,
            path: "OEBPS/content.opf",
            contents: Data(
                """
                <?xml version="1.0"?>
                <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
                  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                    <dc:identifier id="uid">urn:uuid:test</dc:identifier>
                    <dc:title>Sample Book</dc:title>
                    <dc:language>en</dc:language>
                  </metadata>
                  <manifest>
                    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
                    <item id="c1" href="chap1.xhtml" media-type="application/xhtml+xml"/>
                    <item id="c2" href="chap2.xhtml" media-type="application/xhtml+xml"/>
                  </manifest>
                  <spine>
                    <itemref idref="c1"/>
                    <itemref idref="c2"/>
                  </spine>
                </package>
                """.utf8
            )
        )
        try add(
            archive,
            path: "OEBPS/nav.xhtml",
            contents: Data(
                """
                <?xml version="1.0"?>
                <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
                <body>
                  <nav epub:type="toc">
                    <ol>
                      <li><a href="chap1.xhtml">Chapter One</a></li>
                      <li><a href="chap2.xhtml">Chapter Two</a></li>
                    </ol>
                  </nav>
                </body>
                </html>
                """.utf8
            )
        )
        try add(
            archive,
            path: "OEBPS/chap1.xhtml",
            contents: Data("<html xmlns=\"http://www.w3.org/1999/xhtml\"><body><p>One</p></body></html>".utf8)
        )
        try add(
            archive,
            path: "OEBPS/chap2.xhtml",
            contents: Data("<html xmlns=\"http://www.w3.org/1999/xhtml\"><body><p>Two</p></body></html>".utf8)
        )

        return epubURL
    }

    private static func add(_ archive: Archive, path: String, contents: Data) throws {
        try archive.addEntry(
            with: path,
            type: .file,
            uncompressedSize: Int64(contents.count),
            provider: { position, size in
                let start = Int(position)
                return contents.subdata(in: start..<(start + size))
            }
        )
    }
}
