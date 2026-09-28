import XCTest

/// Signs in with a real account against the **staging** backend and walks the
/// app — no mocks anywhere in the process.
///
/// Every other UI test runs on `AuthServiceMock` and `FeedServiceMock`, which
/// proves the screens are wired to each other but not that they are wired to
/// the server. This is the only test where a tap travels all the way to
/// Postgres and back, so it is what "the app works" actually means.
///
/// Opt-in, because it needs the network and an account **on staging**. The
/// app is launched with `-apiOrigin`, which a debug build honours, so every
/// request it makes goes to the staging API through the tunnel — production
/// is never called:
/// ```
/// ssh -N -L 8101:127.0.0.1:8101 -i ~/.ssh/geniusai_new ubuntu@185.216.21.10 &
/// TEST_RUNNER_SILA_LIVE_API=1 TEST_RUNNER_SILA_API_ORIGIN=http://127.0.0.1:8101 \
/// TEST_RUNNER_SILA_LIVE_EMAIL=… TEST_RUNNER_SILA_LIVE_PASSWORD=… xcodebuild … \
///   test -only-testing:SilaUITests/LiveSignInUITests
/// ```
final class LiveSignInUITests: XCTestCase {

    private var email = ""
    private var password = ""
    private var origin = ""

    override func setUpWithError() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard env["SILA_LIVE_API"] == "1" else {
            throw XCTSkip("Live sign-in is opt-in — set SILA_LIVE_API=1 and SILA_API_ORIGIN")
        }
        guard let o = env["SILA_API_ORIGIN"], !o.isEmpty else {
            XCTFail("Live tests run against the staging API: open the tunnel and set "
                    + "TEST_RUNNER_SILA_API_ORIGIN=http://127.0.0.1:8101")
            return
        }
        guard URL(string: o)?.host?.lowercased().hasSuffix("gmai.sa") != true else {
            XCTFail("Live tests never run against production (SILA_API_ORIGIN=\(o))")
            return
        }
        guard let e = env["SILA_LIVE_EMAIL"], let p = env["SILA_LIVE_PASSWORD"] else {
            throw XCTSkip("Set SILA_LIVE_EMAIL and SILA_LIVE_PASSWORD for an account on staging")
        }
        origin = o
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
        // No -mockAuth: this talks to the staging API for real. Nothing kept
        // from an earlier run: the last address signed in with would be in
        // the email field already, and the typed one would follow it.
        app.launchArguments = ["-noBiometrics", "-freshStorage", "-apiOrigin", origin]
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
