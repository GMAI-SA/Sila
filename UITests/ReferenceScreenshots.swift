import XCTest

/// Reference screenshots of the iPhone app, for judging the web redesign
/// against. Not a test of behaviour: nothing here asserts, it only walks the
/// mock world and writes one PNG per screen.
///
/// Output: `/Users/abdulazizalwakeel/sila-web/docs/ios-reference/<lang>/<NN-screen>.png`
/// plus `_capture-log.tsv` (one line per screen: OK or SKIP, with the reason).
///
/// Language comes from the runner's environment, so one file serves both:
///
///     TEST_RUNNER_SILA_REF_LANG=ar xcodebuild test-without-building … \
///         -only-testing:SilaUITests/ReferenceScreenshots
///
/// Labels that carry no accessibility identifier are resolved from the app's
/// own string catalogue at run time, so the same walk works in Arabic.
final class ReferenceScreenshots: XCTestCase {

    // MARK: - Configuration

    private static let outputRoot = "/Users/abdulazizalwakeel/sila-web/docs/ios-reference"

    /// Opt-in: without `TEST_RUNNER_SILA_REF_LANG` every test here skips, so a
    /// full `SilaUITests` run neither pays for this walk nor overwrites the
    /// reference set with whatever is on the working tree.
    private static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["SILA_REF_LANG"] != nil
    }

    private static var lang: String {
        let value = ProcessInfo.processInfo.environment["SILA_REF_LANG"]?.lowercased() ?? "en"
        return value == "ar" ? "ar" : "en"
    }
    private var lang: String { Self.lang }

    private static var outputDir: URL {
        URL(fileURLWithPath: outputRoot).appendingPathComponent(lang)
    }

    private static var logURL: URL { outputDir.appendingPathComponent("_capture-log.tsv") }

    override class func setUp() {
        super.setUp()
        guard isEnabled else { return }
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: logURL)
    }

    override func setUpWithError() throws {
        guard Self.isEnabled else {
            throw XCTSkip("Reference screenshots run only with TEST_RUNNER_SILA_REF_LANG=en|ar.")
        }
        continueAfterFailure = true
    }

    // MARK: - Strings

    /// `key → [lang: value]`, read from the app's catalogue in the source tree.
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

    private func L(_ key: String, _ args: CVarArg...) -> String {
        let format = Self.catalogue[key]?[lang] ?? Self.catalogue[key]?["en"] ?? key
        return args.isEmpty ? format : String(format: format, arguments: args)
    }

    // MARK: - Launch

    private func launch(_ scenario: String = "verified", extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        let language: [String] = lang == "ar"
            ? ["-AppleLanguages", "(ar)", "-AppleLocale", "ar_SA"]
            : ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchArguments = language + [
            "-freshStorage",
            "-mockAuth", "-mockScenario", scenario,
            "-mockFeed", "-mockFeedScenario", "populated",
            "-noBiometrics",
        ] + extra
        app.launch()
        return app
    }

    /// Welcome → Sign In → submit. Returns once the submit is tapped; the
    /// caller waits for whatever the scenario lands on.
    @discardableResult
    private func signIn(_ app: XCUIApplication, waitForFeed: Bool = true) -> Bool {
        guard tap(app, id: "welcome.signIn") else { return false }
        let email = app.textFields.firstMatch
        guard email.waitForExistence(timeout: 10) else { return false }
        email.tap()
        email.typeText("aziz@example.com")
        let password = app.secureTextFields.firstMatch
        guard password.waitForExistence(timeout: 5) else { return false }
        password.tap()
        password.typeText("Passw0rd!234")
        guard tap(app, id: "signIn.submit") else { return false }
        guard waitForFeed else { return true }
        return byId(app, "segment.forYou").waitForExistence(timeout: 25)
    }

    // MARK: - Queries

    private func byId(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func byLabel(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    private func byLabelPrefix(_ app: XCUIApplication, _ prefix: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    private func byLabelContaining(_ app: XCUIApplication, _ text: String, type: XCUIElement.ElementType = .any) -> XCUIElement {
        app.descendants(matching: type).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    /// Taps, falling back to a coordinate tap when the accessibility tap's
    /// scroll-to-visible preamble cannot complete (the custom tab bar).
    @discardableResult
    private func tap(_ element: XCUIElement, timeout: TimeInterval = 15) -> Bool {
        guard element.waitForExistence(timeout: timeout) else { return false }
        if element.isHittable {
            element.tap()
        } else {
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        return true
    }

    @discardableResult
    private func tap(_ app: XCUIApplication, id: String, timeout: TimeInterval = 15) -> Bool {
        tap(byId(app, id), timeout: timeout)
    }

    private func back(_ app: XCUIApplication) {
        let button = app.navigationBars.firstMatch.buttons.element(boundBy: 0)
        if button.waitForExistence(timeout: 5) { tap(button) }
        settle(1.0)
    }

    private func settle(_ seconds: TimeInterval = 1.2) {
        Thread.sleep(forTimeInterval: seconds)
    }

    /// Scrolls the main area until `element` is on screen, or gives up.
    private func scrollTo(_ app: XCUIApplication, _ element: XCUIElement, maxSwipes: Int = 6) -> Bool {
        for _ in 0..<maxSwipes {
            if element.exists && element.isHittable { return true }
            app.swipeUp()
            settle(0.6)
        }
        return element.exists && element.isHittable
    }

    /// A system alert (camera, notifications…) would sit on top of the
    /// screenshot. Accept it so the app's own screen is what gets captured.
    private func clearSystemAlerts() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch
        guard alert.exists else { return }
        let buttons = alert.buttons.allElementsBoundByIndex
        (buttons.last ?? alert.buttons.firstMatch).tap()
        settle(0.8)
    }

    // MARK: - Output

    private func record(_ status: String, _ name: String, _ detail: String) {
        let line = "\(status)\t\(name)\t\(detail.replacingOccurrences(of: "\t", with: " "))\n"
        let url = Self.logURL
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    /// Writes the whole screen (status bar and keyboard included) as `<name>.png`.
    private func shot(_ name: String, _ state: String, settleFor seconds: TimeInterval = 1.2) {
        settle(seconds)
        clearSystemAlerts()
        let screenshot = XCUIScreen.main.screenshot()
        let url = Self.outputDir.appendingPathComponent("\(name).png")
        do {
            try FileManager.default.createDirectory(at: Self.outputDir, withIntermediateDirectories: true)
            try screenshot.pngRepresentation.write(to: url)
            record("OK", name, state)
        } catch {
            record("FAIL", name, "could not write \(url.path): \(error)")
        }
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "\(lang)/\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// A region of the screen, for a card that deserves a close-up.
    private func crop(_ name: String, _ state: String, rect: CGRect, in app: XCUIApplication) {
        let screenshot = XCUIScreen.main.screenshot()
        guard let cg = screenshot.image.cgImage else { return }
        let pointsWide = app.windows.firstMatch.frame.width
        guard pointsWide > 0 else { return }
        let scale = CGFloat(cg.width) / pointsWide
        let pixels = CGRect(x: rect.minX * scale, y: rect.minY * scale,
                            width: rect.width * scale, height: rect.height * scale).integral
        guard let cropped = cg.cropping(to: pixels),
              let data = UIImage(cgImage: cropped).pngData() else { return }
        let url = Self.outputDir.appendingPathComponent("\(name).png")
        if (try? data.write(to: url)) != nil { record("OK", name, state) }
    }

    private func skip(_ name: String, _ reason: String) {
        record("SKIP", name, reason)
    }

    // MARK: - 01–05 Signed out

    func test01_SignedOut() {
        let app = launch()
        guard byId(app, "welcome.signIn").waitForExistence(timeout: 25) else {
            return ["01-welcome", "02-register", "03-signin", "04-forgot"].forEach { skip($0, "welcome never appeared") }
        }
        shot("01-welcome", "Welcome screen, signed out (fresh launch).")

        if tap(app, id: "welcome.createAccount") {
            _ = app.textFields.firstMatch.waitForExistence(timeout: 10)
            shot("02-register", "Create account form, empty.")
            back(app)
        } else { skip("02-register", "no Create account button") }

        guard tap(app, id: "welcome.signIn") else {
            return ["03-signin", "04-forgot"].forEach { skip($0, "no Sign In button") }
        }
        _ = byId(app, "signIn.submit").waitForExistence(timeout: 10)
        shot("03-signin", "Sign-in form, empty.")

        if tap(byLabel(app, L("auth.signIn.forgotPassword")), timeout: 10) {
            shot("04-forgot", "Forgot password: email step (from Sign In).", settleFor: 1.8)
        } else { skip("04-forgot", "no Forgot password link") }
    }

    func test02_OTP() {
        let app = launch("emailUnverified")
        guard signIn(app, waitForFeed: false) else { return skip("05-otp", "sign-in form not reachable") }
        // The mock answers 403 email_unverified; the app replaces Sign In with the code screen.
        let promise = byLabelContaining(app, "aziz@example.com")
        _ = promise.waitForExistence(timeout: 15)
        shot("05-otp", "Email code screen (login purpose) after signing in with an unverified email.", settleFor: 2)
    }

    // MARK: - 06–08 Verification

    func test03_VerificationWall() {
        let app = launch("unstarted")
        guard signIn(app, waitForFeed: false) else {
            return ["06-verification-wall", "07-method-sheet", "08-document-choose"].forEach { skip($0, "sign-in failed") }
        }
        let start = byLabel(app, L("auth.wall.unstarted.action"))
        guard start.waitForExistence(timeout: 20) else {
            return ["06-verification-wall", "07-method-sheet", "08-document-choose"].forEach { skip($0, "wall never appeared") }
        }
        shot("06-verification-wall", "Verification wall, status unstarted (Start Verification).", settleFor: 1.5)

        tap(start)
        let search = app.searchFields.firstMatch
        guard search.waitForExistence(timeout: 10) else {
            return ["07-method-sheet", "08-document-choose"].forEach { skip($0, "nationality picker never appeared") }
        }
        shot("06a-nationality-picker", "Nationality picker sheet (asked before the method when no claim exists).")

        search.tap()
        // In Arabic every name is Arabic, so the ISO code "SA" matches only Saudi Arabia.
        search.typeText(lang == "ar" ? "SA" : "Saudi")
        settle(1.0)
        let saudi = app.buttons.matching(NSPredicate(
            format: "label CONTAINS %@", lang == "ar" ? "السعودية" : "Saudi")).firstMatch
        guard tap(saudi, timeout: 10) else {
            return ["07-method-sheet", "08-document-choose"].forEach { skip($0, "Saudi Arabia not found in picker") }
        }

        let comingSoon = byId(app, "verification.method.nafath.comingSoon")
        guard comingSoon.waitForExistence(timeout: 15) else {
            return ["07-method-sheet", "08-document-choose"].forEach { skip($0, "method sheet never appeared") }
        }
        shot("07-method-sheet", "Method chooser after claiming Saudi nationality: Nafath 'coming soon' + Passport or ID card.", settleFor: 1.5)

        guard tap(byLabelPrefix(app, L("verification.method.document.title") + "."), timeout: 10) else {
            return skip("08-document-choose", "document option not tappable")
        }
        let cont = byLabel(app, L("document.birthdate.continue"))
        if cont.waitForExistence(timeout: 15) {
            shot("07a-document-birthdate", "Document route step 1: date of birth wheel.", settleFor: 1.5)
            tap(cont)
        }
        let passport = byLabelPrefix(app, L("document.type.passport.title") + ".")
        if passport.waitForExistence(timeout: 15) {
            shot("07b-document-type", "Document route: choose passport or national ID.", settleFor: 1.2)
            tap(passport)
        }
        if byId(app, "document.upload.photo").waitForExistence(timeout: 15) {
            shot("08-document-choose", "Passport front capture: camera area (unavailable on simulator) + Upload a photo / Choose a file.", settleFor: 2)
        } else {
            skip("08-document-choose", "upload options never appeared")
        }
    }

    func test04_PendingWall() {
        let app = launch("pendingReview")
        guard signIn(app, waitForFeed: false) else { return skip("06b-verification-pending", "sign-in failed") }
        settle(4)
        shot("06b-verification-pending", "Verification wall, status pending_review (processing ring).", settleFor: 1)
    }

    // MARK: - 09–10 Onboarding

    func test05_Onboarding() {
        let app = launch("verified", extra: ["-forceOnboarding"])
        guard signIn(app, waitForFeed: false),
              byId(app, "onboarding.continue").waitForExistence(timeout: 20) else {
            return ["09-onboarding-subjects", "10-onboarding-people"].forEach { skip($0, "onboarding never appeared") }
        }
        _ = byId(app, "preferences.topic.technology").waitForExistence(timeout: 10)
        for topic in ["technology", "science", "travel"] {
            let tile = byId(app, "preferences.topic.\(topic)")
            if tile.exists && tile.isHittable { tile.tap(); settle(0.3) }
        }
        shot("09-onboarding-subjects", "Onboarding step 1 of 2: subject tiles, three selected (technology, science, travel).")

        tap(app, id: "onboarding.continue")
        if byId(app, "onboarding.done").waitForExistence(timeout: 15) {
            shot("10-onboarding-people", "Onboarding step 2 of 2: people to follow.", settleFor: 2)
        } else {
            skip("10-onboarding-people", "people step never appeared")
        }
    }

    // MARK: - 11–15, 37, 38 Home

    func test06_Home() {
        let app = launch()
        guard signIn(app) else {
            return ["11-home-foryou", "12-home-following", "15-post-detail-thread", "37-fab-hold-menu", "38-question-of-the-week"]
                .forEach { skip($0, "never reached the feed") }
        }
        _ = byId(app, "prompt.answer").waitForExistence(timeout: 10)
        _ = byId(app, "discover.live.room").waitForExistence(timeout: 5)
        shot("11-home-foryou", "Home, For You tab, top: question-of-the-week card, Live now rail, order control, first posts.", settleFor: 2)

        // 38: the same card, full screen and as a close-up.
        let answer = byId(app, "prompt.answer")
        let eyebrow = byLabelContaining(app, L("prompt.eyebrow"))
        if answer.exists {
            shot("38-question-of-the-week", "Question-of-the-week card at the top of For You (full screen).", settleFor: 0.3)
            let top = eyebrow.exists ? eyebrow.frame.minY : answer.frame.minY - 90
            let width = app.windows.firstMatch.frame.width
            let rect = CGRect(x: 0, y: max(0, top - 24), width: width, height: answer.frame.maxY - top + 48)
            crop("38-question-of-the-week-crop", "Close-up crop of the question-of-the-week card.", rect: rect, in: app)
        } else {
            skip("38-question-of-the-week", "no prompt card rendered")
        }

        app.swipeUp()
        shot("11b-home-foryou-scrolled", "Home, For You, scrolled one screen: post cards incl. quote post, Arabic post, reply-blocked post.", settleFor: 1.5)
        app.swipeDown()
        app.swipeDown()
        settle(1)

        // 37: hold the round button.
        let fab = byId(app, "feed.fab")
        if fab.waitForExistence(timeout: 10) {
            fab.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.9)
            if byId(app, "feed.fab.post").waitForExistence(timeout: 5) {
                shot("37-fab-hold-menu", "Home, FAB long-press: Post / GIF / Room options fanned out over a scrim.", settleFor: 1)
            } else {
                skip("37-fab-hold-menu", "long-press did not expand the button")
            }
            fab.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            settle(1)
        } else {
            skip("37-fab-hold-menu", "no FAB")
        }

        // 12: Following.
        if tap(app, id: "segment.following", timeout: 10) {
            shot("12-home-following", "Home, Following tab.", settleFor: 2)
        } else { skip("12-home-following", "no Following segment") }

        // 15: the root post with two replies.
        let bodies = app.textViews.matching(NSPredicate(format: "label CONTAINS %@", "biggest change"))
        _ = bodies.firstMatch.waitForExistence(timeout: 10)
        let visible = bodies.allElementsBoundByIndex.first { $0.exists && $0.isHittable }
        if let body = visible {
            body.tap()
            settle(2.5)
            shot("15-post-detail-thread", "Post detail: @aziz root post (international) with its two replies and the reply bar.", settleFor: 0.5)
            back(app)
        } else {
            skip("15-post-detail-thread", "root post body not tappable in Following")
        }

        // 38b: answering the question opens the composer, prefilled.
        if tap(app, id: "segment.forYou", timeout: 10), tap(app, id: "prompt.answer", timeout: 10) {
            _ = byId(app, "composer.cancel").waitForExistence(timeout: 10)
            shot("38b-question-of-the-week-answer", "Composer opened from the question-of-the-week 'Answer' button (prefilled hashtag).", settleFor: 2)
        }
    }

    // MARK: - 16–17 Composer

    func test07_Composer() {
        let app = launch()
        guard signIn(app), tap(app, id: "feed.fab") else {
            return ["16-composer-empty", "17-composer-poll-editor"].forEach { skip($0, "composer not reachable") }
        }
        guard byId(app, "composer.cancel").waitForExistence(timeout: 10) else {
            return ["16-composer-empty", "17-composer-poll-editor"].forEach { skip($0, "composer sheet never appeared") }
        }
        _ = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'composer.starter.'"))
            .firstMatch.waitForExistence(timeout: 8)
        shot("16-composer-empty", "Composer, empty new post: starter chips, audience picker, attachments (keyboard up).", settleFor: 1.5)

        if tap(app, id: "composer.addPoll", timeout: 8),
           byId(app, "composer.poll.option.0").waitForExistence(timeout: 8) {
            shot("17-composer-poll-editor", "Composer with the poll editor added (two option fields).", settleFor: 1.5)
            if app.keyboards.count > 0 {
                // A slow drag on the scroll content dismisses the keyboard
                // interactively; only keep the shot if the sheet survived it.
                let content = app.scrollViews.firstMatch
                if content.exists {
                    content.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
                        .press(forDuration: 0.05, thenDragTo: content.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)))
                }
                settle(1.2)
                if app.keyboards.count == 0, byId(app, "composer.poll.option.0").exists, byId(app, "composer.cancel").exists {
                    shot("17b-composer-poll-editor-no-keyboard", "Composer poll editor with the keyboard dismissed.", settleFor: 0.5)
                }
            }
        } else {
            skip("17-composer-poll-editor", "poll button not reachable")
        }
    }

    // MARK: - 18–22 Explore

    func test08_ExploreAndSearch() {
        let app = launch()
        guard signIn(app), tap(app, id: "tab.explore") else {
            return ["18-explore-hub", "19-search"].forEach { skip($0, "explore not reachable") }
        }
        _ = app.buttons.containing(NSPredicate(format: "label CONTAINS '#riyadh'")).firstMatch.waitForExistence(timeout: 15)
        shot("18-explore-hub", "Explore hub, idle: search field, Communities entry, discover sections, trending tags.", settleFor: 2)
        app.swipeUp()
        shot("18b-explore-hub-scrolled", "Explore hub scrolled one screen.", settleFor: 1.5)
        app.swipeDown()
        app.swipeDown()
        settle(0.8)

        let field = app.textFields.firstMatch
        if field.waitForExistence(timeout: 8) {
            field.tap()
            field.typeText("no\n")
            shot("19-search", "Search results for \"no\" (people + posts segments), keyboard dismissed by Return.", settleFor: 2.5)
        } else {
            skip("19-search", "no search field")
        }
    }

    func test09_HashtagAndCommunities() {
        let app = launch()
        guard signIn(app), tap(app, id: "tab.explore") else {
            return ["20-hashtag", "21-communities", "22-community"].forEach { skip($0, "explore not reachable") }
        }
        let tag = app.buttons.containing(NSPredicate(format: "label CONTAINS '#riyadh'")).firstMatch
        if tap(tag, timeout: 15), byId(app, "hashtag.sort.newest").waitForExistence(timeout: 10) {
            shot("20-hashtag", "#riyadh tag page: header, sort chips, tagged posts.", settleFor: 2)
            back(app)
        } else {
            skip("20-hashtag", "trending tag not tappable")
        }

        guard tap(app, id: "explore.communities", timeout: 10) else {
            return ["21-communities", "22-community"].forEach { skip($0, "no Communities entry") }
        }
        let runners = byLabelPrefix(app, "Riyadh runners")
        _ = runners.waitForExistence(timeout: 10)
        shot("21-communities", "Communities list (mock: Riyadh runners, Family).", settleFor: 1.5)
        if tap(runners, timeout: 5) {
            shot("22-community", "Community page: Riyadh runners.", settleFor: 2.5)
        } else {
            skip("22-community", "community row not tappable")
        }
    }

    // MARK: - 23–27 Rooms and events

    func test10_Rooms() {
        let app = launch()
        guard signIn(app), tap(app, id: "tab.rooms") else {
            return ["23-rooms-tab", "24-create-room-sheet", "26-events", "27-event-detail"].forEach { skip($0, "rooms not reachable") }
        }
        _ = byLabel(app, L("rooms.status.live")).waitForExistence(timeout: 15)
        shot("23-rooms-tab", "Rooms tab (populated): Live now + Scheduled sections, not-recorded promise.", settleFor: 2)

        if tap(app, id: "feed.fab", timeout: 10) {
            _ = app.navigationBars.buttons[L("common.cancel")].waitForExistence(timeout: 10)
            shot("24-create-room-sheet", "Create room sheet: title, who can speak (audience picker), options.", settleFor: 2)
            let cancel = app.navigationBars.buttons[L("common.cancel")]
            if cancel.exists { cancel.tap() } else { app.swipeDown() }
            settle(1.2)
        } else {
            skip("24-create-room-sheet", "no create button on Rooms")
        }

        let row = byId(app, "events.row")
        if scrollTo(app, row) {
            shot("26-events", "Rooms tab scrolled to the Events section (mock: Derby watch party).", settleFor: 1.2)
            tap(row)
            shot("27-event-detail", "Event detail: Derby watch party, RSVP controls.", settleFor: 2.5)
        } else {
            ["26-events", "27-event-detail"].forEach { skip($0, "events section not found on Rooms tab") }
        }
    }

    func test11_LiveRoom() {
        let app = launch(extra: ["-mockRooms", "-mockRoomsScenario", "listenerOnly", "-mockVoiceEngine"])
        guard signIn(app), tap(app, id: "tab.rooms") else { return skip("25-live-room", "rooms not reachable") }
        let live = app.staticTexts[L("rooms.status.live")].firstMatch
        guard tap(live, timeout: 15) else { return skip("25-live-room", "no live room card") }
        if app.buttons[L("rooms.live.leave.a11yLabel")].waitForExistence(timeout: 15) {
            shot("25-live-room", "Live room as a listener (scenario listenerOnly): stage, listeners, no mic, Leave.", settleFor: 2.5)
        } else {
            skip("25-live-room", "room screen never appeared")
        }
    }

    // MARK: - 28–29 Messages

    func test12_Messages() {
        let app = launch()
        guard signIn(app) else { return ["28-messages-inbox", "29-chat"].forEach { skip($0, "never reached the feed") } }
        if tap(app, id: "tab.messages") {
            _ = byId(app, "messages.screen").waitForExistence(timeout: 10)
            // Messages have no launch-argument mock: the live call fails and
            // the error toast clears after 3 s, leaving the empty inbox.
            shot("28-messages-inbox", "Messages tab: Inbox/Requests folders + empty inbox (no messages mock is launch-selectable).", settleFor: 5)
        } else {
            skip("28-messages-inbox", "no Messages tab")
        }

        guard tap(app, id: "tab.home") else { return skip("29-chat", "could not return home") }
        let maria = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Maria Souza'")).firstMatch
        guard tap(maria, timeout: 10), tap(app, id: "profile.message", timeout: 10) else {
            return skip("29-chat", "no Message button on a profile")
        }
        if byId(app, "chat.input").waitForExistence(timeout: 10) {
            shot("29-chat", "Chat with @maria: new (draft) conversation opened from her profile's Message button.", settleFor: 2)
        } else {
            skip("29-chat", "chat screen never appeared")
        }
    }

    // MARK: - 30–31 Notifications

    func test13_Notifications() {
        let app = launch()
        guard signIn(app), tap(app, id: "tab.notifications") else {
            return ["30-notifications", "31-notification-settings"].forEach { skip($0, "notifications not reachable") }
        }
        _ = byLabel(app, L("notifications.settings.title")).waitForExistence(timeout: 15)
        shot("30-notifications", "Notifications tab (populated): unread summary, Mark all read, rows by kind.", settleFor: 2)
        if tap(byLabel(app, L("notifications.settings.title")), timeout: 5) {
            _ = app.switches.firstMatch.waitForExistence(timeout: 10)
            shot("31-notification-settings", "Notification settings sheet: per-kind switches.", settleFor: 1.5)
        } else {
            skip("31-notification-settings", "no settings button")
        }
    }

    // MARK: - 32, 34–36 Own profile

    func test14_OwnProfile() {
        let app = launch()
        guard signIn(app), tap(app, id: "tab.profile") else {
            return ["32-profile-own", "34-preferences", "35-account-settings", "36-saved-posts"].forEach { skip($0, "profile not reachable") }
        }
        _ = app.buttons[L("profile.editProfile")].waitForExistence(timeout: 15)
        shot("32-profile-own", "Own profile (@aziz): header, Edit profile, settings rows.", settleFor: 2)
        app.swipeUp()
        shot("32b-profile-own-scrolled", "Own profile scrolled one screen.", settleFor: 1.5)
        app.swipeDown()
        app.swipeDown()
        settle(0.8)

        let done = L("common.done")
        if tap(app.buttons[L("feed.profileOff.preferences.title")].firstMatch, timeout: 10) {
            _ = app.navigationBars.buttons[done].waitForExistence(timeout: 10)
            shot("34-preferences", "Feed preferences sheet: how topics are decided, summary, tiles below.", settleFor: 2)
            let button = app.navigationBars.buttons[done]
            if button.exists { button.tap() } else { app.swipeDown() }
            settle(1.2)
        } else { skip("34-preferences", "no Feed preferences row") }

        if tap(app.buttons[L("feed.profileOff.account.title")].firstMatch, timeout: 10) {
            _ = app.navigationBars.buttons[done].waitForExistence(timeout: 10)
            shot("35-account-settings", "Account settings sheet (populated).", settleFor: 2)
            let button = app.navigationBars.buttons[done]
            if button.exists { button.tap() } else { app.swipeDown() }
            settle(1.2)
        } else { skip("35-account-settings", "no Account row") }

        let saved = app.buttons[L("profile.savedPosts")].firstMatch
        if scrollTo(app, saved, maxSwipes: 3) {
            tap(saved)
            shot("36-saved-posts", "Saved posts (mock: one bookmarked quote post).", settleFor: 2.5)
        } else { skip("36-saved-posts", "no Saved posts row") }
    }

    // MARK: - 33, 39, 40 Someone else

    func test15_OtherProfileAndReport() {
        let app = launch()
        guard signIn(app) else {
            return ["33-profile-other", "39-report-sheet", "40-guidelines"].forEach { skip($0, "never reached the feed") }
        }
        let maria = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Maria Souza'")).firstMatch
        if tap(maria, timeout: 10), app.staticTexts["@maria"].waitForExistence(timeout: 10) {
            shot("33-profile-other", "Someone else's profile (@maria): Follow + Message, top-level posts.", settleFor: 2)
            back(app)
        } else {
            skip("33-profile-other", "author control not tappable")
        }

        _ = byId(app, "segment.forYou").waitForExistence(timeout: 10)
        let prefix = L("safety.menu.button.a11yLabel").components(separatedBy: "%@").first ?? ""
        let menu = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS 'Maria'", prefix)).firstMatch
        guard tap(menu, timeout: 10) else {
            return ["39-report-sheet", "40-guidelines"].forEach { skip($0, "no safety menu on Maria's post") }
        }
        let report = byLabel(app, L("safety.menu.report"))
        guard tap(report, timeout: 5) else {
            return ["39-report-sheet", "40-guidelines"].forEach { skip($0, "menu had no Report item") }
        }
        settle(2)
        shot("39-report-sheet", "Report sheet for Maria's post: reason picker.", settleFor: 0.5)

        let link = byId(app, "guidelines.link")
        if scrollTo(app, link, maxSwipes: 3) {
            tap(link)
            shot("40-guidelines", "Community guidelines sheet, opened from the report sheet.", settleFor: 2.5)
        } else {
            skip("40-guidelines", "the report sheet shows no 'Read the community guidelines' link (guidelinesGate is nil in the sheet's environment) and the composer gate never triggers for the mock user")
        }
    }
}
