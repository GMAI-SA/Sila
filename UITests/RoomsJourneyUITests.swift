import XCTest

/// The Rooms tab, driven through the real UI.
///
/// The view models pass in isolation whether or not the tab is wired to
/// anything, so this is the only test that would notice the shell missing the
/// tab, a mic button drawn for a listener, or a room card that says nothing
/// about who may speak in it.
///
/// Runs entirely against the mocks — including a mocked media engine — so no
/// real room is opened, joined or left.
final class RoomsJourneyUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    private func launchApp(scenario: String = "populated") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-mockAuth", "-mockScenario", "verified",
            "-mockFeed", "-mockFeedScenario", "populated",
            "-mockRooms", "-mockRoomsScenario", scenario,
            "-mockVoiceEngine",
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

    private func openRooms(_ app: XCUIApplication) {
        let tab = app.buttons["Rooms"]
        XCTAssertTrue(tab.waitForExistence(timeout: 10), "no Rooms tab")
        tab.tap()
    }

    private func screenshot(_ app: XCUIApplication, named name: String) -> XCTAttachment {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        return attachment
    }

    /// **The tab is real, and it says the thing it has to say.** Live rooms, a
    /// scheduled section, and the promise that none of it is recorded — on the
    /// screen where somebody decides whether to walk in.
    func testTheRoomsTabListsLiveRoomsAndPromisesNoRecording() throws {
        let app = launchApp()
        signIn(app)
        openRooms(app)

        XCTAssertTrue(
            app.staticTexts["LIVE NOW"].waitForExistence(timeout: 15),
            "the Rooms tab has no live section"
        )
        XCTAssertTrue(app.staticTexts["SCHEDULED"].exists, "no scheduled section")
        XCTAssertTrue(
            app.staticTexts.containing(
                NSPredicate(format: "label CONTAINS[c] 'never recorded'")
            ).element.exists,
            "the tab never says rooms are not recorded"
        )
        add(screenshot(app, named: "rooms-list"))
    }

    /// **A room the viewer cannot speak in is listed anyway**, with the
    /// server's own refusal under it. Filtering it out would turn a speaking
    /// rule into a visibility rule.
    func testARoomYouCannotSpeakInIsStillListedWithItsReason() throws {
        let app = launchApp(scenario: "listenerOnly")
        signIn(app)
        openRooms(app)

        XCTAssertTrue(
            app.staticTexts["LIVE NOW"].waitForExistence(timeout: 15),
            "no live section"
        )
        let refusal = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS[c] 'you can still listen'")
        ).element
        XCTAssertTrue(refusal.exists, "an unspeakable room gave no reason")
        add(screenshot(app, named: "rooms-listener-only"))
    }

    /// **A listener gets no microphone button — not a disabled one.** They get
    /// the listening state and the reason instead.
    func testAListenerSeesNoMicrophoneButtonInsideARoom() throws {
        let app = launchApp(scenario: "listenerOnly")
        signIn(app)
        openRooms(app)

        XCTAssertTrue(app.staticTexts["LIVE NOW"].waitForExistence(timeout: 15))
        // The first live card. Tapping it joins and pushes the room screen.
        app.staticTexts["LIVE"].firstMatch.tap()

        XCTAssertTrue(
            app.staticTexts["You're listening"].waitForExistence(timeout: 15),
            "the room screen never said the viewer is listening"
        )
        XCTAssertFalse(app.buttons["Unmute"].exists, "a listener was offered a microphone")
        XCTAssertFalse(app.buttons["Mute"].exists, "a listener was offered a microphone")
        XCTAssertTrue(app.buttons["Leave room"].exists, "no way out of the room")
        add(screenshot(app, named: "room-listening"))

        app.buttons["Leave room"].tap()
        XCTAssertTrue(
            app.staticTexts["LIVE NOW"].waitForExistence(timeout: 15),
            "leaving did not return to the list"
        )
    }

    /// **A host gets the mic, the end control, and controls over other people.**
    func testAHostGetsTheMicrophoneAndTheHostControls() throws {
        let app = launchApp(scenario: "hosting")
        signIn(app)
        openRooms(app)

        XCTAssertTrue(app.staticTexts["LIVE NOW"].waitForExistence(timeout: 15))
        app.staticTexts["LIVE"].firstMatch.tap()

        XCTAssertTrue(
            app.buttons["Unmute"].waitForExistence(timeout: 15),
            "the host was not offered a microphone"
        )
        XCTAssertTrue(app.buttons["End"].exists, "the host cannot end their own room")
        XCTAssertFalse(
            app.staticTexts["You're listening"].exists,
            "the host was told they are only listening"
        )
        add(screenshot(app, named: "room-hosting"))
    }

    /// **The create sheet says the asymmetry out loud** and reuses the
    /// composer's audience picker.
    func testTheCreateSheetExplainsThatEveryoneCanListen() throws {
        let app = launchApp()
        signIn(app)
        openRooms(app)

        let create = app.buttons["Start a room"]
        XCTAssertTrue(create.waitForExistence(timeout: 15), "no way to start a room")
        create.tap()

        XCTAssertTrue(
            app.staticTexts["WHO CAN SPEAK"].waitForExistence(timeout: 10),
            "the create sheet has no audience picker"
        )
        XCTAssertTrue(
            app.staticTexts.containing(
                NSPredicate(format: "label CONTAINS[c] 'Everyone on Sila can listen'")
            ).element.exists,
            "the create sheet never said everyone can listen"
        )
        XCTAssertTrue(app.staticTexts["International"].exists, "no International audience")
        add(screenshot(app, named: "rooms-create"))
    }
}
