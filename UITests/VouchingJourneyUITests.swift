import XCTest

/// Contract v24 through the real UI, on the person's side: a vouch link
/// opened before there is a session waits through sign-in, comes back as the
/// claim, asks its two warnings first (§12), names the field that did not
/// match — never what the voucher wrote (§11) — and, once the details agree,
/// leaves the person at the wall waiting for the voucher to confirm.
///
/// Runs against `AuthServiceMock` and `VouchingServiceMock` (its link
/// `mock-khalid-2026-link`, written by @noura for Khalid Al-Harbi, Saudi,
/// born 12 April 1995), so it needs no network and no real link.
final class VouchingJourneyUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    private static let link = "https://sila.gmai.sa/vouch/mock-khalid-2026-link"

    // MARK: - Copy, read from the catalogue the app ships

    private static let catalogue: [String: [String: String]] = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sila/Resources/Localizable.xcstrings")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let strings = json["strings"] as? [String: Any] else { return [:] }
        var out: [String: [String: String]] = [:]
        for (key, raw) in strings {
            guard let entry = raw as? [String: Any],
                  let locs = entry["localizations"] as? [String: Any] else { continue }
            var values: [String: String] = [:]
            for (code, loc) in locs {
                if let loc = loc as? [String: Any],
                   let unit = loc["stringUnit"] as? [String: Any],
                   let value = unit["value"] as? String {
                    values[code] = value
                }
            }
            out[key] = values
        }
        return out
    }()

    /// A catalogue sentence with its one `%@` filled in.
    private func L(_ key: String, _ argument: String? = nil, _ lang: String = "en") -> String {
        let value = Self.catalogue[key]?[lang] ?? key
        guard let argument else { return value }
        return value.replacingOccurrences(of: "%@", with: argument)
    }

    // MARK: - Launch

    private func launch(_ arguments: [String], lang: String = "en") -> XCUIApplication {
        let app = XCUIApplication()
        let language: [String] = lang == "ar"
            ? ["-AppleLanguages", "(ar)", "-AppleLocale", "ar_SA"]
            : ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchArguments = language + ["-freshStorage", "-mockAuth", "-noBiometrics"] + arguments
        app.launch()
        return app
    }

    /// The sign-in form, reached from the link's own "Sign in".
    private func signInFromTheLanding(_ app: XCUIApplication) {
        let signIn = byId(app, "vouching.claim.signIn")
        XCTAssertTrue(signIn.waitForExistence(timeout: 20), "the landing offers no way to sign in")
        signIn.tap()
        let email = app.textFields.firstMatch
        XCTAssertTrue(email.waitForExistence(timeout: 10), "no email field on the sign-in screen")
        email.tap()
        email.typeText("khalid@example.com")
        let password = app.secureTextFields.firstMatch
        XCTAssertTrue(password.waitForExistence(timeout: 5), "no password field")
        password.tap()
        password.typeText("Passw0rd!234")
        byId(app, "signIn.submit").tap()
    }

    private func byId(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func byLabel(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    private func byLabelContaining(_ app: XCUIApplication, _ text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    private func screenshot(_ app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Waits for `element` to leave the screen.
    private func gone(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    /// Scrolls the claim form until `element` sits well clear of the bottom
    /// edge, where a tap is taken by the home indicator rather than the row.
    /// Stops once the form cannot move any further, and lets it settle: a tap
    /// on a scroll view that is still bouncing only stops the bounce.
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        let window = app.windows.firstMatch
        var tries = 0
        while (!element.isHittable || element.frame.maxY > window.frame.maxY - 80) && tries < 8 {
            let before = element.frame
            let from = window.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.7))
            from.press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.45)))
            usleep(800_000)
            if element.frame == before { break }
            tries += 1
        }
    }

    // MARK: - The claim

    func testALinkOpenedBeforeSignInBecomesAClaimThatNamesTheFieldThatDidNotMatch() {
        let app = launch(["-mockScenario", "unstarted", "-openLink", Self.link])

        // Signed out: the landing, over the welcome screen.
        let title = byId(app, "vouching.claim.title")
        XCTAssertTrue(title.waitForExistence(timeout: 20), "the link's landing never appeared")
        XCTAssertEqual(title.label, L("vouch.claim.title", "noura"))
        XCTAssertTrue(byLabel(app, L("vouch.claim.guest")).exists, "a signed-out person is asked to join first")
        screenshot(app, named: "Vouch link, signed out")

        // The link waits through sign-in and comes back as the claim.
        signInFromTheLanding(app)
        let understand = byId(app, "vouching.warning.person.continue")
        XCTAssertTrue(understand.waitForExistence(timeout: 20), "the claim did not come back after signing in")

        // The two warnings first, both on screen, before any field (§12).
        XCTAssertTrue(byLabel(app, L("vouch.warning.person.title")).exists)
        XCTAssertTrue(byLabelContaining(app, String(L("vouch.warning.person.one", "noura").prefix(40))).exists)
        XCTAssertTrue(byLabelContaining(app, L("vouch.warning.person.two", "noura")).exists)
        XCTAssertFalse(app.textFields[L("vouch.form.fullName")].exists, "no details form before the warnings")
        screenshot(app, named: "Before you accept")
        understand.tap()

        // The person's own details: a name one letter off.
        let name = app.textFields[L("vouch.form.fullName")]
        XCTAssertTrue(name.waitForExistence(timeout: 10), "no name field")
        name.tap()
        name.typeText("Khaled Al-Harbi\n")
        XCTAssertTrue(gone(app.keyboards.firstMatch, timeout: 5))

        byId(app, "vouching.form.nationality").tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10), "no nationality list")
        search.tap()
        search.typeText("Saudi")
        let saudi = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Saudi")).firstMatch
        XCTAssertTrue(saudi.waitForExistence(timeout: 10))
        saudi.tap()

        let birth = byId(app, "vouching.form.dateOfBirth")
        XCTAssertTrue(birth.waitForExistence(timeout: 10))
        reveal(birth, in: app)
        birth.tap()
        let wheels = app.pickerWheels
        XCTAssertTrue(wheels.firstMatch.waitForExistence(timeout: 10), "no date wheel")
        wheels.element(boundBy: 0).adjust(toPickerWheelValue: "April")
        wheels.element(boundBy: 1).adjust(toPickerWheelValue: "12")
        wheels.element(boundBy: 2).adjust(toPickerWheelValue: "1995")
        // Closed again, so no swipe below can turn it.
        birth.tap()
        XCTAssertTrue(gone(wheels.firstMatch, timeout: 5))
        XCTAssertTrue(birth.label.contains("1995"), "the chosen day is not on the row: \(birth.label)")

        for promise in ["adult", "realName", "singleAccount", "terms"] {
            let box = byId(app, "vouching.claim.attest.\(promise)")
            reveal(box, in: app)
            box.tap()
            XCTAssertTrue(box.isSelected, "the \(promise) box did not tick")
        }
        let accept = byId(app, "vouching.claim.accept")
        reveal(accept, in: app)
        accept.tap()

        // Which field, never what @noura wrote; and how many tries are left.
        let mismatch = byId(app, "vouching.claim.mismatch")
        XCTAssertTrue(mismatch.waitForExistence(timeout: 10), "a mismatch was not shown")
        let said = mismatch.label
        XCTAssertTrue(said.contains(L("vouch.claim.mismatch").replacingOccurrences(of: "%1$@", with: "noura")
            .replacingOccurrences(of: "%2$@", with: L("vouch.field.fullName"))), "the name is not named: \(said)")
        XCTAssertFalse(said.contains(L("vouch.field.dateOfBirth")), "a field that matched was named")
        XCTAssertFalse(said.contains("Khalid"), "what the voucher wrote reached the person")
        XCTAssertTrue(said.contains("2 tries left"), "the tries left are not said: \(said)")
        screenshot(app, named: "A name that did not match")

        // Corrected, it is accepted, and @noura is asked to confirm.
        reveal(name, in: app)
        name.tap()
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 20) + "Khalid Al-Harbi\n")
        // The keyboard's exit moves the form; the tap waits for it.
        XCTAssertTrue(gone(app.keyboards.firstMatch, timeout: 5))
        reveal(accept, in: app)
        accept.tap()

        let done = byId(app, "vouching.claim.done")
        XCTAssertTrue(done.waitForExistence(timeout: 10), "the claim was not accepted")
        XCTAssertTrue(byLabel(app, L("vouch.wall.pending.title", "noura")).exists)
        screenshot(app, named: "Claimed — waiting for @noura")
        done.tap()

        // The wall says who it is waiting for.
        XCTAssertTrue(byLabel(app, L("vouch.wall.pending.title", "noura")).waitForExistence(timeout: 10),
                      "the wall does not say it is waiting for @noura")
        XCTAssertTrue(byId(app, "vouching.wall.withdraw").exists, "the claim cannot be taken back from the wall")
        screenshot(app, named: "The wall while @noura decides")
    }

    func testCancellingTheWarningsLetsTheLinkGo() {
        let app = launch(["-mockScenario", "unstarted", "-openLink", Self.link])
        signInFromTheLanding(app)
        let cancel = byId(app, "vouching.warning.person.cancel")
        XCTAssertTrue(cancel.waitForExistence(timeout: 20), "the claim did not come back after signing in")
        cancel.tap()
        XCTAssertTrue(gone(byId(app, "vouching.claim.title"), timeout: 10), "the landing stayed up")
        XCTAssertTrue(byLabel(app, L("auth.wall.unstarted.action")).waitForExistence(timeout: 10),
                      "cancelling did not leave the person at the wall")
    }

    // MARK: - The limited tier

    func testAVouchedAccountSeesItsThirtyDaysAndAMessagesTabThatExplainsItself() {
        let app = launch(["-mockScenario", "vouched"])
        let start = byId(app, "welcome.signIn")
        XCTAssertTrue(start.waitForExistence(timeout: 20), "never reached the welcome screen")
        start.tap()
        let email = app.textFields.firstMatch
        XCTAssertTrue(email.waitForExistence(timeout: 10))
        email.tap()
        email.typeText("khalid@example.com")
        let password = app.secureTextFields.firstMatch
        XCTAssertTrue(password.waitForExistence(timeout: 5))
        password.tap()
        password.typeText("Passw0rd!234")
        byId(app, "signIn.submit").tap()

        // A member, not the wall: the feed, with the 30 days above it.
        let banner = byId(app, "vouching.banner")
        XCTAssertTrue(banner.waitForExistence(timeout: 20), "a vouched account did not reach the feed with its countdown")
        XCTAssertTrue(banner.label.contains(L("vouch.banner.title", "noura")), "the banner does not say whose word: \(banner.label)")
        screenshot(app, named: "Home, vouched")

        // Messages explain themselves instead of failing.
        app.buttons["Messages"].tap()
        XCTAssertTrue(byLabelContaining(app, L("vouch.limited.messages.title")).waitForExistence(timeout: 10),
                      "the Messages tab does not say why it is closed")
        XCTAssertTrue(byId(app, "vouching.notice.verify").exists, "no way to verify from the closed tab")
        screenshot(app, named: "Messages, vouched")

        // The countdown opens the person's own vouch.
        app.buttons["Home"].tap()
        XCTAssertTrue(banner.waitForExistence(timeout: 10))
        banner.tap()
        let days = byId(app, "vouching.mine.daysLeft")
        XCTAssertTrue(days.waitForExistence(timeout: 10), "the countdown did not open the vouch")
        XCTAssertEqual(days.label, "23 days left")
        XCTAssertTrue(byId(app, "vouching.mine.verify").exists, "the door that lasts is not offered")
        XCTAssertTrue(byLabelContaining(app, L("vouch.right.directMessages")).exists, "what waits for verification is not listed")
        screenshot(app, named: "Your vouch")
    }

    func testTheWarningsReadInArabic() {
        let app = launch(["-mockScenario", "unstarted", "-openLink", Self.link], lang: "ar")
        signInFromTheLanding(app)
        let understand = byId(app, "vouching.warning.person.continue")
        XCTAssertTrue(understand.waitForExistence(timeout: 20))
        XCTAssertTrue(byLabel(app, L("vouch.warning.person.title", nil, "ar")).exists)
        XCTAssertEqual(understand.label, L("vouch.warning.continue", nil, "ar"))
        // Foundation isolates the handle inside the Arabic sentence, so the
        // words around it are what is matched.
        let two = L("vouch.warning.person.two", "noura", "ar")
        XCTAssertTrue(byLabelContaining(app, String(two.prefix(20))).exists, "the second warning is not in Arabic")
        // One language only (§12): no English beside the Arabic.
        XCTAssertFalse(byLabel(app, L("vouch.warning.person.title")).exists, "the English title is drawn too")
        XCTAssertFalse(byLabel(app, L("vouch.warning.continue")).exists, "the English button is drawn too")
        // Both warnings and both buttons on screen without scrolling — on an
        // iPhone SE too.
        let window = app.windows.firstMatch.frame
        for id in ["vouching.warning.person.1", "vouching.warning.person.2", "vouching.warning.person.continue",
                   "vouching.warning.person.cancel"] {
            let element = byId(app, id)
            XCTAssertTrue(element.exists, "\(id) is missing")
            XCTAssertTrue(window.contains(element.frame), "\(id) is off screen: \(element.frame) in \(window)")
        }
        screenshot(app, named: "قبل أن تقبل")
    }

    /// Signs in from the welcome screen, as Khalid.
    private func signInFromWelcome(_ app: XCUIApplication) {
        let start = byId(app, "welcome.signIn")
        XCTAssertTrue(start.waitForExistence(timeout: 20), "never reached the welcome screen")
        start.tap()
        let email = app.textFields.firstMatch
        XCTAssertTrue(email.waitForExistence(timeout: 10))
        email.tap()
        email.typeText("khalid@example.com")
        let password = app.secureTextFields.firstMatch
        XCTAssertTrue(password.waitForExistence(timeout: 5))
        password.tap()
        password.typeText("Passw0rd!234")
        byId(app, "signIn.submit").tap()
    }

    /// Back at the wall after @noura declined the claim (contract v24 §15):
    /// the wall says whose vouch ended, why, and what is left — in the one
    /// language the app is in.
    func testTheWallSaysWhyTheLastVouchEnded() {
        let app = launch(["-mockScenario", "vouchEnded"])
        signInFromWelcome(app)
        let card = byId(app, "vouching.wall.ended")
        XCTAssertTrue(card.waitForExistence(timeout: 20), "the wall does not say the last vouch ended")
        XCTAssertTrue(card.label.contains(L("vouch.ended.title", "noura")), card.label)
        XCTAssertTrue(card.label.contains(L("vouch.ended.reason.declined", "noura")), card.label)
        XCTAssertTrue(card.label.contains(L("vouch.ended.next.again")), card.label)
        // The wall's own way on stays: verification.
        XCTAssertTrue(byLabel(app, L("auth.wall.unstarted.action")).exists, "the wall lost its verify button")
        screenshot(app, named: "The vouch from @noura has ended")
    }

    func testTheWallSaysWhyTheLastVouchEndedInArabicOnly() {
        let app = launch(["-mockScenario", "vouchEnded"], lang: "ar")
        signInFromWelcome(app)
        let card = byId(app, "vouching.wall.ended")
        XCTAssertTrue(card.waitForExistence(timeout: 20), "the wall does not say the last vouch ended")
        // The handle sits in its own isolate; the Arabic around it is matched.
        let title = L("vouch.ended.title", "noura", "ar")
        XCTAssertTrue(card.label.contains(String(title.prefix(10))), card.label)
        XCTAssertTrue(card.label.contains("noura"), card.label)
        XCTAssertTrue(card.label.contains(L("vouch.ended.next.again", nil, "ar")), card.label)
        XCTAssertFalse(card.label.contains("vouch"), "English beside the Arabic: \(card.label)")
        XCTAssertFalse(card.label.contains(L("vouch.ended.next.again")), "English beside the Arabic: \(card.label)")
        screenshot(app, named: "انتهت تزكية @noura لك")
    }

    /// A vouched listener (contract v24 §4): no reactions, no share, and a
    /// chat that says why it takes no line — to the room or privately to the
    /// host — with the door to verification opening over the chat sheet.
    func testAVouchedListenerIsOfferedNoChatNoReactionsAndNoShare() {
        let app = launch(["-mockScenario", "vouched"])
        signInFromWelcome(app)
        XCTAssertTrue(byId(app, "vouching.banner").waitForExistence(timeout: 20), "never reached the feed")

        app.buttons["Rooms"].tap()
        XCTAssertTrue(app.staticTexts["LIVE NOW"].waitForExistence(timeout: 15), "no live rooms")
        app.staticTexts["LIVE"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts[L("rooms.listening.title")].waitForExistence(timeout: 15), "not in the room")

        XCTAssertTrue(byLabelContaining(app, String(L("vouch.limited.rooms").prefix(40))).exists,
                      "the room does not say what waits for verification")
        XCTAssertFalse(byId(app, "rooms.reaction.👏").exists, "a vouched listener was offered reactions")
        XCTAssertFalse(app.buttons[L("rooms.share.a11yLabel")].exists, "a vouched listener was offered the share")
        XCTAssertFalse(app.buttons[L("rooms.hand.raise")].exists, "a vouched listener was offered the hand")

        // Nothing past the screen's edges: the reactions row used to push
        // the whole room 412pt wide.
        let width = app.windows.firstMatch.frame.width
        let header = app.staticTexts[L("rooms.live.stage.header").uppercased()]
        XCTAssertTrue(header.exists)
        XCTAssertGreaterThanOrEqual(header.frame.minX, 12, "the room runs off the left edge")
        XCTAssertLessThanOrEqual(app.buttons["Leave room"].firstMatch.frame.maxX, width, "the room runs off the right edge")
        screenshot(app, named: "A vouched listener's room")

        byId(app, "rooms.chat.open").tap()
        XCTAssertTrue(byId(app, "rooms.chat.vouched").waitForExistence(timeout: 10), "the chat does not say why it is closed")
        XCTAssertFalse(app.textFields[L("rooms.chat.placeholder")].exists, "a composer was drawn")
        XCTAssertFalse(app.buttons[L("rooms.chat.audience.host")].exists, "the private line to the host was offered")
        screenshot(app, named: "A vouched listener's chat")

        let verify = byId(app, "rooms.chat.vouched.verify")
        XCTAssertTrue(verify.exists, "no way to verify from the chat")
        verify.tap()
        let notNow = byId(app, "verification.selfCover.close")
        XCTAssertTrue(notNow.waitForExistence(timeout: 10), "the verification flow did not open over the chat sheet")
        screenshot(app, named: "Verification over the room's chat")
        notNow.tap()
        XCTAssertTrue(gone(notNow, timeout: 10))
        XCTAssertTrue(byId(app, "rooms.chat.vouched").exists, "closing the flow did not return to the chat")
    }
}

/// The voucher's side through the real UI (contract v24 §5, §12): the
/// Profile entry, the list with a claim to confirm, the two warnings before
/// any link is minted, and a voucher a strike has stopped.
///
/// Runs against the mocks: `-mockVouchingScenario voucher | empty | struck`.
final class VoucherJourneyUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ scenario: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-freshStorage", "-noBiometrics",
            "-mockAuth", "-mockScenario", "verified",
            "-mockFeed", "-mockFeedScenario", "populated",
            "-mockProfile", "-mockProfileScenario", "populated",
            "-mockVouchingScenario", scenario
        ]
        app.launch()
        return app
    }

    private func signIn(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons["Sign In"].waitForExistence(timeout: 20), "never reached the welcome screen")
        app.buttons["Sign In"].tap()
        let email = app.textFields.firstMatch
        XCTAssertTrue(email.waitForExistence(timeout: 10))
        email.tap()
        email.typeText("aziz@example.com")
        let password = app.secureTextFields.firstMatch
        XCTAssertTrue(password.waitForExistence(timeout: 5))
        password.tap()
        password.typeText("Passw0rd!234")
        app.buttons.matching(identifier: "Sign In").element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["For You"].waitForExistence(timeout: 20), "a verified account did not reach the feed")
    }

    private func byId(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func byLabelContaining(_ app: XCUIApplication, _ text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    private func screenshot(_ app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The Profile tab's "Vouch for someone you know", scrolled to and opened.
    private func openVouching(_ app: XCUIApplication) -> XCUIElement {
        app.buttons["Profile"].tap()
        let entry = app.buttons["Vouch for someone you know"]
        XCTAssertTrue(entry.waitForExistence(timeout: 15), "the Profile has no vouching entry while vouching is open")
        var tries = 0
        while !entry.isHittable && tries < 6 {
            app.swipeUp()
            tries += 1
        }
        return entry
    }

    func testAVoucherConfirmsWhoAcceptedTheirLink() {
        let app = launch("voucher")
        signIn(app)
        let entry = openVouching(app)
        screenshot(app, named: "Profile entry, dimmed with the reason")
        entry.tap()

        // The claim waiting inside its 48 hours, with what the voucher wrote.
        let confirm = byId(app, "vouching.list.confirm")
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "no claim to confirm")
        XCTAssertTrue(byLabelContaining(app, "Khalid Al-Harbi").exists, "the voucher does not see what they wrote")
        XCTAssertTrue(byLabelContaining(app, "A moderator is asking about @omar_h").exists, "the finding is not on the vouch")
        screenshot(app, named: "The voucher's list")

        // Asked in place, then confirmed.
        confirm.tap()
        let yes = byId(app, "vouching.list.confirm.confirm")
        XCTAssertTrue(yes.waitForExistence(timeout: 5), "no \"Is this who you meant?\" step")
        XCTAssertTrue(byLabelContaining(app, "Is this who you meant?").exists)
        screenshot(app, named: "Is this who you meant?")
        yes.tap()

        XCTAssertTrue(byLabelContaining(app, "Confirmed. @khalid can post now.").waitForExistence(timeout: 10),
                      "the confirmation was not said")
        let stillPending = NSPredicate(format: "exists == false")
        let gone = XCTNSPredicateExpectation(predicate: stillPending, object: byId(app, "vouching.list.confirm"))
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 10), .completed, "the claim is still waiting after its confirmation")
    }

    func testMintingALinkStartsWithTheTwoWarnings() {
        let app = launch("empty")
        signIn(app)
        openVouching(app).tap()

        let create = byId(app, "vouching.list.create")
        XCTAssertTrue(create.waitForExistence(timeout: 10))
        create.tap()

        // Before the details form, both warnings on screen (§12).
        let understand = byId(app, "vouching.warning.voucher.continue")
        XCTAssertTrue(understand.waitForExistence(timeout: 10), "the warnings did not come first")
        XCTAssertTrue(byLabelContaining(app, "Before you vouch").exists)
        XCTAssertTrue(byLabelContaining(app, "Only vouch for someone you know in person.").exists)
        XCTAssertTrue(byLabelContaining(app, "you lose the right to vouch for good").exists)
        XCTAssertFalse(app.textFields["Full name"].exists, "no details form before the warnings")
        screenshot(app, named: "Before you vouch")

        understand.tap()
        XCTAssertTrue(app.textFields["Full name"].waitForExistence(timeout: 5), "no details form after the warnings")
        screenshot(app, named: "Who are they?")
    }

    /// Scrolls the sheet until `element` sits clear of the bottom edge.
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        let window = app.windows.firstMatch
        var tries = 0
        while (!element.isHittable || element.frame.maxY > window.frame.maxY - 80) && tries < 8 {
            let before = element.frame
            let from = window.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.7))
            from.press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.45)))
            usleep(800_000)
            if element.frame == before { break }
            tries += 1
        }
    }

    /// The one moment the link exists (contract v24 §5): Share opens the
    /// system share sheet, and a link that went nowhere does not close away
    /// without a word.
    func testAMintedLinkOpensTheShareSheetAndIsNotClosedAwayUnshared() {
        let app = launch("empty")
        signIn(app)
        openVouching(app).tap()
        let create = byId(app, "vouching.list.create")
        XCTAssertTrue(create.waitForExistence(timeout: 10))
        create.tap()
        let understand = byId(app, "vouching.warning.voucher.continue")
        XCTAssertTrue(understand.waitForExistence(timeout: 10))
        understand.tap()

        let name = app.textFields["Full name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("Khalid Al-Harbi\n")
        // A tap while the keyboard is still going down lands on the row as
        // it moves, and opens nothing.
        XCTAssertTrue(gone(app.keyboards.firstMatch, timeout: 5))
        byId(app, "vouching.form.nationality").tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10), "no search on the nationality list")
        // Somebody else's nationality: not "Your nationality".
        XCTAssertTrue(app.navigationBars["Nationality"].exists, "the voucher's list is not titled for them")
        XCTAssertFalse(app.navigationBars["Your nationality"].exists)
        search.tap()
        search.typeText("Saudi")
        let saudi = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Saudi")).firstMatch
        XCTAssertTrue(saudi.waitForExistence(timeout: 10))
        saudi.tap()
        let birth = byId(app, "vouching.form.dateOfBirth")
        XCTAssertTrue(birth.waitForExistence(timeout: 10))
        reveal(birth, in: app)
        birth.tap()          // opens the wheel on a date 25 years back: an adult
        birth.tap()          // and closes it again
        for promise in ["knows", "adult", "realName", "singleAccount"] {
            let box = byId(app, "vouching.new.attest.\(promise)")
            reveal(box, in: app)
            box.tap()
        }
        let mint = byId(app, "vouching.new.create")
        reveal(mint, in: app)
        mint.tap()

        let share = byId(app, "vouching.new.share")
        XCTAssertTrue(share.waitForExistence(timeout: 10), "the link was not made")
        screenshot(app, named: "Your link is ready")
        share.tap()
        let sheet = app.otherElements["ActivityListView"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 10), "Share link opened no share sheet")
        screenshot(app, named: "The share sheet")
        // Closed without sending it anywhere.
        let closeShare = app.buttons["Close"].firstMatch
        if closeShare.waitForExistence(timeout: 3) {
            closeShare.tap()
        } else {
            sheet.swipeDown()
        }
        XCTAssertTrue(share.waitForExistence(timeout: 10))

        byId(app, "vouching.new.close").tap()
        let warning = byId(app, "vouching.new.closeWarning")
        XCTAssertTrue(warning.waitForExistence(timeout: 5), "a link that went nowhere closed without a word")
        screenshot(app, named: "Close without sharing it?")

        byId(app, "vouching.new.copy").tap()
        XCTAssertTrue(gone(warning, timeout: 5), "copying the link settles the question")
        byId(app, "vouching.new.close").tap()
        XCTAssertTrue(gone(share, timeout: 10), "the sheet did not close once the link was copied")
    }

    /// Waits for `element` to leave the screen.
    private func gone(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    func testAStruckVoucherIsToldTheRightIsGone() {
        let app = launch("struck")
        signIn(app)
        let entry = openVouching(app)
        XCTAssertTrue(entry.label.contains("Vouch for someone you know"))
        entry.tap()
        XCTAssertTrue(byId(app, "vouching.list.privilegeLost").waitForExistence(timeout: 10),
                      "a struck voucher is not told the right is gone")
        XCTAssertFalse(byId(app, "vouching.list.create").isEnabled, "a struck voucher can still mint")
        screenshot(app, named: "One strike")
    }
}
