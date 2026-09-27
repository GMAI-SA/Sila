import Observation
import SwiftUI
import WebKit

/// A modal web view for the Terms of Service and Privacy Policy.
///
/// Uses `WKWebView` directly (wrapped in `UIViewRepresentable`) rather than
/// `SFSafariViewController`, so the document stays inside the app's chrome and
/// cannot be used as a general-purpose browser.
///
/// It shows the legal page or says the page is unavailable, and nothing
/// else. The host answers any path it does not know with the web app, so a
/// legal page that has not been published yet used to open the whole web
/// client inside the sign-up sheet, scripts running, for somebody who was
/// being asked to accept terms they could not read. ``LegalPageLoader`` is
/// the gate: only the requested address loads, no script from the page runs,
/// and a page that turns out to be the web app is shown as unavailable, as
/// the web client does.
@MainActor
public struct LegalDocumentSheet: View {

    private let document: AppRouter.LegalDocument
    private let onClose: () -> Void

    /// - Parameters:
    ///   - document: Which policy to load.
    ///   - onClose: Dismisses the sheet.
    public init(document: AppRouter.LegalDocument, onClose: @escaping () -> Void) {
        self.document = document
        self.onClose = onClose
    }

    public var body: some View {
        NavigationStack {
            Group {
                if let url = document.url {
                    Owned({ LegalPageLoader(url: url) }) { loader in
                        LegalPageView(loader: loader, document: document)
                    }
                } else {
                    unavailable
                }
            }
            .tnScreenBackground()
            .tnNavigationBar(title: document.title)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.t("common.done"), action: onClose)
                        .foregroundStyle(SLColor.primary)
                        .accessibilityLabel(Text(L10n.t("common.done")))
                        .accessibilityHint(Text(L10n.t("auth.legal.close.hint", document.title)))
                        .accessibilityIdentifier("legal.done")
                }
            }
        }
    }

    private var unavailable: some View {
        LegalUnavailableView(document: document)
    }
}

/// The document, a spinner while it loads, or the unavailable state.
@MainActor
private struct LegalPageView: View {

    let loader: LegalPageLoader
    let document: AppRouter.LegalDocument

    var body: some View {
        ZStack {
            // In the hierarchy from the start, so it loads, but invisible
            // until the loader has confirmed a legal page is what arrived.
            LegalWebView(loader: loader)
                .opacity(loader.state == .document ? 1 : 0)
                .accessibilityHidden(loader.state != .document)
                .accessibilityLabel(Text(document.title))
                .accessibilityHint(Text(L10n.t("auth.legal.read.hint")))
                .accessibilityIdentifier("legal.document")

            switch loader.state {
            case .loading:
                ProgressView()
                    .tint(SLColor.primary)
                    .accessibilityIdentifier("legal.loading")
            case .unavailable:
                LegalUnavailableView(document: document)
            case .document:
                EmptyView()
            }
        }
        .onAppear { loader.start() }
    }
}

/// The in-app placeholder for a legal page that is not there.
@MainActor
private struct LegalUnavailableView: View {

    let document: AppRouter.LegalDocument

    var body: some View {
        SLEmptyState(
            icon: "doc.text.magnifyingglass",
            title: L10n.t("auth.legal.unavailable.title"),
            subtitle: L10n.t("auth.legal.unavailable.subtitle", document.title)
        )
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("legal.unavailable")
    }
}

/// Hosts the loader's web view.
struct LegalWebView: UIViewRepresentable {

    let loader: LegalPageLoader

    func makeUIView(context: Context) -> WKWebView {
        loader.webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}
}

// MARK: - Loading

/// What the legal sheet is showing.
public enum LegalPageState: Equatable, Sendable {
    /// Still arriving.
    case loading
    /// A legal page, confirmed.
    case document
    /// Anything else: no answer, an error status, or the web app.
    case unavailable
}

/// The rules the legal sheet's web view lives by, apart from WebKit so each
/// can be tested on its own.
enum LegalPagePolicy {

    /// Whether a navigation may happen inside the sheet: the requested page,
    /// in the main frame, and nothing else — no link, redirect or frame takes
    /// the sheet anywhere.
    static func allowsNavigation(to url: URL?, requested: URL, isMainFrame: Bool) -> Bool {
        guard isMainFrame, let url else { return false }
        return normalised(url) == normalised(requested)
    }

    /// Whether an answer can be a legal page at all: a success, carrying a
    /// document rather than, say, JSON or an image.
    static func accepts(statusCode: Int?, mimeType: String?) -> Bool {
        if let statusCode, !(200..<300).contains(statusCode) { return false }
        guard let mimeType = mimeType?.lowercased() else { return true }
        return mimeType == "text/html" || mimeType == "text/plain" || mimeType == "application/xhtml+xml"
    }

    /// Run once the page has loaded; `true` means a document arrived.
    ///
    /// The web app's shell mounts into `<div id="root">`, which a legal page
    /// never has — exactly how the web client tells the two apart — and a
    /// page with no text is not a legal document either.
    static let documentProbe = """
        (function () {
          var body = document.body;
          return !document.getElementById('root') && !!body && body.innerText.trim().length > 0;
        })()
        """

    /// Links a person taps inside a legal page open outside the app.
    static func opensExternally(_ url: URL?) -> Bool {
        guard let scheme = url?.scheme?.lowercased() else { return false }
        return scheme == "https" || scheme == "mailto"
    }

    /// Scheme and host case-folded, the fragment and a trailing slash dropped.
    static func normalised(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
            return url.absoluteString
        }
        components.fragment = nil
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        if components.path.count > 1, components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        return components.string ?? url.absoluteString
    }
}

/// Loads one legal page into a locked-down web view and decides whether what
/// arrived is the page.
///
/// No script from the page runs (`allowsContentJavaScript` is off; the one
/// check the loader makes is its own), nothing is stored between sheets, and
/// the navigation delegate refuses every address but the requested one.
@MainActor
@Observable
public final class LegalPageLoader {

    /// What the sheet should show.
    public private(set) var state: LegalPageState = .loading

    /// The page requested.
    public let url: URL

    private let delegate = NavigationDelegate()
    @ObservationIgnored private var madeWebView: WKWebView?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var timeout: Task<Void, Never>?
    /// How long a page may take before the sheet says it is unavailable.
    private let patience: TimeInterval

    /// - Parameters:
    ///   - url: The legal page.
    ///   - patience: Seconds before an unanswered load counts as unavailable.
    public init(url: URL, patience: TimeInterval = 15) {
        self.url = url
        self.patience = patience
        delegate.loader = self
    }

    /// The web view the sheet hosts, made on first use: a loader SwiftUI
    /// builds and throws away on a re-render never makes one.
    public var webView: WKWebView {
        if let madeWebView { return madeWebView }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.allowsLinkPreview = false
        // Nothing VoiceOver can reach until a legal page is confirmed.
        webView.accessibilityElementsHidden = true
        webView.navigationDelegate = delegate
        madeWebView = webView
        return webView
    }

    /// Starts the load, once.
    public func start() {
        guard !started else { return }
        started = true
        armTimeout()
        webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: patience))
    }

    /// Loads `html` as though the requested address had answered with it. For
    /// tests: the same checks run on it as on a real answer.
    func start(html: String) {
        guard !started else { return }
        started = true
        armTimeout()
        webView.loadHTMLString(html, baseURL: url)
    }

    private func armTimeout() {
        let patience = patience
        timeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(patience * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.settle(.unavailable)
        }
    }

    /// Decides once. Later answers — a link refused after the page showed, a
    /// late failure — do not change what the sheet already says.
    fileprivate func settle(_ outcome: LegalPageState) {
        guard state == .loading else { return }
        timeout?.cancel()
        state = outcome
        madeWebView?.accessibilityElementsHidden = outcome != .document
        if outcome == .unavailable { madeWebView?.stopLoading() }
    }

    fileprivate func pageFinished() {
        guard state == .loading else { return }
        // What finished must be the page asked for: a load WebKit refused
        // outright finishes as an empty page at no address at all.
        guard LegalPagePolicy.allowsNavigation(to: webView.url, requested: url, isMainFrame: true) else {
            settle(.unavailable)
            return
        }
        webView.evaluateJavaScript(LegalPagePolicy.documentProbe) { [weak self] result, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Fails closed: a page that cannot be checked is not shown.
                guard error == nil, let isDocument = result as? Bool else {
                    self.settle(.unavailable)
                    return
                }
                self.settle(isDocument ? .document : .unavailable)
            }
        }
    }

    /// The loader's `WKNavigationDelegate`, kept apart so the loader itself
    /// stays a plain observable class.
    private final class NavigationDelegate: NSObject, WKNavigationDelegate {

        weak var loader: LegalPageLoader?

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            MainActor.assumeIsolated {
                guard let loader else { return decisionHandler(.cancel) }
                let target = navigationAction.request.url
                let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? false
                if LegalPagePolicy.allowsNavigation(to: target, requested: loader.url, isMainFrame: isMainFrame) {
                    return decisionHandler(.allow)
                }
                if navigationAction.navigationType == .linkActivated,
                   LegalPagePolicy.opensExternally(target), let target {
                    UIApplication.shared.open(target)
                } else if loader.state == .loading, isMainFrame {
                    // Sent somewhere else before anything showed: a redirect
                    // away from the legal page is not the legal page.
                    loader.settle(.unavailable)
                }
                decisionHandler(.cancel)
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationResponse: WKNavigationResponse,
            decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
        ) {
            MainActor.assumeIsolated {
                let response = navigationResponse.response
                let status = (response as? HTTPURLResponse)?.statusCode
                guard navigationResponse.isForMainFrame else { return decisionHandler(.cancel) }
                if LegalPagePolicy.accepts(statusCode: status, mimeType: response.mimeType) {
                    decisionHandler(.allow)
                } else {
                    loader?.settle(.unavailable)
                    decisionHandler(.cancel)
                }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            MainActor.assumeIsolated { loader?.pageFinished() }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            MainActor.assumeIsolated { loader?.settle(.unavailable) }
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            MainActor.assumeIsolated { loader?.settle(.unavailable) }
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            MainActor.assumeIsolated { loader?.settle(.unavailable) }
        }
    }
}

#Preview("LegalDocumentSheet") {
    LegalDocumentSheet(document: .terms, onClose: {})
}
