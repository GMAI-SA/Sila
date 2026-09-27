import XCTest
@testable import Sila

/// The Terms and Privacy sheets show the legal page, or say it is
/// unavailable — never the web app the host answers unknown paths with.
@MainActor
final class LegalDocumentTests: XCTestCase {

    private let terms = URL(string: "https://sila.gmai.sa/legal/terms")!

    // MARK: - Addresses

    func testEachSheetOpensItsOwnLegalPage() {
        XCTAssertEqual(AppRouter.LegalDocument.terms.url?.absoluteString, "https://sila.gmai.sa/legal/terms")
        XCTAssertEqual(AppRouter.LegalDocument.privacy.url?.absoluteString, "https://sila.gmai.sa/legal/privacy")
    }

    // MARK: - Navigation

    func testOnlyTheRequestedPageLoadsInTheSheet() {
        XCTAssertTrue(LegalPagePolicy.allowsNavigation(to: terms, requested: terms, isMainFrame: true))
        XCTAssertTrue(
            LegalPagePolicy.allowsNavigation(to: URL(string: "https://SILA.gmai.sa/legal/terms/#section-2"), requested: terms, isMainFrame: true),
            "the same page, with a fragment or a trailing slash, is the same page"
        )

        XCTAssertFalse(
            LegalPagePolicy.allowsNavigation(to: URL(string: "https://sila.gmai.sa/"), requested: terms, isMainFrame: true),
            "the web app's front page"
        )
        XCTAssertFalse(LegalPagePolicy.allowsNavigation(to: URL(string: "https://sila.gmai.sa/legal/privacy"), requested: terms, isMainFrame: true))
        XCTAssertFalse(LegalPagePolicy.allowsNavigation(to: URL(string: "https://evil.example/legal/terms"), requested: terms, isMainFrame: true))
        XCTAssertFalse(LegalPagePolicy.allowsNavigation(to: URL(string: "http://sila.gmai.sa/legal/terms"), requested: terms, isMainFrame: true))
        XCTAssertFalse(LegalPagePolicy.allowsNavigation(to: terms, requested: terms, isMainFrame: false), "no frames")
        XCTAssertFalse(LegalPagePolicy.allowsNavigation(to: nil, requested: terms, isMainFrame: true))
    }

    func testOnlyASuccessfulDocumentIsShown() {
        XCTAssertTrue(LegalPagePolicy.accepts(statusCode: 200, mimeType: "text/html"))
        XCTAssertTrue(LegalPagePolicy.accepts(statusCode: 200, mimeType: "TEXT/HTML"))
        XCTAssertTrue(LegalPagePolicy.accepts(statusCode: nil, mimeType: "text/html"), "a page loaded from a string")

        XCTAssertFalse(LegalPagePolicy.accepts(statusCode: 404, mimeType: "text/html"))
        XCTAssertFalse(LegalPagePolicy.accepts(statusCode: 502, mimeType: "text/html"))
        XCTAssertFalse(LegalPagePolicy.accepts(statusCode: 200, mimeType: "application/json"))
        XCTAssertFalse(LegalPagePolicy.accepts(statusCode: 200, mimeType: "application/javascript"))
    }

    func testTappedLinksLeaveTheAppRatherThanTheSheet() {
        XCTAssertTrue(LegalPagePolicy.opensExternally(URL(string: "https://sdaia.gov.sa/")))
        XCTAssertTrue(LegalPagePolicy.opensExternally(URL(string: "mailto:privacy@gmai.sa")))
        XCTAssertFalse(LegalPagePolicy.opensExternally(URL(string: "http://example.com/")))
        XCTAssertFalse(LegalPagePolicy.opensExternally(URL(string: "javascript:alert(1)")))
        XCTAssertFalse(LegalPagePolicy.opensExternally(nil))
    }

    // MARK: - What arrived

    private func outcome(of html: String) async -> LegalPageState {
        let loader = LegalPageLoader(url: terms, patience: 10)
        loader.start(html: html)
        let deadline = Date().addingTimeInterval(10)
        while loader.state == .loading, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return loader.state
    }

    /// What the host serves today for `/legal/terms`: the web app's shell.
    func testTheWebAppIsShownAsUnavailable() async {
        let shell = """
        <!doctype html><html lang="en"><head><meta charset="UTF-8"><title>Sila</title>
        <script type="module" src="/assets/index-abc123.js"></script></head>
        <body><div id="root"></div></body></html>
        """
        let state = await outcome(of: shell)
        XCTAssertEqual(state, .unavailable)
    }

    func testALegalPageIsShown() async {
        let page = """
        <!doctype html><html lang="en"><head><meta charset="UTF-8"><title>Terms of Service</title></head>
        <body><main><h1>Terms of Service</h1><p>These terms govern your use of Sila.</p></main></body></html>
        """
        let loader = LegalPageLoader(url: terms, patience: 10)
        loader.start(html: page)
        let deadline = Date().addingTimeInterval(10)
        while loader.state == .loading, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(loader.state, .document)
        XCTAssertFalse(loader.webView.accessibilityElementsHidden, "a confirmed page is readable")
    }

    /// No script from the page runs: one that tries to turn itself into the
    /// app (or into anything else) never gets the chance.
    func testThePagesOwnScriptsDoNotRun() async {
        let page = """
        <!doctype html><html><head><title>Privacy Policy</title>
        <script>document.addEventListener('DOMContentLoaded', function () {
          document.body.innerHTML = '<div id="root"></div>';
        });</script></head>
        <body><h1>Privacy Policy</h1></body></html>
        """
        let state = await outcome(of: page)
        XCTAssertEqual(state, .document, "a page script ran inside the sheet")
    }

    func testAnEmptyPageIsUnavailable() async {
        let state = await outcome(of: "<!doctype html><html><head><title></title></head><body>  </body></html>")
        XCTAssertEqual(state, .unavailable)
    }

    private func outcome(loading address: String) async -> LegalPageState {
        let loader = LegalPageLoader(url: URL(string: address)!, patience: 3)
        loader.start()
        let deadline = Date().addingTimeInterval(8)
        while loader.state == .loading, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return loader.state
    }

    /// Nothing listening: the connection is refused.
    func testAPageThatNeverArrivesIsUnavailable() async {
        let state = await outcome(loading: "https://127.0.0.1:65530/legal/terms")
        XCTAssertEqual(state, .unavailable)
    }

    /// A port WebKit refuses to use finishes as an empty page at no address;
    /// that is not the legal page either.
    func testALoadWebKitRefusesIsUnavailable() async {
        let state = await outcome(loading: "https://127.0.0.1:9/legal/terms")
        XCTAssertEqual(state, .unavailable)
    }

    func testTheWebViewRunsNoPageScriptsAndKeepsNothing() {
        let loader = LegalPageLoader(url: terms)
        XCTAssertEqual(loader.state, .loading)
        XCTAssertFalse(loader.webView.configuration.defaultWebpagePreferences.allowsContentJavaScript)
        XCTAssertFalse(loader.webView.configuration.websiteDataStore.isPersistent)
        XCTAssertTrue(loader.webView === loader.webView, "one web view per sheet")
        XCTAssertTrue(loader.webView.accessibilityElementsHidden, "nothing to read until a legal page is confirmed")
    }
}
