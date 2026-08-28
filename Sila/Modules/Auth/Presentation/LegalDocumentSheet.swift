import SwiftUI
import WebKit

/// A modal web view for the Terms of Service and Privacy Policy.
///
/// Uses `WKWebView` directly (wrapped in `UIViewRepresentable`) rather than
/// `SFSafariViewController`, so the document stays inside the app's chrome and
/// cannot be used as a general-purpose browser.
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
                    LegalWebView(url: url)
                        .accessibilityLabel(Text(document.title))
                        .accessibilityHint(Text("Scroll to read the full document"))
                } else {
                    SLEmptyState(
                        icon: "doc.text.magnifyingglass",
                        title: "Document unavailable",
                        subtitle: "We couldn't load the \(document.title). Please try again later."
                    )
                }
            }
            .tnScreenBackground()
            .tnNavigationBar(title: document.title)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", action: onClose)
                        .foregroundStyle(SLColor.primary)
                        .accessibilityLabel(Text("Done"))
                        .accessibilityHint(Text("Closes the \(document.title)"))
                }
            }
        }
    }
}

/// Minimal `WKWebView` wrapper: loads one URL, no navigation delegate tricks.
struct LegalWebView: UIViewRepresentable {

    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard webView.url != url else { return }
        webView.load(URLRequest(url: url))
    }
}

#Preview("LegalDocumentSheet") {
    LegalDocumentSheet(document: .terms, onClose: {})
}
