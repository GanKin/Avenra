import AVKit
import AvenraCore
import PDFKit
import SwiftUI
import WebKit

/// A vault file shown rather than edited.
///
/// Every file that was not a canvas used to open in the text editor, so a JPEG
/// in the sidebar became a screenful of mojibake — the app had the bytes and
/// showed them as the wrong thing, which is worse than declining to open it.
///
/// The last case matters as much as the first four. A vault holds whatever its
/// owner put there, and some of it this app will never render. Saying so, and
/// offering the two doors out, is a better answer than a blank page.
struct AttachmentView: View {
    let url: URL
    let kind: AttachmentKind

    @Environment(\.style) private var style

    var body: some View {
        Group {
            switch kind {
            case .image: image
            case .pdf: PDFPreview(url: url)
            case .html: HTMLPreview(url: url)
            case .audio, .video: VideoPlayer(player: AVPlayer(url: url))
            case .other: unsupported
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(style.background)
    }

    @ViewBuilder
    private var image: some View {
        // `PlatformImage` is NSImage or UIImage, from ThemeBridge.
        if let loaded = PlatformImage(contentsOfFile: url.path(percentEncoded: false)) {
            #if os(macOS)
            Image(nsImage: loaded).resizable().scaledToFit().padding(20)
            #else
            Image(uiImage: loaded).resizable().scaledToFit().padding(20)
            #endif
        } else {
            // The extension said image and the bytes disagreed. Falling through
            // to the same panel keeps the two doors out available rather than
            // leaving an empty frame.
            unsupported
        }
    }

    private var unsupported: some View {
        VStack(spacing: 14) {
            Image(systemName: "doc")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(style.faintText)
            VStack(spacing: 4) {
                Text(url.lastPathComponent)
                    .font(style.uiFont.weight(.medium))
                    .foregroundStyle(style.text)
                Text(fileSize)
                    .font(style.uiFont)
                    .foregroundStyle(style.secondaryText)
            }
            Text("Avenra cannot show this kind of file.")
                .font(style.uiFont)
                .foregroundStyle(style.secondaryText)
            HStack(spacing: 10) {
                #if os(macOS)
                Button("Open in Default App") { NSWorkspace.shared.open(url) }
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                #else
                ShareLink(item: url) { Text("Share…") }
                #endif
            }
            .buttonStyle(.bordered)
        }
        .padding(40)
    }

    private var fileSize: String {
        let bytes = (try? FileManager.default.attributesOfItem(
            atPath: url.path(percentEncoded: false))[.size] as? Int) ?? nil
        guard let bytes else { return "" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

/// PDFKit exists on both platforms and handles paging, selection and search;
/// rendering pages by hand would be a worse viewer for more code.
private struct PDFPreview {
    let url: URL
}

#if os(macOS)
extension PDFPreview: NSViewRepresentable {
    func makeNSView(context: Context) -> PDFView { configured() }
    func updateNSView(_ view: PDFView, context: Context) { reload(view) }
}
#else
extension PDFPreview: UIViewRepresentable {
    func makeUIView(context: Context) -> PDFView { configured() }
    func updateUIView(_ view: PDFView, context: Context) { reload(view) }
}
#endif

extension PDFPreview {
    fileprivate func configured() -> PDFView {
        let view = PDFView()
        view.autoScales = true
        reload(view)
        return view
    }

    fileprivate func reload(_ view: PDFView) {
        if view.document?.documentURL != url { view.document = PDFDocument(url: url) }
    }
}

/// Read-only vault HTML. Relative CSS and images beside the file resolve;
/// http(s) links leave the app rather than turning this into a browser.
private struct HTMLPreview {
    let url: URL
}

#if os(macOS)
extension HTMLPreview: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView(frame: .zero, configuration: Self.configuration())
        view.navigationDelegate = context.coordinator
        reload(view)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.rootDirectory = url.deletingLastPathComponent()
        reload(view)
    }

    func makeCoordinator() -> Coordinator { Coordinator(rootDirectory: url.deletingLastPathComponent()) }
}
#else
extension HTMLPreview: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView {
        let view = WKWebView(frame: .zero, configuration: Self.configuration())
        view.navigationDelegate = context.coordinator
        reload(view)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.rootDirectory = url.deletingLastPathComponent()
        reload(view)
    }

    func makeCoordinator() -> Coordinator { Coordinator(rootDirectory: url.deletingLastPathComponent()) }
}
#endif

extension HTMLPreview {
    fileprivate static func configuration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        return configuration
    }

    fileprivate func reload(_ view: WKWebView) {
        if view.url == url { return }
        view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var rootDirectory: URL

        init(rootDirectory: URL) {
            self.rootDirectory = rootDirectory
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let requestURL = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }

            if Self.isHTTP(requestURL) {
                #if os(macOS)
                NSWorkspace.shared.open(requestURL)
                #else
                UIApplication.shared.open(requestURL)
                #endif
                decisionHandler(.cancel)
                return
            }

            if requestURL.isFileURL {
                let root = rootDirectory.standardizedFileURL.path
                let target = requestURL.standardizedFileURL.path
                if target == root || target.hasPrefix(root + "/") {
                    decisionHandler(.allow)
                    return
                }
            }

            // Fragment-only / about:blank / unexpected schemes stay in-place when
            // WebKit asks; anything else is refused rather than fetched in-app.
            if requestURL.scheme == nil || requestURL.scheme == "about" {
                decisionHandler(.allow)
                return
            }
            decisionHandler(.cancel)
        }

        private static func isHTTP(_ url: URL) -> Bool {
            guard let scheme = url.scheme?.lowercased() else { return false }
            return scheme == "http" || scheme == "https"
        }
    }
}
