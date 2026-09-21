import XCTest

/// The subject strip, driven through the real UI.
///
/// The thing this test protects is not that a row of chips renders — it is
/// that the choice is *in the timeline* and that it is the same choice on
/// every tab. Both of those are properties of the shell, so no view-model
/// test can notice them going missing.
final class SubjectStripJourneyUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-mockAuth", "-mockScenario", "verified",
            "-mockFeed", "-mockFeedScenario", "populated",
            "-mockPreferences", "-mockPreferencesScenario", "populated",
            "-noBiometrics",
        ]
        app.launch()
        return app
    }

    private func signIn(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons["Sign In"].waitForExistence(timeout: 20), "never reached the welcome screen")
        app.buttons["Sign In"].tap()

        let email = app.textFields.firstMatch
        XCTAssertTrue(email.waitForExistence(timeout: 10), "no email field on the sign-in screen")
        email.tap()
        email.typeText("aziz@example.com")

        let password = app.secureTextFields.firstMatch
        XCTAssertTrue(password.waitForExistence(timeout: 5), "no password field")
        password.tap()
        password.typeText("Passw0rd!234")

        app.buttons.matching(identifier: "Sign In").element(boundBy: 0).tap()
    }

    private func chip(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)["feed.subject.\(id)"].firstMatch
    }

    /// One tap in the timeline narrows it, and the choice is still there after
    /// changing tabs.
    func testASubjectPinnedOnOneTimelineHoldsOnAllOfThem() throws {
        let app = launchApp()
        signIn(app)

        XCTAssertTrue(app.buttons["For You"].waitForExistence(timeout: 20), "a verified account did not reach the feed")

        let technology = chip(app, "technology")
        XCTAssertTrue(
            technology.waitForExistence(timeout: 10),
            "the subjects are not in the timeline — choosing one still means opening a settings screen"
        )
        technology.tap()

        XCTAssertTrue(
            technology.waitForExistence(timeout: 10),
            "the strip disappeared after a subject was pinned"
        )

        // The same choice, on a different tab, without being made again.
        app.buttons["International"].tap()
        let onInternational = chip(app, "technology")
        XCTAssertTrue(onInternational.waitForExistence(timeout: 10), "the strip is missing from International")
        XCTAssertTrue(
            onInternational.isSelected,
            "a subject pinned on For You did not hold on International — the choice is per tab, which is exactly what it must not be"
        )

        app.buttons["Following"].tap()
        XCTAssertTrue(
            chip(app, "technology").waitForExistence(timeout: 10),
            "the strip is missing from Following"
        )
    }

    /// The full screen is still one tap from the strip, and it is reachable
    /// without scrolling a row of twenty subjects to its end.
    func testTheStripKeepsARouteIntoTheFullScreen() throws {
        let app = launchApp()
        signIn(app)

        XCTAssertTrue(app.buttons["For You"].waitForExistence(timeout: 20), "a verified account did not reach the feed")

        // Found by its spoken label, which is what a person navigating by
        // VoiceOver has to hear anyway.
        let shortcut = app.buttons["Feed preferences"]
        XCTAssertTrue(shortcut.waitForExistence(timeout: 10), "the strip lost its route into feed preferences")
        XCTAssertTrue(shortcut.isHittable, "the route into preferences is on screen but cannot be tapped")
        shortcut.tap()

        XCTAssertTrue(
            app.staticTexts["How topics are decided"].waitForExistence(timeout: 10),
            "the strip's control did not open feed preferences"
        )
    }
}
