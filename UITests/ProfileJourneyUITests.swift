import XCTest

/// Feed → a person → follow, and the Profile tab, driven through the real UI.
///
/// Every view model here passes in isolation whether or not the screens are
/// wired together, so this is the only test that would notice a tapped author
/// going nowhere, the follow button appearing on the viewer's own page, or the
/// Profile tab losing its route into account settings.
///
/// Runs entirely against the mocks, so no real account is followed or unfollowed.
final class ProfileJourneyUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    private func launchApp(profileScenario: String = "populated") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-mockAuth", "-mockScenario", "verified",
            "-mockFeed", "-mockFeedScenario", "populated",
            "-mockProfile", "-mockProfileScenario", profileScenario,
            "-noBiometrics"
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
        XCTAssertTrue(email.waitForExistence(timeout: 10), "no email field")
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

    private func screenshot(_ app: XCUIApplication, named name: String) -> XCTAttachment {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        return attachment
    }

    /// **The route.** A post's author is a control, and it opens that person.
    func testTappingAPostsAuthorOpensTheirProfile() throws {
        let app = launchApp()
        signIn(app)

        // The first card in For You is Maria's quote post.
        let author = app.buttons
            .matching(NSPredicate(format: "label BEGINSWITH 'Maria Souza'"))
            .firstMatch
        XCTAssertTrue(author.waitForExistence(timeout: 10), "no author control on a feed card")
        author.tap()

        XCTAssertTrue(
            app.staticTexts["@maria"].waitForExistence(timeout: 10),
            "tapping an author did not open their profile"
        )
        // The exclusion the screen is obliged to state, whatever is in the list.
        XCTAssertTrue(
            app.staticTexts
                .containing(NSPredicate(format: "label CONTAINS[c] 'Top-level posts only'"))
                .firstMatch
                .waitForExistence(timeout: 5),
            "the timeline does not admit that replies are missing"
        )
        add(screenshot(app, named: "Profile — someone else"))
    }

    /// The follow button reflects the relationship, and says so after the tap.
    func testFollowingSomebodyFlipsTheButtonAndUnfollowingPutsItBack() throws {
        let app = launchApp()
        signIn(app)

        app.buttons
            .matching(NSPredicate(format: "label BEGINSWITH 'Maria Souza'"))
            .firstMatch
            .tap()

        let follow = app.buttons["Follow"]
        XCTAssertTrue(follow.waitForExistence(timeout: 10), "no follow button on someone else's page")
        follow.tap()

        let following = app.buttons["Following"]
        XCTAssertTrue(
            following.waitForExistence(timeout: 10),
            "the button never adopted the stored relationship"
        )
        add(screenshot(app, named: "Profile — following"))

        following.tap()
        XCTAssertTrue(
            app.buttons["Follow"].waitForExistence(timeout: 10),
            "unfollowing left the button claiming a follow that is gone"
        )
    }

    /// **There is no follow button on your own page**, because the server
    /// answers `400 self_follow` — a disabled one would be an affordance for
    /// something that cannot happen. The editor takes its place.
    func testYourOwnProfileOffersTheEditorInsteadOfAFollowButton() throws {
        let app = launchApp()
        signIn(app)

        app.buttons["Profile"].tap()

        XCTAssertTrue(
            app.buttons["Edit profile"].waitForExistence(timeout: 10),
            "your own profile has no route into the existing editor"
        )
        XCTAssertFalse(app.buttons["Follow"].exists, "a follow button appeared on your own profile")
        XCTAssertFalse(app.buttons["Following"].exists)
        add(screenshot(app, named: "Profile — your own"))
    }

    /// The Profile tab is the way into deletion and the data export, so it must
    /// keep both settings routes now that it renders a real profile.
    func testTheProfileTabStillCarriesTheAccountAndPreferencesRoutes() throws {
        let app = launchApp()
        signIn(app)

        app.buttons["Profile"].tap()

        XCTAssertTrue(
            app.buttons["Account"].waitForExistence(timeout: 10),
            "the Profile tab lost its route into Account"
        )
        XCTAssertTrue(
            app.buttons["Feed preferences"].exists,
            "the Profile tab lost its route into feed preferences"
        )
        XCTAssertTrue(app.buttons["Sign out"].exists)
    }

    /// **The dead end.** A handle that belongs to nobody gets a plain
    /// explanation and *no* Try Again — retrying could only fail again.
    func testAnUnavailableAccountOffersNoRetry() throws {
        let app = launchApp(profileScenario: "notFound")
        signIn(app)

        app.buttons
            .matching(NSPredicate(format: "label BEGINSWITH 'Maria Souza'"))
            .firstMatch
            .tap()

        // `SLEmptyState` reads its title and subtitle as one element, so this
        // matches the sentence rather than a standalone label.
        XCTAssertTrue(
            app.staticTexts
                .containing(NSPredicate(format: "label CONTAINS[c] \"isn't available\""))
                .firstMatch
                .waitForExistence(timeout: 10),
            "a missing account did not produce the unavailable state"
        )
        XCTAssertFalse(
            app.buttons["Try again"].exists,
            "a retry button was offered for a handle that cannot start existing"
        )
        add(screenshot(app, named: "Profile — unavailable"))
    }
}
