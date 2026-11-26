import AppKit
import WebKit

/// Shows an agent's HTML preview in the imagine box. HTML and CSS only: no scripts, nothing
/// from the network, and no navigating away.
@MainActor
final class ImaginePreview: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    private var page: URL?
    private var blocksNetwork = false
    private var cachedSnapshot: CGImage?

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.suppressesIncrementalRendering = true
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
        // Transparent until the page paints, so the box never flashes white.
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear
        webView.allowsMagnification = false
        webView.allowsBackForwardNavigationGestures = false
        webView.wantsLayer = true
        webView.layer?.cornerRadius = 4
        webView.layer?.masksToBounds = true
    }

    /// Loads `page`, which may use files next to it, such as the screenshot of the area.
    func show(_ page: URL) {
        self.page = page
        cachedSnapshot = nil
        Task {
            if !blocksNetwork, let rules = await Self.networkRules() {
                webView.configuration.userContentController.add(rules)
                blocksNetwork = true
            }
            guard self.page == page else { return }
            webView.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        }
    }

    func clear() {
        page = nil
        cachedSnapshot = nil
        webView.loadHTMLString("", baseURL: nil)
    }

    /// The preview as it shows on screen, as a CGImage (falling back to the last cached
    /// capture when the preview is temporarily hidden).
    func snapshotImage() async -> CGImage? {
        guard page != nil else { return nil }
        if !webView.isHidden, let image = try? await webView.takeSnapshot(configuration: nil),
           let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            cachedSnapshot = cg
            return cg
        }
        return cachedSnapshot
    }

    /// The preview as it shows on screen, as PNG.
    func snapshot() async -> Data? {
        guard let cg = await snapshotImage() else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let loaded = page else { return }
        Task {
            guard self.page == loaded, !webView.isHidden,
                  let image = try? await webView.takeSnapshot(configuration: nil),
                  let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
            self.cachedSnapshot = cg
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        // Only the preview itself; links go nowhere.
        let url = navigationAction.request.url
        let isPage = url?.isFileURL == true && url?.standardizedFileURL.path == page?.standardizedFileURL.path
        let isBlank = url?.absoluteString == "about:blank"
        decisionHandler(isPage || isBlank ? .allow : .cancel)
    }

    private static var rules: WKContentRuleList?

    /// Blocks every network load. One rule per scheme: content rules can't use `|`.
    static func networkRules() async -> WKContentRuleList? {
        if let rules { return rules }
        let json = "[" + ["^https?://", "^wss?://", "^ftp://"].map {
            #"{"trigger":{"url-filter":"\#($0)"},"action":{"type":"block"}}"#
        }.joined(separator: ",") + "]"
        do {
            rules = try await WKContentRuleListStore.default()
                .compileContentRuleList(forIdentifier: "DeskDrawImagineOffline", encodedContentRuleList: json)
        } catch {
            NSLog("Desk Draw: couldn't block the network for Imagine previews: \(error)")
        }
        return rules
    }
}
