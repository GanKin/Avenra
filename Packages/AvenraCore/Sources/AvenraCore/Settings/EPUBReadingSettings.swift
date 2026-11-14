import Foundation

/// How an EPUB looks when opened in the vault reader.
///
/// Separate from note `Typography`: a book is read, not edited, and people who
/// want Songti at 18pt for novels rarely want that as their Markdown body face.
public struct EPUBReadingSettings: Codable, Hashable, Sendable {
    public var font: FontChoice = .serif
    /// Body size in points.
    public var fontSize: Double = 18
    /// Multiple of the font size.
    public var lineHeightMultiple: Double = 1.7
    /// Space after a paragraph, in points.
    public var paragraphSpacing: Double = 14
    /// Extra tracking, in points.
    public var letterSpacing: Double = 0
    /// Column measure in points. Long lines tire the eye in continuous scroll.
    public var maxWidth: Double = 680

    public init() {}

    /// CSS injected into the continuous reader, after the book's own sheets so
    /// these preferences win on the body without rewriting every chapter.
    public var readerCSS: String {
        let family = font.cssFontFamily
        return """
        html body {
          margin: 0 auto !important;
          padding: 1.5rem 1.25rem 4rem !important;
          max-width: \(css(maxWidth))pt !important;
          font-family: \(family) !important;
          font-size: \(css(fontSize))pt !important;
          line-height: \(css(lineHeightMultiple)) !important;
          letter-spacing: \(css(letterSpacing))pt !important;
        }
        html body p {
          margin-top: 0 !important;
          margin-bottom: \(css(paragraphSpacing))pt !important;
        }
        section[data-avenra-chapter] + section[data-avenra-chapter] {
          margin-top: 2.5rem;
          padding-top: 2.5rem;
          border-top: 1px solid rgba(127,127,127,0.35);
        }
        img, svg, video { max-width: 100%; height: auto; }
        """
    }

    private func css(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}

extension FontChoice {
    /// A CSS `font-family` list that maps the same choices the native UI uses.
    public var cssFontFamily: String {
        switch self {
        case .system:
            return #"-apple-system, BlinkMacSystemFont, "PingFang SC", "Hiragino Sans GB", "Noto Sans CJK SC", sans-serif"#
        case .serif:
            return #"ui-serif, "Songti SC", "Songti TC", "STSong", "Noto Serif CJK SC", Georgia, serif"#
        case .rounded:
            return #"ui-rounded, "PingFang SC", "Hiragino Sans GB", sans-serif"#
        case .monospaced:
            return #"ui-monospace, Menlo, "SF Mono", monospace"#
        case .named(let name):
            let escaped = name
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\", serif"
        }
    }
}
