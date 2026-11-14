import Foundation
import ZIPFoundation

/// One readable chapter in an EPUB spine order.
public struct EPUBChapter: Hashable, Sendable, Identifiable {
    public var id: String { href }
    /// Path relative to the OPF directory (as in the manifest).
    public let href: String
    public let title: String
    /// Absolute file URL inside the extracted book root.
    public let fileURL: URL
}

/// A vault EPUB unpacked and parsed far enough to read chapter by chapter.
///
/// EPUB is a ZIP of XHTML plus a package document. This type extracts once into
/// a cache keyed by path and modification time, then reads
/// `META-INF/container.xml` → the OPF → spine. DRM (presence of
/// `META-INF/encryption.xml`) is refused rather than half-opened.
public struct EPUBDocument: Sendable {
    public let title: String
    /// Root of the extracted archive — pass this to `loadFileURL` access scope.
    public let rootDirectory: URL
    public let chapters: [EPUBChapter]

    public enum OpenError: Error, Equatable, Sendable {
        case notAZip
        case encrypted
        case missingContainer
        case missingPackage
        case emptySpine
    }

    /// Opens `url`, extracting when the cache is missing or stale.
    public static func open(_ url: URL) throws -> EPUBDocument {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate?.timeIntervalSince1970 ?? 0
        let cacheRoot = try cacheDirectory(for: url, modified: modified)

        if !FileManager.default.fileExists(atPath: cacheRoot.appending(path: "META-INF/container.xml").path) {
            try extract(from: url, to: cacheRoot)
        }

        if FileManager.default.fileExists(
            atPath: cacheRoot.appending(path: "META-INF/encryption.xml").path
        ) {
            throw OpenError.encrypted
        }

        let containerURL = cacheRoot.appending(path: "META-INF/container.xml")
        guard let containerData = try? Data(contentsOf: containerURL),
              let rootfile = ContainerParser.rootfilePath(in: containerData)
        else {
            throw OpenError.missingContainer
        }

        let packageURL = cacheRoot.appending(path: rootfile)
        guard let packageData = try? Data(contentsOf: packageURL) else {
            throw OpenError.missingPackage
        }

        let packageDir = packageURL.deletingLastPathComponent()
        let parsed = try PackageParser.parse(packageData)
        let tocTitles = TOCResolver.titles(
            packageData: packageData,
            packageDirectory: packageDir,
            manifest: parsed.manifest
        )

        var chapters: [EPUBChapter] = []
        chapters.reserveCapacity(parsed.spine.count)
        for href in parsed.spine {
            let fileURL = packageDir.appending(path: href)
            guard FileManager.default.fileExists(atPath: fileURL.path) else { continue }
            let title = tocTitles[normalizedPath(href)]
                ?? URL(fileURLWithPath: href).deletingPathExtension().lastPathComponent
            chapters.append(EPUBChapter(href: href, title: title, fileURL: fileURL))
        }
        guard !chapters.isEmpty else { throw OpenError.emptySpine }

        return EPUBDocument(
            title: parsed.title.isEmpty ? url.deletingPathExtension().lastPathComponent : parsed.title,
            rootDirectory: cacheRoot,
            chapters: chapters
        )
    }

    /// Stable element id for chapter `index` in the continuous reader page.
    public static func anchorID(forChapterIndex index: Int) -> String {
        "avenra-chapter-\(index)"
    }

    /// One long HTML page that concatenates every spine item so reading is a
    /// single scroll, the way a webpage is. Written into the extract cache.
    public func continuousReaderURL() throws -> URL {
        let reader = rootDirectory.appending(path: "avenra-reader.html")
        var stylesheets: [String] = []
        var seenSheets = Set<String>()
        var sections: [String] = []

        // Spine href → in-page anchor, so cross-chapter links keep working.
        var hrefToAnchor: [String: String] = [:]
        for (index, chapter) in chapters.enumerated() {
            let anchor = Self.anchorID(forChapterIndex: index)
            hrefToAnchor[Self.normalizedPath(chapter.href)] = "#" + anchor
            hrefToAnchor[Self.normalizedPath(chapter.fileURL.lastPathComponent)] = "#" + anchor
        }

        for (index, chapter) in chapters.enumerated() {
            let raw = (try? String(contentsOf: chapter.fileURL, encoding: .utf8)) ?? ""
            let prefix = Self.pathPrefix(from: reader, toDirectoryOf: chapter.fileURL)
            for sheet in Self.stylesheetHrefs(in: raw) {
                let resolved = Self.join(prefix: prefix, relative: sheet)
                if seenSheets.insert(resolved).inserted {
                    stylesheets.append(resolved)
                }
            }
            var body = Self.bodyInnerHTML(of: raw)
            body = Self.rewriteResourceURLs(in: body, pathPrefix: prefix)
            body = Self.rewriteSpineLinks(in: body, hrefToAnchor: hrefToAnchor, pathPrefix: prefix)
            let anchor = Self.anchorID(forChapterIndex: index)
            sections.append(
                """
                <section id="\(anchor)" data-avenra-chapter="\(index)">
                \(body)
                </section>
                """
            )
        }

        let sheetTags = stylesheets.map {
            #"<link rel="stylesheet" href="\#($0.addingHTMLAttributeEscapes)"/>"#
        }.joined(separator: "\n")

        let html = """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8"/>
        <meta name="viewport" content="width=device-width, initial-scale=1"/>
        <title>\(title.addingHTMLAttributeEscapes)</title>
        \(sheetTags)
        <style>
          body { margin: 0 auto; padding: 1.5rem 1.25rem 4rem; max-width: 42rem;
                 line-height: 1.6; font-size: 1.05rem; }
          section[data-avenra-chapter] + section[data-avenra-chapter] {
            margin-top: 2.5rem; padding-top: 2.5rem;
            border-top: 1px solid rgba(127,127,127,0.35);
          }
          img, svg, video { max-width: 100%; height: auto; }
        </style>
        </head>
        <body>
        \(sections.joined(separator: "\n"))
        </body>
        </html>
        """
        try html.write(to: reader, atomically: true, encoding: .utf8)
        return reader
    }

    // MARK: - Continuous HTML helpers

    /// Directory of `file`, expressed relative to the continuous reader's folder.
    private static func pathPrefix(from reader: URL, toDirectoryOf file: URL) -> String {
        let readerDir = reader.deletingLastPathComponent().standardizedFileURL.path
        let chapterDir = file.deletingLastPathComponent().standardizedFileURL.path
        guard chapterDir.hasPrefix(readerDir) else { return "" }
        var rest = String(chapterDir.dropFirst(readerDir.count))
        if rest.hasPrefix("/") { rest.removeFirst() }
        return rest
    }

    private static func join(prefix: String, relative: String) -> String {
        if relative.hasPrefix("/") { return String(relative.dropFirst()) }
        if relative.hasPrefix("http://") || relative.hasPrefix("https://")
            || relative.hasPrefix("data:") || relative.hasPrefix("#") {
            return relative
        }
        if prefix.isEmpty { return relative }
        return prefix + "/" + relative
    }

    private static func stylesheetHrefs(in html: String) -> [String] {
        let pattern = #"<link\b[^>]*rel=["']stylesheet["'][^>]*>"#
        guard let linkRe = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return []
        }
        let ns = html as NSString
        let full = NSRange(location: 0, length: ns.length)
        var hrefs: [String] = []
        for match in linkRe.matches(in: html, range: full) {
            let tag = ns.substring(with: match.range)
            if let href = attribute("href", in: tag) { hrefs.append(href) }
        }
        return hrefs
    }

    private static func bodyInnerHTML(of html: String) -> String {
        guard let bodyRe = try? NSRegularExpression(
            pattern: #"<body\b[^>]*>(.*)</body>"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else {
            return html
        }
        let ns = html as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard let match = bodyRe.firstMatch(in: html, range: full), match.numberOfRanges > 1 else {
            return html
        }
        return ns.substring(with: match.range(at: 1))
    }

    private static func rewriteResourceURLs(in html: String, pathPrefix: String) -> String {
        guard !pathPrefix.isEmpty else { return html }
        var result = html
        for attr in ["src", "href"] {
            result = rewriteAttribute(attr, in: result) { value in
                if value.hasPrefix("#") || value.hasPrefix("http://") || value.hasPrefix("https://")
                    || value.hasPrefix("data:") || value.hasPrefix("mailto:") || value.hasPrefix("file:") {
                    return value
                }
                return join(prefix: pathPrefix, relative: value)
            }
        }
        return result
    }

    private static func rewriteSpineLinks(
        in html: String,
        hrefToAnchor: [String: String],
        pathPrefix: String
    ) -> String {
        rewriteAttribute("href", in: html) { value in
            if value.hasPrefix("#") || value.hasPrefix("http://") || value.hasPrefix("https://")
                || value.hasPrefix("mailto:") {
                return value
            }
            let resolved = join(prefix: pathPrefix, relative: value)
            let key = normalizedPath(resolved)
            if let anchor = hrefToAnchor[key] { return anchor }
            let fileKey = normalizedPath(URL(fileURLWithPath: resolved).lastPathComponent)
            return hrefToAnchor[fileKey] ?? resolved
        }
    }

    private static func rewriteAttribute(
        _ name: String,
        in html: String,
        transform: (String) -> String
    ) -> String {
        let pattern = #"\#(name)=["']([^"']+)["']"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return html
        }
        let ns = html as NSString
        let full = NSRange(location: 0, length: ns.length)
        var output = html
        // Replace from the end so earlier ranges stay valid.
        for match in re.matches(in: html, range: full).reversed() {
            guard match.numberOfRanges > 1 else { continue }
            let value = ns.substring(with: match.range(at: 1))
            let replacement = #"\#(name)="\#(transform(value).addingHTMLAttributeEscapes)""#
            if let range = Range(match.range, in: output) {
                output.replaceSubrange(range, with: replacement)
            }
        }
        return output
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = #"\#(name)=["']([^"']+)["']"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return nil
        }
        let ns = tag as NSString
        guard let match = re.firstMatch(in: tag, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges > 1
        else { return nil }
        return ns.substring(with: match.range(at: 1))
    }

    // MARK: - Cache / extract

    private static func cacheDirectory(for url: URL, modified: TimeInterval) throws -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let key = stableKey(path: url.path, modified: modified)
        let dir = base.appending(path: "avenra-epub").appending(path: key)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func stableKey(path: String, modified: TimeInterval) -> String {
        let stamp = String(Int(modified))
        let raw = path + "|" + stamp
        // Path-safe, short enough for a directory name; collisions would only
        // force a re-extract of the wrong book, which open() rebuilds from the
        // source URL the next time the mtime changes.
        return raw.data(using: .utf8)!.base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
    }

    private static func extract(from source: URL, to destination: URL) throws {
        // Wipe a half-written cache before filling it again.
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)

        let archive: Archive
        do {
            archive = try Archive(url: source, accessMode: .read)
        } catch {
            throw OpenError.notAZip
        }
        for entry in archive {
            // Skip directory entries; extracting a file creates parents.
            guard entry.type == .file else { continue }
            let out = destination.appending(path: entry.path)
            try fm.createDirectory(
                at: out.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            _ = try archive.extract(entry, to: out)
        }
    }

    fileprivate static func normalizedPath(_ path: String) -> String {
        var p = path
        if let hash = p.firstIndex(of: "#") {
            p = String(p[..<hash])
        }
        return URL(fileURLWithPath: p).standardizedFileURL.path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
    }
}

// MARK: - container.xml

private enum ContainerParser {
    static func rootfilePath(in data: Data) -> String? {
        let parser = SimpleXML(data: data)
        parser.parse()
        // <rootfile full-path="OEBPS/content.opf" …/>
        return parser.elements
            .first { $0.localName == "rootfile" }?
            .attributes["full-path"]
            ?? parser.elements.first { $0.localName == "rootfile" }?.attributes["fullPath"]
    }
}

// MARK: - OPF package

private struct PackageParser {
    struct Result {
        var title: String
        var manifest: [String: String] // id → href
        var spine: [String] // hrefs in reading order
        var navHref: String?
        var ncxHref: String?
    }

    static func parse(_ data: Data) throws -> Result {
        let xml = SimpleXML(data: data)
        xml.parse()

        var title = ""
        var manifest: [String: String] = [:]
        var spineIDs: [String] = []
        var navHref: String?
        var ncxHref: String?

        for el in xml.elements {
            switch el.localName {
            case "title" where title.isEmpty:
                title = el.text.trimmingCharacters(in: .whitespacesAndNewlines)
            case "item":
                guard let id = el.attributes["id"], let href = el.attributes["href"] else { continue }
                manifest[id] = href
                var mediaType = ""
                for (k, v) in el.attributes where k.lowercased() == "media-type" {
                    mediaType = v
                }
                if let props = el.attributes["properties"],
                   props.split(whereSeparator: \.isWhitespace).contains("nav") {
                    navHref = href
                }
                if mediaType.contains("ncx") {
                    ncxHref = href
                }
            case "itemref":
                if let idref = el.attributes["idref"] {
                    spineIDs.append(idref)
                }
            default:
                break
            }
        }

        let spine = spineIDs.compactMap { manifest[$0] }
        guard !spine.isEmpty else { throw EPUBDocument.OpenError.emptySpine }

        return Result(
            title: title,
            manifest: manifest,
            spine: spine,
            navHref: navHref,
            ncxHref: ncxHref
        )
    }
}

// MARK: - TOC titles

private enum TOCResolver {
    /// Maps normalized href → display title from nav or NCX when present.
    static func titles(
        packageData: Data,
        packageDirectory: URL,
        manifest: [String: String]
    ) -> [String: String] {
        let xml = SimpleXML(data: packageData)
        xml.parse()

        var navHref: String?
        var ncxHref: String?
        for el in xml.elements where el.localName == "item" {
            let href = el.attributes["href"]
            if let props = el.attributes["properties"],
               props.split(whereSeparator: \.isWhitespace).contains("nav") {
                navHref = href
            }
            for (k, v) in el.attributes where k.lowercased() == "media-type" && v.contains("ncx") {
                ncxHref = href
            }
        }
        _ = manifest

        if let navHref,
           let data = try? Data(contentsOf: packageDirectory.appending(path: navHref)) {
            let fromNav = parseNav(data, relativeTo: navHref)
            if !fromNav.isEmpty { return fromNav }
        }
        if let ncxHref,
           let data = try? Data(contentsOf: packageDirectory.appending(path: ncxHref)) {
            return parseNCX(data)
        }
        return [:]
    }

    private static func parseNav(_ data: Data, relativeTo navHref: String) -> [String: String] {
        let xml = SimpleXML(data: data)
        xml.parse()
        var result: [String: String] = [:]
        let navDir = URL(fileURLWithPath: navHref).deletingLastPathComponent().path
        // Walk <a href="…">text</a>
        var i = 0
        let els = xml.elements
        while i < els.count {
            let el = els[i]
            if el.localName == "a", let href = el.attributes["href"] {
                let resolved = resolve(href, relativeToDirectory: navDir)
                let label = el.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !label.isEmpty {
                    result[EPUBDocument.normalizedPath(resolved)] = label
                }
            }
            i += 1
        }
        return result
    }

    private static func parseNCX(_ data: Data) -> [String: String] {
        let xml = SimpleXML(data: data)
        xml.parse()
        var result: [String: String] = [:]
        var pendingLabel: String?
        for el in xml.elements {
            if el.localName == "text" {
                pendingLabel = el.text.trimmingCharacters(in: .whitespacesAndNewlines)
            } else if el.localName == "content", let src = el.attributes["src"], let label = pendingLabel,
                      !label.isEmpty {
                result[EPUBDocument.normalizedPath(src)] = label
                pendingLabel = nil
            }
        }
        return result
    }

    private static func resolve(_ href: String, relativeToDirectory dir: String) -> String {
        if href.hasPrefix("/") { return String(href.dropFirst()) }
        if dir.isEmpty || dir == "." { return href }
        return dir + "/" + href
    }
}

// MARK: - Minimal XML

private extension String {
    var addingHTMLAttributeEscapes: String {
        replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
    }
}

/// Collects elements and text without building a DOM. Enough for OPF / nav / NCX.
private final class SimpleXML: NSObject, XMLParserDelegate {
    struct Element {
        var localName: String
        var attributes: [String: String]
        var text: String
    }

    private let parser: XMLParser
    private(set) var elements: [Element] = []
    private var stack: [Element] = []

    init(data: Data) {
        parser = XMLParser(data: data)
        super.init()
        parser.delegate = self
        parser.shouldProcessNamespaces = true
    }

    func parse() {
        _ = parser.parse()
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let local = elementName.split(separator: ":").last.map(String.init) ?? elementName
        // Also strip namespace from attribute keys' prefixes for lookups.
        var attrs: [String: String] = [:]
        for (k, v) in attributeDict {
            let key = k.split(separator: ":").last.map(String.init) ?? k
            attrs[key] = v
            attrs[k] = v
        }
        stack.append(Element(localName: local, attributes: attrs, text: ""))
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard !stack.isEmpty else { return }
        stack[stack.count - 1].text += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard let finished = stack.popLast() else { return }
        elements.append(finished)
    }
}
