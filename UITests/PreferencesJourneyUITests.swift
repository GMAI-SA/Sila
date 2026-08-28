import XCTest

/// The sign-in → Profile → feed preferences journey, driven through the real UI.
///
/// Every view model here passes in isolation whether or not the screen is
/// reachable, so this is the only test that would notice the entry point going
/// missing — and a disclosure nobody can reach is the same as no disclosure.
///
/// Runs entirely against the mocks: no network, no seeded account.
final class PreferencesJourneyUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    private func launchApp(preferencesScenario: String = "populated") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-mockAuth", "-mockScenario", "verified",
            "-mockFeed", "-mockFeedScenario", "populated",
            "-mockPreferences", "-mockPreferencesScenario", preferencesScenario,
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
    }

    /// Profile carries a findable route into the screen, and the screen tells
    /// the user about the automatic labelling before asking them to tune it.
    func testProfileReachesFeedPreferencesAndTheDisclosureIsOnScreen() throws {
        let app = launchApp()
        signIn(app)

        XCTAssertTrue(
            app.buttons["For You"].waitForExistence(timeout: 20),
            "a verified account did not reach the feed"
        )

        app.buttons["Profile"].tap()

        let entry = app.buttons["Feed preferences"]
        XCTAssertTrue(
            entry.waitForExistence(timeout: 10),
            "the Profile tab has no route into feed preferences"
        )
        entry.tap()

        XCTAssertTrue(
            app.staticTexts["How topics are decided"].waitForExistence(timeout: 10),
            "the AI-labelling disclosure is not on the screen it belongs to"
        )
        XCTAssertTrue(
            app.staticTexts
                .containing(NSPredicate(format: "label CONTAINS 'sometimes wrong'"))
                .firstMatch
                .waitForExistence(timeout: 5),
            "the disclosure does not admit the labelling can be wrong"
        )
        add(screenshot(app, named: "Feed preferences — disclosure and summary"))

        // The twenty-row topic list and the muted-country editor are further
        // down the same scroll view.
        let interested = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Technology: Interested'")
        ).firstMatch
        app.swipeUp()
        app.swipeUp()
        XCTAssertTrue(
            interested.waitForExistence(timeout: 10),
            "the three-way stance control is missing from the topic rows"
        )
        add(screenshot(app, named: "Feed preferences — topic list"))

        app.swipeUp()
        app.swipeUp()
        app.swipeUp()
        add(screenshot(app, named: "Feed preferences — muted countries"))

        // The save affordance exists and starts out with nothing to save.
        XCTAssertTrue(app.buttons["Save"].waitForExistence(timeout: 5), "no save control")
        XCTAssertFalse(app.buttons["Save"].isEnabled, "a freshly loaded screen has nothing to save")

        app.buttons["Done"].tap()
        XCTAssertTrue(
            app.buttons["Feed preferences"].waitForExistence(timeout: 10),
            "Done did not return to Profile"
        )
    }

    /// The second entry point sits on the one feed the settings affect.
    func testTheInternationalFeedOffersTheSameScreen() throws {
        let app = launchApp()
        signIn(app)

        XCTAssertTrue(
            app.buttons["International"].waitForExistence(timeout: 20),
            "a verified account did not reach the feed"
        )
        app.buttons["International"].tap()

        let shortcut = app.buttons["Feed preferences"]
        XCTAssertTrue(
            shortcut.waitForExistence(timeout: 10),
            "the International feed has no shortcut to the filters that narrow it"
        )
        shortcut.tap()

        XCTAssertTrue(
            app.staticTexts["How topics are decided"].waitForExistence(timeout: 10),
            "the shortcut did not open feed preferences"
        )
        add(screenshot(app, named: "Feed preferences — from International"))
    }

    private func screenshot(_ app: XCUIApplication, named name: String) -> XCTAttachment {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        return attachment
    }
}
