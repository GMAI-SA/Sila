import XCTest

/// Signs in with a real account against the **deployed** backend and walks the
/// app — no mocks anywhere in the process.
///
/// Every other UI test runs on `AuthServiceMock` and `FeedServiceMock`, which
/// proves the screens are wired to each other but not that they are wired to
/// the server. This is the only test where a tap travels all the way to
/// Postgres and back, so it is what "the app works" actually means.
///
/// Opt-in, because it needs the network and a real account:
/// ```
/// TEST_RUNNER_SILA_LIVE_API=1 TEST_RUNNER_SILA_LIVE_EMAIL=… \
/// TEST_RUNNER_SILA_LIVE_PASSWORD=… xcodebuild … \
///   test -only-testing:SilaUITests/LiveSignInUITests
/// ```
final class LiveSignInUITests: XCTestCase {

    private var email = ""
    private var password = ""

    override func setUpWithError() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard env["SILA_LIVE_API"] == "1" else {
            throw XCTSkip("Live sign-in is opt-in — set SILA_LIVE_API=1")
        }
        guard let e = env["SILA_LIVE_EMAIL"], let p = env["SILA_LIVE_PASSWORD"] else {
            throw XCTSkip("Set SILA_LIVE_EMAIL and SILA_LIVE_PASSWORD")
        }
        email = e
        password = p
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testSignInAgainstTheLiveServerAndBrowse() throws {
        let app = XCUIApplication()
        // No -mockAuth: this talks to https://sila.gmai.sa for real.
        app.launchArguments = ["-noBiometrics"]
        app.launch()

        attach(app, "1 — Welcome")

        XCTAssertTrue(
            app.buttons["Sign In"].waitForExistence(timeout: 25),
            "never reached the welcome screen"
        )
        app.buttons["Sign In"].tap()

        let emailField = app.textFields.firstMatch
        XCTAssertTrue(emailField.waitForExistence(timeout: 10), "no email field")
        emailField.tap()
        emailField.typeText(email)

        let passwordField = app.secureTextFields.firstMatch
        XCTAssertTrue(passwordField.waitForExistence(timeout: 5), "no password field")
        passwordField.tap()
        passwordField.typeText(password)

        attach(app, "2 — Credentials entered")

        app.buttons.matching(identifier: "Sign In").element(boundBy: 0).tap()

        // The real network round trip, so allow generously for it.
        XCTAssertTrue(
            app.buttons["For You"].waitForExistence(timeout: 40),
            "signed in but never reached the feed — check the account is verified"
        )
        attach(app, "3 — Feed, live data")

        for tab in ["My Country", "International"] {
            let control = app.buttons[tab]
            if control.waitForExistence(timeout: 10) {
                control.tap()
                // Let the request land before capturing.
                _ = app.buttons["For You"].waitForExistence(timeout: 10)
                attach(app, "4 — \(tab), live data")
            }
        }

        if app.buttons["Explore"].waitForExistence(timeout: 5) {
            app.buttons["Explore"].tap()
            _ = app.staticTexts.firstMatch.waitForExistence(timeout: 10)
            attach(app, "5 — Explore, live trending")
        }
    }
}
