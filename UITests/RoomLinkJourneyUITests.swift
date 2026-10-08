import XCTest

/// A room link tapped while signed in (round-2 security finding CA-1),
/// walked through the real UI in English and in Arabic.
///
/// Joining a room puts the person in the host's listener list by verified
/// name, so a link — from Messages, a web page, a push — opens on the room's
/// card and nothing joins until Join is tapped. "Not now" leaves without the
/// host ever knowing. (The signed-out half, Listen on a guest's card, is in
/// ``GuestListeningJourneyUITests``.)
///
/// Entirely against the mocks — rooms and a mocked media engine — so no
/// room is joined anywhere real. `-openLinkAfterSignIn` is the debug-only
/// way to tap a link once the session is on the feed.
final class RoomLinkJourneyUITests: XCTestCase {

    private static let link = "https://sila.gmai.sa/rooms/00000000-0000-4000-8000-000000000702"

    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(language: String = "en") -> XCUIApplication {
        let app = XCUIApplication()
        let locale = language == "ar"
            ? ["-AppleLanguages", "(ar)", "-AppleLocale", "ar_SA"]
            : ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchArguments = locale + [
            "-freshStorage",
            "-mockAuth", "-mockScenario", "verified",
            "-mockFeed", "-mockFeedScenario", "populated",
            "-mockRooms", "-mockRoomsScenario", "populated",
            "-mockVoiceEngine",
            "-noBiometrics",
            "-noRealtime",
            "-noOnboarding",
            "-apiOrigin", "http://127.0.0.1:9",
            "-openLinkAfterSignIn", Self.link,
        ]
        app.launch()
        return app
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func showing(_ app: XCUIApplication, _ text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    @discardableResult
    private func tap(_ app: XCUIApplication, _ identifier: String, timeout: TimeInterval = 15) -> Bool {
        let target = element(app, identifier)
        guard target.waitForExistence(timeout: timeout) else { return false }
        if target.isHittable {
            target.tap()
        } else {
            target.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        return true
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func signIn(_ app: XCUIApplication) {
        XCTAssertTrue(tap(app, "welcome.signIn", timeout: 25), "never reached the welcome screen")
        let email = app.textFields.firstMatch
        XCTAssertTrue(email.waitForExistence(timeout: 10), "no sign-in form")
        email.tap()
        email.typeText("aziz@example.com")
        let password = app.secureTextFields.firstMatch
        password.tap()
        password.typeText("Passw0rd!234")
        XCTAssertTrue(tap(app, "signIn.submit"))
    }

    /// The card, then Join: in the room only after the tap.
    func testARoomLinkShowsTheCardAndJoinsOnlyOnJoin() throws {
        let app = launch()
        signIn(app)

        XCTAssertTrue(element(app, "roomLink.card").waitForExistence(timeout: 25), "a room link did not show the room's card")
        XCTAssertTrue(showing(app, "قهوة الصباح").exists, "the link opened a different room")
        XCTAssertTrue(showing(app, "You haven't joined").exists, "the card does not say nothing has happened yet")
        XCTAssertFalse(showing(app, "You're listening").waitForExistence(timeout: 3),
                       "a room link joined the room without a tap")
        shot(app, "room-link-card-en")

        XCTAssertTrue(tap(app, "roomLink.enter"), "the card had no Join button")
        XCTAssertTrue(showing(app, "You're listening").waitForExistence(timeout: 25), "Join on the card did not join")
        XCTAssertFalse(element(app, "roomLink.card").exists)
        shot(app, "room-link-joined-en")
    }

    /// "Not now": back to the rooms, never in the room.
    func testNotNowLeavesWithoutJoining() throws {
        let app = launch()
        signIn(app)
        XCTAssertTrue(element(app, "roomLink.card").waitForExistence(timeout: 25))
        XCTAssertTrue(tap(app, "roomLink.cancel"), "the card had no Not now")
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element(app, "roomLink.card"))
        wait(for: [gone], timeout: 10)
        XCTAssertFalse(showing(app, "You're listening").exists, "Not now joined the room")
    }

    /// The card in Arabic: Join is «انضم», and nothing joins before it.
    func testTheCardReadsInArabic() throws {
        let app = launch(language: "ar")
        signIn(app)
        let join = element(app, "roomLink.enter")
        XCTAssertTrue(join.waitForExistence(timeout: 25), "a room link did not show the room's card in Arabic")
        XCTAssertTrue(join.label.contains("انضم"), "Join is not in Arabic: \(join.label)")
        XCTAssertTrue(showing(app, "لم تنضم بعد").exists)
        shot(app, "room-link-card-ar")
    }
}
