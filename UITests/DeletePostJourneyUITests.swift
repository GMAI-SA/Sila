import XCTest

/// Deleting your own post, driven through the real UI.
///
/// The view model passes in isolation — it always has — so the only thing that
/// can notice the confirmation failing to appear, or the menu item never being
/// offered, is a test that goes through the card itself.
final class DeletePostJourneyUITests: XCTestCase {

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
            // Nothing kept from the journey before this one.
            "-freshStorage",
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

    /// The whole journey: find your own post, ask to delete it, be asked
    /// whether you mean it, and watch it go.
    func testDeletingYourOwnPost() throws {
        let app = launchApp()
        signIn(app)

        XCTAssertTrue(app.buttons["For You"].waitForExistence(timeout: 20), "a verified account did not reach the feed")

        // The signed-in account is "aziz"; the first sample post is theirs.
        let mine = app.staticTexts["Abdulaziz Alwakeel"].firstMatch
        XCTAssertTrue(mine.waitForExistence(timeout: 10), "no post by the signed-in account to delete")

        // The visible button in the card's corner. Your own post used to have
        // nothing there at all — the safety verbs are absent on your own
        // words — so the only way to Delete was a long press nobody was told
        // about.
        let menu = app.buttons["post.menu.own"].firstMatch
        XCTAssertTrue(
            menu.waitForExistence(timeout: 10),
            "your own post has no menu button — the card cannot tell it is yours"
        )
        let ownPostsBefore = app.buttons.matching(identifier: "post.menu.own").count
        menu.tap()

        // A menu's items are not always `buttons` in the accessibility tree,
        // so this asks for anything carrying the label.
        let delete = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Delete Post"))
            .firstMatch
        XCTAssertTrue(
            delete.waitForExistence(timeout: 5),
            """
            your own post does not offer Delete. What was on screen after the tap:
            \(app.buttons.debugDescription)
            """
        )
        delete.tap()

        // The confirmation is the step most likely to be swallowed: it is
        // presented from the shell while the menu it was chosen from is still
        // dismissing.
        let confirm = app.buttons["Delete"].firstMatch
        XCTAssertTrue(
            confirm.waitForExistence(timeout: 10),
            "the confirmation never appeared — Delete did nothing at all"
        )
        confirm.tap()

        // One fewer card of your own on screen. Neither the author's name
        // nor the post's words can be the measure: the sample feed has more
        // than one post by this person, and another post quotes this one, so
        // its words legitimately stay on screen inside that quote.
        let ownPosts = app.buttons.matching(identifier: "post.menu.own")
        let deadline = Date().addingTimeInterval(10)
        while ownPosts.count >= ownPostsBefore, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        XCTAssertLessThan(
            ownPosts.count,
            ownPostsBefore,
            """
            the post is still on screen after being deleted \
            (own cards before: \(ownPostsBefore), after: \(ownPosts.count); \
            alerts on screen: \(app.alerts.count) \(app.alerts.debugDescription))
            """
        )
    }
}
