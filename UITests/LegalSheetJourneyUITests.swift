import XCTest

/// Create Account → Terms of Service / Privacy Policy, through the real UI.
///
/// The sheets load `https://sila.gmai.sa/legal/terms` and `/legal/privacy`.
/// Until those pages are published the host answers them with the web app,
/// and the sheet used to show the whole web client, scripts running, to
/// somebody being asked to accept terms. Whatever the host answers now, the
/// sheet shows the legal page or says it is unavailable — never the app.
///
/// Signed out and on the mocks: the only request is a GET of a public page.
final class LegalSheetJourneyUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    private func openRegister() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-freshStorage", "-mockAuth", "-mockScenario", "verified", "-noBiometrics"]
        app.launch()
        let create = app.buttons["Create Account"]
        XCTAssertTrue(create.waitForExistence(timeout: 20), "never reached the welcome screen")
        create.tap()
        return app
    }

    private func assertShowsTheDocumentOrSaysItIsUnavailable(_ app: XCUIApplication, title: String) {
        let sheetTitle = app.navigationBars[title]
        XCTAssertTrue(sheetTitle.waitForExistence(timeout: 10), "the \(title) sheet never opened")

        // The web view is hidden from accessibility until the loader has
        // confirmed a legal page arrived, so either marker is a verdict.
        let unavailable = app.descendants(matching: .any).matching(identifier: "legal.unavailable").firstMatch
        let document = app.webViews.firstMatch
        let settled = NSPredicate { _, _ in unavailable.exists || document.exists }
        let wait = XCTNSPredicateExpectation(predicate: settled, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [wait], timeout: 25), .completed, "the \(title) sheet never settled")

        // The web app's own chrome — its sign-in and its tabs — must not be
        // what the sheet is showing.
        XCTAssertFalse(app.webViews.buttons["Sign In"].exists, "the sheet is showing the web app")
        XCTAssertFalse(app.webViews.buttons["Create account"].exists, "the sheet is showing the web app")

        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        shot.name = "Legal — \(title)"
        shot.lifetime = .keepAlways
        add(shot)

        app.buttons["legal.done"].tap()
        XCTAssertTrue(app.buttons[title].waitForExistence(timeout: 10), "Done did not close the sheet")
    }

    func testTermsShowTheTermsOrSayTheyAreUnavailable() {
        let app = openRegister()
        let terms = app.buttons["Terms of Service"]
        for _ in 0..<3 where !terms.isHittable { app.swipeUp() }
        XCTAssertTrue(terms.waitForExistence(timeout: 10), "the register screen has no Terms link")
        terms.tap()
        assertShowsTheDocumentOrSaysItIsUnavailable(app, title: "Terms of Service")
    }

    func testPrivacyShowsThePolicyOrSaysItIsUnavailable() {
        let app = openRegister()
        let privacy = app.buttons["Privacy Policy"]
        for _ in 0..<3 where !privacy.isHittable { app.swipeUp() }
        XCTAssertTrue(privacy.waitForExistence(timeout: 10), "the register screen has no Privacy link")
        privacy.tap()
        assertShowsTheDocumentOrSaysItIsUnavailable(app, title: "Privacy Policy")
    }
}
