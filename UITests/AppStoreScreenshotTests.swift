import XCTest

/// App Store screenshots for Known | معروف — six screens, one locale per run.
///
/// Not a test of behaviour: it walks the mock world and writes full-screen
/// PNGs. Opt-in, so a normal `SilaUITests` run skips it:
///
///     TEST_RUNNER_KNOWN_SHOTS_LANG=ar \
///     TEST_RUNNER_KNOWN_SHOTS_DIR=/Users/abdulazizalwakeel/sila-l10n/screenshots/ar-SA \
///     xcodebuild test-without-building … -only-testing:SilaUITests/AppStoreScreenshotTests
///
/// Output: `<dir>/01-feed.png` … `<dir>/06-explore.png`.
final class AppStoreScreenshotTests: XCTestCase {

    // MARK: - Configuration

    private static var env: [String: String] { ProcessInfo.processInfo.environment }

    private static var outputDir: URL? {
        env["KNOWN_SHOTS_DIR"].map { URL(fileURLWithPath: $0) }
    }

    private static var lang: String {
        (env["KNOWN_SHOTS_LANG"] ?? "en").lowercased() == "ar" ? "ar" : "en"
    }
    private var lang: String { Self.lang }

    override func setUpWithError() throws {
        guard Self.outputDir != nil else {
            throw XCTSkip("App Store screenshots run only with TEST_RUNNER_KNOWN_SHOTS_DIR set.")
        }
        continueAfterFailure = false
    }

    // MARK: - Strings

    /// `key → [lang: value]`, read from the app's catalogue in the source tree,
    /// so labels without an identifier resolve in either language.
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

    private func L(_ key: String) -> String {
        Self.catalogue[key]?[lang] ?? Self.catalogue[key]?["en"] ?? key
    }

    // MARK: - Launch

    private func launch(extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        let language: [String] = lang == "ar"
            ? ["-AppleLanguages", "(ar)", "-AppleLocale", "ar_SA"]
            : ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchArguments = language + [
            "-freshStorage",
            "-mockAuth", "-mockScenario", "verified",
            "-mockFeed", "-mockFeedScenario", "populated",
            "-mockProfile", "-mockProfileScenario", "populated",
            "-mockNotifications", "-mockNotificationsScenario", "populated",
            "-mockSearch", "-mockSearchScenario", "populated",
            "-mockVoiceEngine",
            "-noBiometrics",
            "-noOnboarding",
        ] + extra
        app.launch()
        return app
    }

    /// Welcome → Sign In → the feed.
    private func signIn(_ app: XCUIApplication) {
        tap(app, id: "welcome.signIn", timeout: 25)
        let email = app.textFields.firstMatch
        XCTAssertTrue(email.waitForExistence(timeout: 10), "no email field")
        email.tap()
        email.typeText("aziz@example.com")
        let password = app.secureTextFields.firstMatch
        XCTAssertTrue(password.waitForExistence(timeout: 5), "no password field")
        password.tap()
        password.typeText("Passw0rd!234")
        tap(app, id: "signIn.submit")
        XCTAssertTrue(byId(app, "segment.forYou").waitForExistence(timeout: 25), "never reached the feed")
    }

    // MARK: - Queries

    private func byId(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func tap(_ element: XCUIElement, timeout: TimeInterval = 15, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "missing \(element)", file: file, line: line)
        if element.isHittable {
            element.tap()
        } else {
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
    }

    private func tap(_ app: XCUIApplication, id: String, timeout: TimeInterval = 15, file: StaticString = #filePath, line: UInt = #line) {
        tap(byId(app, id), timeout: timeout, file: file, line: line)
    }

    private func settle(_ seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    private func clearSystemAlerts() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch
        guard alert.exists else { return }
        (alert.buttons.allElementsBoundByIndex.last ?? alert.buttons.firstMatch).tap()
        settle(0.8)
    }

    // MARK: - Output

    private func shot(_ name: String, settleFor seconds: TimeInterval = 2) {
        settle(seconds)
        clearSystemAlerts()
        let screenshot = XCUIScreen.main.screenshot()
        guard let dir = Self.outputDir else { return }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try screenshot.pngRepresentation.write(to: dir.appendingPathComponent("\(name).png"))
        } catch {
            XCTFail("could not write \(name).png: \(error)")
        }
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "\(lang)/\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: - 1. Home feed

    func test1_Feed() {
        let app = launch()
        signIn(app)
        _ = byId(app, "discover.live.room").waitForExistence(timeout: 8)
        shot("01-feed", settleFor: 3)
    }

    // MARK: - 2. A thread

    func test2_Thread() {
        let app = launch()
        signIn(app)
        tap(app, id: "segment.following", timeout: 10)
        let bodies = app.textViews.matching(NSPredicate(format: "label CONTAINS %@", "biggest change"))
        XCTAssertTrue(bodies.firstMatch.waitForExistence(timeout: 10), "no root post in Following")
        settle(1.5)
        guard let body = bodies.allElementsBoundByIndex.first(where: { $0.exists && $0.isHittable }) else {
            return XCTFail("root post not tappable")
        }
        // The text is selectable, so a tap on it is swallowed; the card's own
        // open button sits behind the empty column under the avatar.
        let window = app.windows.firstMatch.frame
        let x = lang == "ar" ? window.maxX - 30 : window.minX + 30
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: x, dy: body.frame.maxY - 10)).tap()
        XCTAssertTrue(app.navigationBars.firstMatch.buttons.element(boundBy: 0).waitForExistence(timeout: 10))
        shot("02-thread", settleFor: 3)
    }

    // MARK: - 3. A live voice room

    func test3_LiveRoom() {
        let app = launch(extra: ["-mockRooms", "-mockRoomsScenario", "hosting"])
        signIn(app)
        tap(app, id: "tab.rooms")
        let live = app.staticTexts[L("rooms.status.live")].firstMatch
        tap(live, timeout: 15)
        XCTAssertTrue(app.buttons[L("rooms.live.leave.a11yLabel")].waitForExistence(timeout: 15), "room never opened")
        shot("03-live-room", settleFor: 3)
    }

    // MARK: - 4. Composer and the "who can reply" picker

    func test4_Composer() {
        let app = launch()
        signIn(app)
        tap(app, id: "feed.fab")
        XCTAssertTrue(byId(app, "composer.cancel").waitForExistence(timeout: 10), "composer never opened")
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 8), "no editor")
        settle(1)
        let text = lang == "ar"
            ? "وين ألذ قهوة سعودية في الرياض؟ أبي رأي أهل الديرة"
            : "Where's the best Saudi coffee in Riyadh? Locals only, please"
        editor.tap()
        editor.typeText(text)
        settle(0.8)
        // Only compatriots may answer: pick the country row.
        let onlyWord = lang == "ar" ? "فقط." : "only."
        let country = app.buttons.matching(NSPredicate(
            format: "label CONTAINS %@ AND label CONTAINS %@", lang == "ar" ? "السعودية" : "Saudi Arabia", onlyWord)).firstMatch
        // Drags on the window, above the keyboard: `app.scrollViews` would
        // find the keyboard's own scroll views and swipe-type into the post.
        let window = app.windows.firstMatch
        func drag(from: CGFloat, to: CGFloat) {
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: from))
                .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: to)))
            settle(1.2)
        }
        if country.waitForExistence(timeout: 5) { tap(country) }
        settle(1)
        // A drag from the content down into the keyboard dismisses it
        // (interactive dismissal); a draft with words in
        // it cannot be swiped away, so the sheet stays.
        for _ in 0..<3 where app.keyboards.count > 0 {
            drag(from: 0.3, to: 0.97)
        }
        drag(from: 0.25, to: 0.6)
        let keep = app.buttons[L("composer.discard.keepWriting")]
        if keep.exists { keep.tap(); settle(1) }
        shot("04-composer", settleFor: 2)
    }

    // MARK: - 5. Profile

    func test5_Profile() {
        let app = launch()
        signIn(app)
        tap(app, id: "tab.profile")
        XCTAssertTrue(app.buttons[L("profile.editProfile")].waitForExistence(timeout: 15), "profile never loaded")
        shot("05-profile", settleFor: 3)
    }

    // MARK: - 6. Explore

    func test6_Explore() {
        let app = launch()
        signIn(app)
        tap(app, id: "tab.explore")
        _ = app.buttons.containing(NSPredicate(format: "label CONTAINS '#riyadh'")).firstMatch.waitForExistence(timeout: 15)
        // In Arabic the Live now rail opens scrolled one card past its start
        // (a right-to-left offset quirk); one swipe brings it back.
        let room = byId(app, "discover.live.room")
        if lang == "ar", room.waitForExistence(timeout: 8) {
            settle(1.5)
            room.swipeRight()
        }
        shot("06-explore", settleFor: 3)
    }
}
