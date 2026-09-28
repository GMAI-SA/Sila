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

    private func launchApp(composerScenario: String = "success", gifScenario: String = "populated") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-mockAuth", "-mockScenario", "verified",
            "-mockFeed", "-mockFeedScenario", "populated",
            "-mockComposer", "-mockComposerScenario", composerScenario,
            "-mockGifScenario", gifScenario,
            "-mockSearch", "-mockSearchScenario", "populated",
            "-noBiometrics",
            // Nothing kept from the journey before this one.
            "-freshStorage",
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

    /// Opens the composer the way a person does: the round button in the
    /// bottom corner of the feed. Fails loudly rather than silently doing
    /// nothing, because a missing entry point is precisely the regression
    /// worth catching here.
    private func openComposer(_ app: XCUIApplication) {
        let button = app.descendants(matching: .any)["feed.fab"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 15), "the feed has no post button")
        button.tap()
    }

    /// The feed's compose row opens a real composer, offers the scope picker,
    /// and posts — the thing that used to be a toast saying "later release".
    ///
    /// Driven by identifier, not by the label "Post": that label belongs to the
    /// composer's own submit button too, and matching it by text is what made
    /// the old version of this test need a comment explaining which "Post" it
    /// meant.
    func testComposeButtonOpensTheComposerAndPostingClosesIt() throws {
        let app = launchApp()
        signIn(app)

        openComposer(app)

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

        openComposer(app)

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

    /// Holds the round button until its choices fan out.
    private func holdFloatingButton(_ app: XCUIApplication) {
        let button = app.descendants(matching: .any)["feed.fab"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 15), "the feed has no post button")
        button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.9)
        XCTAssertTrue(
            app.descendants(matching: .any)["feed.fab.post"].waitForExistence(timeout: 5),
            "holding the button did not fan out its choices"
        )
        // The choices spring into place; a tap mid-flight lands where the
        // choice was a moment ago.
        sleep(1)
    }

    /// No GIF provider and nothing in the library — production today
    /// (contract v27 §5): neither the floating button nor the composer offers
    /// a GIF picker that could only open on nothing.
    func testWithNoGifToOfferTheGifWaysInAreHidden() throws {
        let app = launchApp(gifScenario: "empty")
        signIn(app)
        // The tabs ask the library once they open; give the answer a moment.
        sleep(2)

        holdFloatingButton(app)
        XCTAssertFalse(app.descendants(matching: .any)["feed.fab.gif"].exists, "the GIF choice is offered with no GIF to pick")
        add(screenshot(app, named: "FAB — no GIF choice"))

        app.descendants(matching: .any)["feed.fab.post"].firstMatch.tap()
        XCTAssertTrue(app.textViews.firstMatch.waitForExistence(timeout: 10), "the composer sheet never appeared")
        XCTAssertTrue(app.descendants(matching: .any)["composer.addImage"].waitForExistence(timeout: 5), "the composer lost its photo button")
        XCTAssertFalse(app.descendants(matching: .any)["composer.addGif"].exists, "the composer offers a GIF button with no GIF to pick")
        add(screenshot(app, named: "Composer — no GIF button"))
    }

    /// With a library, both ways in are there, and the floating button's GIF
    /// choice opens the composer onto the picker.
    func testWithGifsToOfferTheFloatingButtonOpensThePicker() throws {
        let app = launchApp()
        signIn(app)
        sleep(2)

        holdFloatingButton(app)
        let gif = app.descendants(matching: .any)["feed.fab.gif"].firstMatch
        XCTAssertTrue(gif.exists, "the GIF choice is missing although the library has GIFs")
        // The middle of the row, which is the gap between the word and its
        // circle: the whole row must answer.
        gif.tap()

        XCTAssertTrue(
            app.descendants(matching: .any)["composer.gif.search"].waitForExistence(timeout: 10),
            "the GIF choice did not open the picker"
        )
        add(screenshot(app, named: "Composer — GIF picker from the floating button"))
        app.descendants(matching: .any)["composer.gif.cancel"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["composer.addGif"].waitForExistence(timeout: 5), "the composer has no GIF button")
    }

    /// Explore shows real trending tags instead of the Phase-3 placeholder.
    func testExploreShowsTrendingAndOpensATappedTagsPage() throws {
        let app = launchApp()
        signIn(app)

        app.buttons["Explore"].tap()

        let tag = app.buttons.containing(NSPredicate(format: "label CONTAINS '#riyadh'")).firstMatch
        XCTAssertTrue(tag.waitForExistence(timeout: 15), "Explore is not showing trending tags")
        add(screenshot(app, named: "Explore — trending"))

        tag.tap()

        // A tag is a place: tapping one opens its page, with the order chips
        // under the title, rather than running a search.
        XCTAssertTrue(
            app.descendants(matching: .any)["hashtag.sort.newest"].waitForExistence(timeout: 10),
            "tapping a trending tag did not open the tag's page"
        )
        XCTAssertTrue(app.descendants(matching: .any)["hashtag.sort.top"].exists, "the page offers no other order")
        // An ordinary pushed screen keeps its system back arrow — the fix for
        // the live room's doubled arrow only ever hides, never un-hides.
        let leading = app.navigationBars.firstMatch.buttons.allElementsBoundByIndex.filter { $0.frame.minX < 120 }
        XCTAssertEqual(leading.count, 1, "a pushed page lost its back arrow")
        add(screenshot(app, named: "Explore — a tag's page"))
    }

    private func screenshot(_ app: XCUIApplication, named name: String) -> XCTAttachment {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        return attachment
    }
}
