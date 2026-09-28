import XCTest

/// Listening to a room without an account (contract v31, owner request
/// 2026-09-28), walked through the real UI in English and in Arabic.
///
/// Somebody who chose "Look around first" finds the Rooms tab open to them,
/// taps a room and is listening at once; speaking, a hand, a reaction or the
/// chat meet "Join Sila to take part", whose sign-in comes back to the room;
/// every refusal the server can answer is said in its own words; a shared
/// room link opens for somebody signed out. And members see the guests on a
/// room, and its host can turn them off.
///
/// Entirely against the mocks — rooms, guest seats and a mocked media engine
/// — so no room is opened, joined or listened to. The one service with no
/// mock, the public feed a guest's Home tab reads, is pointed at a port
/// nothing answers on rather than at production.
final class GuestListeningJourneyUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    // MARK: - Launch

    private func launch(
        guestRooms scenario: String = "populated",
        rooms: String = "populated",
        language: String = "en",
        extra: [String] = []
    ) -> XCUIApplication {
        let app = XCUIApplication()
        let locale = language == "ar"
            ? ["-AppleLanguages", "(ar)", "-AppleLocale", "ar_SA"]
            : ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchArguments = locale + [
            "-freshStorage",
            "-mockAuth", "-mockScenario", "verified",
            "-mockFeed", "-mockFeedScenario", "populated",
            "-mockRooms", "-mockRoomsScenario", rooms,
            "-mockGuestRoomsScenario", scenario,
            "-mockVoiceEngine",
            "-noBiometrics",
            "-noRealtime",
            // A guest's Home tab reads the public feed, which nothing mocks.
            "-apiOrigin", "http://127.0.0.1:9",
        ] + extra
        app.launch()
        return app
    }

    // MARK: - Helpers

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
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

    /// Anything on screen whose label contains `text`.
    private func showing(_ app: XCUIApplication, _ text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Welcome → "Look around first" → the Rooms tab.
    private func browseRooms(_ app: XCUIApplication) {
        XCTAssertTrue(tap(app, "welcome.browse", timeout: 25), "never reached the welcome screen")
        XCTAssertTrue(tap(app, "tab.rooms"), "a guest has no Rooms tab")
        XCTAssertTrue(element(app, "guest.room.card").waitForExistence(timeout: 15), "a guest's Rooms tab listed nothing")
    }

    private func isArabic(_ value: String) -> Bool {
        value.unicodeScalars.contains { (0x0600...0x06FF).contains($0.value) }
    }

    // MARK: - Listening

    /// **One tap listens**, and everything else is the invitation.
    func testAGuestListensToALiveRoomAndIsInvitedToTakePart() throws {
        let app = launch()
        browseRooms(app)
        XCTAssertTrue(showing(app, "LIVE NOW").exists)
        XCTAssertTrue(showing(app, "12 guests listening").exists, "the card does not count the guests listening")
        XCTAssertTrue(showing(app, "without an account").exists, "the tab never says a guest may listen")
        shot(app, "guest-rooms-en")

        XCTAssertTrue(tap(app, "guest.room.card"))
        XCTAssertTrue(element(app, "guest.room.listening").waitForExistence(timeout: 15), "the room never started listening")
        XCTAssertTrue(showing(app, "You're listening as a guest").exists)
        XCTAssertTrue(showing(app, "hasn't asked for your microphone").exists)
        XCTAssertTrue(showing(app, "12 guests listening").exists, "the room's header does not count the guests")
        XCTAssertFalse(app.buttons["Unmute"].exists, "a guest was offered a microphone")
        XCTAssertFalse(app.buttons["Mute"].exists, "a guest was offered a microphone")
        shot(app, "guest-room-listening-en")

        // A hand is an invitation, not a request.
        XCTAssertTrue(tap(app, "guest.room.hand"))
        XCTAssertTrue(showing(app, "Join Sila to take part").waitForExistence(timeout: 10), "a hand did not invite")
        shot(app, "guest-room-join-en")
        XCTAssertTrue(tap(app, "guest.join.later"))

        // So is a reaction.
        XCTAssertTrue(tap(app, "guest.room.reaction.👏"))
        XCTAssertTrue(showing(app, "Join Sila to take part").waitForExistence(timeout: 10), "a reaction did not invite")
        XCTAssertTrue(tap(app, "guest.join.later"))

        // The chat is there to read; writing in it is the invitation.
        XCTAssertTrue(tap(app, "guest.room.chat.open"))
        XCTAssertTrue(showing(app, "Welcome, everyone").waitForExistence(timeout: 10), "a guest cannot read the chat")
        XCTAssertTrue(showing(app, "what's said while you're here").exists)
        XCTAssertFalse(app.textFields.count > 0 && app.textFields.firstMatch.isHittable, "a guest was offered a chat box")
        shot(app, "guest-room-chat-en")
        XCTAssertTrue(tap(app, "guest.room.chat.join"))
        XCTAssertTrue(showing(app, "Join Sila to take part").waitForExistence(timeout: 10))
        XCTAssertTrue(tap(app, "guest.join.later"))

        // Leaving goes back to the list.
        XCTAssertTrue(tap(app, "guest.room.leave"))
        XCTAssertTrue(element(app, "guest.room.card").waitForExistence(timeout: 15), "leaving did not return to the rooms")
    }

    /// The same in Arabic: the words arrive, and nothing leaves the screen.
    func testAGuestListensInArabic() throws {
        let app = launch(language: "ar")
        browseRooms(app)
        XCTAssertTrue(showing(app, "12 من الزوار يستمعون").exists, "the guests count is not Arabic")
        shot(app, "guest-rooms-ar")

        XCTAssertTrue(tap(app, "guest.room.card"))
        XCTAssertTrue(element(app, "guest.room.listening").waitForExistence(timeout: 15))
        XCTAssertTrue(showing(app, "أنت تستمع كزائر").exists)
        shot(app, "guest-room-listening-ar")

        XCTAssertTrue(tap(app, "guest.room.hand"))
        XCTAssertTrue(showing(app, "انضم إلى صلة لتشارك").waitForExistence(timeout: 10))
        shot(app, "guest-room-join-ar")
    }

    // MARK: - Every refusal, in words

    private struct Refusal {
        let scenario: String
        let code: String
        let english: String
        let arabic: String
        /// A member could do what the guest cannot: the two doors are offered.
        let offersJoin: Bool
    }

    private let refusals: [Refusal] = [
        Refusal(scenario: "room_closed", code: "room_closed", english: "This room is for members only",
                arabic: "هذه الغرفة للأعضاء فقط", offersJoin: true),
        Refusal(scenario: "guests_not_allowed", code: "guests_not_allowed", english: "Guests can't listen to this room",
                arabic: "لا يمكن للزوار الاستماع إلى هذه الغرفة", offersJoin: true),
        Refusal(scenario: "room_ended", code: "room_ended", english: "This room has ended",
                arabic: "انتهت هذه الغرفة", offersJoin: true),
        Refusal(scenario: "guests_full", code: "guests_full", english: "This room has no guest seats left",
                arabic: "لم يبقَ مقعد للزوار في هذه الغرفة", offersJoin: true),
        Refusal(scenario: "rate_limited", code: "rate_limited", english: "Too many tries from your connection",
                arabic: "محاولات كثيرة من اتصالك", offersJoin: false),
        Refusal(scenario: "not_found", code: "not_found", english: "This room isn't available",
                arabic: "هذه الغرفة غير متاحة", offersJoin: false),
        Refusal(scenario: "connect_failed", code: "connect_failed", english: "Couldn't connect to the room",
                arabic: "تعذّر الاتصال بالغرفة", offersJoin: false),
    ]

    private func walkRefusals(language: String) {
        for refusal in refusals {
            let app = launch(guestRooms: refusal.scenario, language: language)
            browseRooms(app)
            XCTAssertTrue(tap(app, "guest.room.card"))
            XCTAssertTrue(
                element(app, "guest.room.refusal.\(refusal.code)").waitForExistence(timeout: 15),
                "\(refusal.code) was not refused as itself in \(language)"
            )
            let words = language == "ar" ? refusal.arabic : refusal.english
            XCTAssertTrue(showing(app, words).exists, "\(refusal.code) did not say '\(words)'")
            XCTAssertEqual(element(app, "guest.room.create").exists, refusal.offersJoin, "\(refusal.code): join offered wrongly")
            XCTAssertTrue(element(app, "guest.room.backToRooms").exists, "\(refusal.code) is a dead end")
            if refusal.code == "rate_limited" {
                // The server's wait, counting down on a button that waits too.
                let retry = element(app, "guest.room.retry")
                XCTAssertTrue(retry.exists)
                XCTAssertFalse(retry.isEnabled, "a guest could ask again before the server's wait")
                XCTAssertTrue(showing(app, language == "ar" ? "أعد المحاولة بعد" : "Try again in").exists)
            }
            shot(app, "guest-room-\(refusal.code)-\(language)")
            app.terminate()
        }
    }

    func testEveryRefusalIsSaidInItsOwnWordsInEnglish() throws {
        walkRefusals(language: "en")
    }

    func testEveryRefusalIsSaidInItsOwnWordsInArabic() throws {
        walkRefusals(language: "ar")
    }

    /// A room that has not started says so, and when it does.
    func testARoomThatHasNotStartedSaysWhenItStarts() throws {
        for language in ["en", "ar"] {
            let app = launch(language: language)
            browseRooms(app)
            // A host's title is content, the same in either language.
            let scheduled = app.descendants(matching: .any).matching(identifier: "guest.room.card")
                .matching(NSPredicate(format: "label CONTAINS %@", "Weekly science reading group")).firstMatch
            XCTAssertTrue(scheduled.waitForExistence(timeout: 10), "no scheduled room on a guest's tab")
            if !scheduled.isHittable { app.swipeUp() }
            scheduled.tap()
            XCTAssertTrue(element(app, "guest.room.refusal.room_not_live").waitForExistence(timeout: 15))
            XCTAssertTrue(showing(app, language == "ar" ? "لم تبدأ هذه الغرفة بعد" : "This room hasn't started yet").exists)
            XCTAssertTrue(element(app, "guest.room.starts").waitForExistence(timeout: 10), "no start time in \(language)")
            shot(app, "guest-room-room_not_live-\(language)")
            app.terminate()
        }
    }

    // MARK: - Back to the room

    /// **Signing in from a room comes back to it**, as a member now.
    func testSigningInFromTheRoomComesBackToIt() throws {
        let app = launch()
        browseRooms(app)
        XCTAssertTrue(tap(app, "guest.room.card"))
        XCTAssertTrue(element(app, "guest.room.listening").waitForExistence(timeout: 15))
        XCTAssertTrue(tap(app, "guest.room.hand"))
        XCTAssertTrue(tap(app, "guest.join.signIn"), "the invitation had no way to sign in")

        let email = app.textFields.firstMatch
        XCTAssertTrue(email.waitForExistence(timeout: 10), "no sign-in form")
        email.tap()
        email.typeText("aziz@example.com")
        let password = app.secureTextFields.firstMatch
        password.tap()
        password.typeText("Passw0rd!234")
        XCTAssertTrue(tap(app, "signIn.submit"))

        // The member's room, joined: the member's listening card, and the
        // member's hand — no guest invitation in sight.
        XCTAssertTrue(showing(app, "You're listening").waitForExistence(timeout: 25), "signing in did not come back to the room")
        XCTAssertFalse(element(app, "guest.room.listening").exists)
        XCTAssertTrue(showing(app, "What verification actually changes").exists, "a different room opened")
        shot(app, "guest-signed-in-back-in-room")
    }

    // MARK: - Links

    /// A shared room link opens for somebody signed out: listening, at once.
    func testASharedRoomLinkOpensForSomebodySignedOut() throws {
        let link = "https://sila.gmai.sa/rooms/00000000-0000-4000-8000-000000000702"
        for language in ["en", "ar"] {
            let app = launch(language: language, extra: ["-openLink", link])
            XCTAssertTrue(element(app, "guest.room.listening").waitForExistence(timeout: 25),
                          "a shared room link did not open for somebody signed out (\(language))")
            XCTAssertTrue(showing(app, "قهوة الصباح").exists, "the link opened a different room")
            shot(app, "guest-room-link-\(language)")
            XCTAssertTrue(tap(app, "guest.room.leave"))
            XCTAssertTrue(element(app, "guest.room.card").waitForExistence(timeout: 15),
                          "leaving a linked room did not land on the guest's rooms")
            app.terminate()
        }
    }

    // MARK: - Members and hosts

    private func signInAsMember(_ app: XCUIApplication) {
        XCTAssertTrue(tap(app, "welcome.signIn", timeout: 25), "never reached the welcome screen")
        let email = app.textFields.firstMatch
        XCTAssertTrue(email.waitForExistence(timeout: 10))
        email.tap()
        email.typeText("aziz@example.com")
        let password = app.secureTextFields.firstMatch
        password.tap()
        password.typeText("Passw0rd!234")
        XCTAssertTrue(tap(app, "signIn.submit"))
        XCTAssertTrue(tap(app, "tab.rooms", timeout: 25), "a member has no Rooms tab")
    }

    /// Members see the guests on a room; its host turns them off in the
    /// room's settings, and the line goes.
    func testMembersSeeTheGuestsAndTheHostCanTurnThemOff() throws {
        let app = launch(rooms: "hosting")
        signInAsMember(app)
        XCTAssertTrue(showing(app, "Guests can listen · 12 guests listening").waitForExistence(timeout: 15),
                      "a member's card does not say guests can listen")
        shot(app, "member-rooms-guests-en")

        app.staticTexts["LIVE"].firstMatch.tap()
        XCTAssertTrue(element(app, "room.guests").waitForExistence(timeout: 15), "the room's header does not show the guests")
        XCTAssertTrue(tap(app, "room.menu"), "the host has no room menu")
        // The menu's item, not the menu button that shares its name.
        let settings = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@", "Room settings", "room.menu")).firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5), "the host's menu has no settings")
        settings.tap()

        let toggle = app.switches["room.settings.guests"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), "room settings have no guests switch")
        XCTAssertEqual(toggle.value as? String, "1")
        shot(app, "room-settings-guests-en")
        // The switch itself sits at the trailing end of its row.
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        let off = expectation(for: NSPredicate(format: "value == '0'"), evaluatedWith: toggle)
        wait(for: [off], timeout: 10)
        XCTAssertFalse(element(app, "room.settings.error").exists, "turning guests off was refused")
        app.buttons["Done"].firstMatch.tap()
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element(app, "room.guests"))
        wait(for: [gone], timeout: 10)
        shot(app, "room-guests-off-en")
    }

    /// The create sheet offers the switch for an open room, and not for a
    /// closed one.
    func testTheCreateSheetOffersGuestsForAnOpenRoom() throws {
        let app = launch()
        signInAsMember(app)
        XCTAssertTrue(tap(app, "feed.fab"), "no way to start a room")
        let toggle = app.switches["rooms.create.allowGuests"].firstMatch
        if !toggle.waitForExistence(timeout: 5) { app.swipeUp() }
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), "the create sheet has no guests switch")
        XCTAssertEqual(toggle.value as? String, "1", "guests are not on by default")
        shot(app, "rooms-create-guests-en")
    }
}
