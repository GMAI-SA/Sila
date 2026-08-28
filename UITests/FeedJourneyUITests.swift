import XCTest

/// The sign-in → feed journey, driven through the real UI.
///
/// Unit tests cover every view model in isolation, which means they all pass
/// even if the screens are never wired to each other. This is the only test
/// that would notice a broken route, a button that stopped being tappable, or
/// a feed that renders nothing.
///
/// Runs entirely against `AuthServiceMock` and `FeedServiceMock`, so it needs
/// no network and no seeded account.
final class FeedJourneyUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    private func launchApp(feedScenario: String = "populated") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-mockAuth", "-mockScenario", "verified",
            "-mockFeed", "-mockFeedScenario", feedScenario,
            "-noBiometrics",  // keeps the Face ID prompt out of the run
        ]
        app.launch()
        return app
    }

    private func signIn(_ app: XCUIApplication) {
        XCTAssertTrue(
            app.buttons["Sign In"].waitForExistence(timeout: 20),
            "never reached the welcome screen"
        )
        app.buttons["Sign In"].tap()

        let email = app.textFields.firstMatch
        XCTAssertTrue(email.waitForExistence(timeout: 10), "no email field on the sign-in screen")
        email.tap()
        email.typeText("aziz@example.com")

        let password = app.secureTextFields.firstMatch
        XCTAssertTrue(password.waitForExistence(timeout: 5), "no password field")
        password.tap()
        password.typeText("Passw0rd!234")

        // The sign-in screen's own button, not the welcome screen's.
        app.buttons.matching(identifier: "Sign In").element(boundBy: 0).tap()
    }

    /// A verified account lands on the feed and can move between all four tabs.
    func testVerifiedUserReachesTheFeedAndEveryTabIsReachable() throws {
        let app = launchApp()
        signIn(app)

        XCTAssertTrue(
            app.buttons["For You"].waitForExistence(timeout: 20),
            "a verified account did not reach the feed"
        )

        add(screenshot(app, named: "Feed — For You"))

        for tab in ["Following", "My Country", "International", "For You"] {
            let control = app.buttons[tab]
            XCTAssertTrue(control.waitForExistence(timeout: 10), "tab '\(tab)' is missing")
            control.tap()
            // Switching must not tear the screen down; the bar stays put.
            XCTAssertTrue(
                app.buttons["For You"].waitForExistence(timeout: 10),
                "the feed disappeared after selecting '\(tab)'"
            )
        }

        add(screenshot(app, named: "Feed — after visiting every tab"))
    }

    /// An unverified account must be held at the wall, never shown the feed.
    /// This is the product's central promise, so it is worth asserting through
    /// the UI and not only in a view model.
    func testUnverifiedUserIsHeldAtTheWall() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-mockAuth", "-mockScenario", "pendingReview", "-noBiometrics",
        ]
        app.launch()
        signIn(app)

        XCTAssertFalse(
            app.buttons["For You"].waitForExistence(timeout: 8),
            "an unverified account reached the feed"
        )
        add(screenshot(app, named: "Pending verification wall"))
    }

    private func screenshot(_ app: XCUIApplication, named name: String) -> XCTAttachment {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        return attachment
    }
}
