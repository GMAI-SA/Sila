import XCTest

/// The compose and explore journeys, driven through the real UI.
///
/// The view-model tests all pass even if the composer is never presented, the
/// scope picker is never rendered, or Explore is still wired to the old
/// placeholder. This is the only test that would notice.
///
/// Runs entirely against the mock stack (`-mockAuth` implies `-mockComposer`
/// and `-mockSearch`), so it needs no network and no seeded account.
final class ComposerJourneyUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    private func launchApp(composerScenario: String = "success") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-mockAuth", "-mockScenario", "verified",
            "-mockFeed", "-mockFeedScenario", "populated",
            "-mockComposer", "-mockComposerScenario", composerScenario,
            "-mockSearch", "-mockSearchScenario", "populated",
            "-noBiometrics",
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

        app.buttons.matching(identifier: "Sign In").element(boundBy: 0).tap()
        XCTAssertTrue(
            app.buttons["For You"].waitForExistence(timeout: 20),
            "a verified account did not reach the feed"
        )
    }

    /// The centre `[+]` opens a real composer, offers the scope picker, and
    /// posts — the thing that used to be a toast saying "later release".
    func testComposeButtonOpensTheComposerAndPostingClosesIt() throws {
        let app = launchApp()
        signIn(app)

        app.buttons["Post"].firstMatch.tap()

        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10), "the composer sheet never appeared")

        // The scope picker is the composer's centrepiece, and a verified 🇸🇦
        // account must be offered its own country.
        XCTAssertTrue(
            app.buttons["International. Any verified account anywhere can reply."].exists,
            "the scope picker is missing its International row"
        )
        XCTAssertTrue(
            app.buttons.containing(NSPredicate(format: "label CONTAINS 'Saudi Arabia'")).firstMatch.exists,
            "a verified Saudi account was not offered its own country scope"
        )

        add(screenshot(app, named: "Composer — scope picker"))

        editor.tap()
        editor.typeText("Posting from a UI test.")
        // The sheet's own toolbar button, not the tab bar's behind it.
        app.navigationBars.buttons["Post"].firstMatch.tap()

        XCTAssertTrue(
            app.buttons["For You"].waitForExistence(timeout: 15),
            "the composer did not close after a successful post"
        )
        add(screenshot(app, named: "Feed — after posting"))
    }

    /// Cancelling a draft asks before throwing it away.
    func testCancellingADraftAsksBeforeDiscarding() throws {
        let app = launchApp()
        signIn(app)

        app.buttons["Post"].firstMatch.tap()

        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.tap()
        editor.typeText("Half a thought")

        app.buttons["Cancel"].tap()

        let discard = app.buttons["Discard"]
        XCTAssertTrue(discard.waitForExistence(timeout: 5), "a draft was thrown away without asking")
        add(screenshot(app, named: "Composer — discard confirmation"))
        discard.tap()

        XCTAssertTrue(app.buttons["For You"].waitForExistence(timeout: 10))
    }

    /// Explore shows real trending tags instead of the Phase-3 placeholder.
    func testExploreShowsTrendingAndSearchesForATappedTag() throws {
        let app = launchApp()
        signIn(app)

        app.buttons["Explore"].tap()

        let tag = app.buttons.containing(NSPredicate(format: "label CONTAINS '#riyadh'")).firstMatch
        XCTAssertTrue(tag.waitForExistence(timeout: 15), "Explore is not showing trending tags")
        add(screenshot(app, named: "Explore — trending"))

        tag.tap()

        // Tapping a tag runs the search, so the People tab appears alongside Posts.
        XCTAssertTrue(
            app.buttons["People"].waitForExistence(timeout: 10),
            "tapping a trending tag did not run a search"
        )
        add(screenshot(app, named: "Explore — results for a tag"))
    }

    private func screenshot(_ app: XCUIApplication, named name: String) -> XCTAttachment {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        return attachment
    }
}
