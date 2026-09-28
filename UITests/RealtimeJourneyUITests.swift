import XCTest

/// Real time (contract v30) through the real UI, in English and in Arabic:
/// a message that lands in the inbox and the badges without anybody pulling,
/// "typing…" in the thread, the reply appearing by itself, "Read" under the
/// message it belongs to — and, with the socket refused, the app carrying on
/// exactly as it did before real time existed.
///
/// Runs against the mocks: `RealtimeServerMock` speaks the socket's protocol
/// in-process and plays @noura in the mocked thread, so every frame goes
/// through the same client, decoder and view models a real socket's would.
final class RealtimeJourneyUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

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

    private func L(_ key: String, _ lang: String) -> String {
        Self.catalogue[key]?[lang] ?? key
    }

    // MARK: - Launch

    private func launch(_ scenario: String, lang: String = "en") -> XCUIApplication {
        let app = XCUIApplication()
        let language: [String] = lang == "ar"
            ? ["-AppleLanguages", "(ar)", "-AppleLocale", "ar_SA"]
            : ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchArguments = language + [
            "-freshStorage",
            "-mockAuth", "-mockScenario", "verified",
            "-mockFeed", "-mockFeedScenario", "populated",
            "-mockNotifications", "-mockNotificationsScenario", "populated",
            "-mockRealtime", scenario,
            "-noBiometrics", "-noOnboarding",
        ]
        app.launch()
        signIn(app)
        XCTAssertTrue(byId(app, "tab.messages").waitForExistence(timeout: 25), "the tabs never appeared")
        return app
    }

    /// Signed in through the form, by identifiers, which no language changes.
    /// The socket opens once the session exists.
    private func signIn(_ app: XCUIApplication) {
        let door = byId(app, "welcome.signIn")
        XCTAssertTrue(door.waitForExistence(timeout: 20), "never reached the welcome screen")
        door.tap()
        let email = app.textFields.firstMatch
        XCTAssertTrue(email.waitForExistence(timeout: 10), "no email field")
        email.tap()
        email.typeText("aziz@example.com")
        let password = app.secureTextFields.firstMatch
        XCTAssertTrue(password.waitForExistence(timeout: 5), "no password field")
        password.tap()
        password.typeText("Passw0rd!234")
        byId(app, "signIn.submit").tap()
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

    /// Waits for `element`'s `key` to satisfy `format`.
    private func wait(_ element: XCUIElement, _ format: String, _ args: CVarArg..., timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: format, argumentArray: args)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func openThreadWithNoura(_ app: XCUIApplication) {
        byId(app, "tab.messages").tap()
        let row = byId(app, "messages.row.noura")
        XCTAssertTrue(row.waitForExistence(timeout: 15), "no thread with @noura in the inbox")
        row.tap()
        XCTAssertTrue(byId(app, "chat.input").waitForExistence(timeout: 10), "the thread did not open")
    }

    // MARK: - Live messaging

    func testAReplyTypesAndArrivesByItselfInEnglish() {
        replyTypesAndArrivesByItself(lang: "en")
    }

    func testAReplyTypesAndArrivesByItselfInArabic() {
        replyTypesAndArrivesByItself(lang: "ar")
    }

    /// The viewer writes to @noura; she reads it, types, and answers — and
    /// the thread shows each as it happens, with nothing pulled or reopened.
    private func replyTypesAndArrivesByItself(lang: String) {
        let app = launch("replies", lang: lang)
        openThreadWithNoura(app)

        let input = byId(app, "chat.input")
        input.tap()
        input.typeText("See you at eight")
        byId(app, "chat.send").tap()
        let mine = byLabelContaining(app, "See you at eight")
        XCTAssertTrue(mine.waitForExistence(timeout: 10), "the sent message is not in the thread")

        // typing… — in the other person's place, in the interface's language.
        let typing = byId(app, "chat.typing")
        XCTAssertTrue(typing.waitForExistence(timeout: 10), "\"typing…\" never appeared")
        // One snapshot for its words and its place: it lasts only until her
        // message, and asking twice can find it gone.
        guard let seen = try? typing.snapshot() else { return XCTFail("\"typing…\" left before it could be read") }
        screenshot(app, named: "Realtime — typing (\(lang))")
        let sentence = L("messages.typing.row", lang).replacingOccurrences(of: "%@", with: "")
            .trimmingCharacters(in: .whitespaces)
        XCTAssertTrue(seen.label.contains(sentence), "typing label: \(seen.label)")
        let window = app.windows.firstMatch.frame
        if lang == "ar" {
            XCTAssertGreaterThan(seen.frame.midX, window.midX, "right-to-left, the other person's side is the right")
        } else {
            XCTAssertLessThan(seen.frame.midX, window.midX, "the other person's side is the left")
        }
        // Read — she read it before she started typing: under the message
        // just sent, not the older one.
        let read = byId(app, "chat.read")
        XCTAssertTrue(
            wait(read, "exists == true AND label == %@", L("messages.bubble.read", lang), timeout: 5),
            "no read receipt appeared"
        )
        XCTAssertGreaterThan(read.frame.minY, mine.frame.minY, "\"Read\" is not under the latest message")

        // The reply, by itself; its arrival ends the typing.
        let reply = byLabelContaining(app, "On my way")
        XCTAssertTrue(reply.waitForExistence(timeout: 20), "the reply never arrived without a refresh")
        XCTAssertTrue(wait(typing, "exists == false", timeout: 5), "\"typing…\" outlived the message it announced")
        screenshot(app, named: "Realtime — reply arrived (\(lang))")
    }

    // MARK: - The inbox and the badges

    func testTheInboxAndBothBadgesMoveOnTheirOwnInEnglish() {
        inboxAndBadgesMoveOnTheirOwn(lang: "en")
    }

    func testTheInboxAndBothBadgesMoveOnTheirOwnInArabic() {
        inboxAndBadgesMoveOnTheirOwn(lang: "ar")
    }

    /// @noura writes first while the viewer looks at the inbox: the row says
    /// she is typing, then carries her words, and the Messages and Alerts
    /// badges count them — nobody pulls anything.
    private func inboxAndBadgesMoveOnTheirOwn(lang: String) {
        let app = launch("incoming", lang: lang)
        let messages = byId(app, "tab.messages")
        messages.tap()
        let row = byId(app, "messages.row.noura")
        XCTAssertTrue(row.waitForExistence(timeout: 10), "no thread with @noura in the inbox")
        // Two unread to begin with — which Arabic says without a digit (the
        // dual), so the start is only compared, not read.
        let before = messages.value as? String
        let alerts = byId(app, "tab.notifications")
        XCTAssertTrue(wait(alerts, "value CONTAINS '3'", timeout: 10), "the alerts badge did not start at 3")

        let typing = L("messages.typing.row", lang).replacingOccurrences(of: "%@", with: "")
            .trimmingCharacters(in: .whitespaces)
        XCTAssertTrue(wait(row, "label CONTAINS %@", typing, timeout: 15), "the row never said @noura was typing")
        screenshot(app, named: "Realtime — inbox, typing (\(lang))")

        XCTAssertTrue(wait(row, "label CONTAINS %@", "Are you coming tonight?", timeout: 15),
                      "the row never showed the new message")
        XCTAssertFalse(row.label.contains(typing), "the row still says typing after her message")
        XCTAssertTrue(wait(messages, "value CONTAINS '3'", timeout: 5), "the inbox badge did not count it: \(messages.value ?? "")")
        XCTAssertNotEqual(messages.value as? String, before)
        XCTAssertTrue(wait(alerts, "value CONTAINS '4'", timeout: 5), "the alerts badge did not move: \(alerts.value ?? "")")
        screenshot(app, named: "Realtime — inbox, arrived (\(lang))")
    }

    // MARK: - Without real time

    /// The socket refused (`1013 realtime_unavailable`): sending still works,
    /// nothing live happens, and pulling reads the reply as it always did.
    func testWithoutRealTimeTheAppRefreshesAsBefore() {
        let app = launch("unavailable")
        openThreadWithNoura(app)

        let input = byId(app, "chat.input")
        input.tap()
        input.typeText("Anyone there?")
        byId(app, "chat.send").tap()
        XCTAssertTrue(byLabelContaining(app, "Anyone there?").waitForExistence(timeout: 10), "sending needs no socket")

        // The reply is on the "server" after about fourteen seconds; with no
        // socket, nothing says so.
        sleep(17)
        XCTAssertFalse(byLabelContaining(app, "On my way").exists, "something arrived live with the socket refused")
        XCTAssertFalse(byId(app, "chat.typing").exists)

        // Back to the inbox and pull: today's refresh behaviour.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let row = byId(app, "messages.row.noura")
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        let start = row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 400)))
        XCTAssertTrue(wait(row, "label CONTAINS %@", "On my way", timeout: 15), "pulling did not read the reply")
        screenshot(app, named: "Realtime — refused, pulled")
    }
}
