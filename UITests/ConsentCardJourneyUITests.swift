import XCTest

/// The consent card of contract v34 §7.2, through the real UI, in English and
/// in Arabic: after the face check the step that sends shows "Keep your
/// photos? (optional)" in the chosen language only, the box unticked and
/// Send enabled; sending with the tick says the photos are kept encrypted in
/// the verification file, sending without it keeps today's words.
///
/// Runs against the mocks with `-mockRetentionConsent` (the server announces
/// `vf1`). A simulator has no camera: each side and the face are the canned
/// sample pictures of the mock camera, never a real document.
final class ConsentCardJourneyUITests: XCTestCase {

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

    // MARK: - Helpers

    private func launch(lang: String) -> XCUIApplication {
        let app = XCUIApplication()
        let language: [String] = lang == "ar"
            ? ["-AppleLanguages", "(ar)", "-AppleLocale", "ar_SA"]
            : ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchArguments = language + [
            "-freshStorage", "-mockAuth", "-noBiometrics",
            "-mockScenario", "screenedOut", "-mockVerificationScenario", "rejected",
            "-mockRetentionConsent", "-mockSlowDocumentUpload"
        ]
        app.launch()
        return app
    }

    private func signIn(_ app: XCUIApplication) {
        let start = byId(app, "welcome.signIn")
        XCTAssertTrue(start.waitForExistence(timeout: 20), "never reached the welcome screen")
        start.tap()
        let email = app.textFields.firstMatch
        XCTAssertTrue(email.waitForExistence(timeout: 10), "no email field on the sign-in screen")
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

    private func addSide(_ app: XCUIApplication) {
        let sample = byId(app, "document.mock.useSample")
        XCTAssertTrue(sample.waitForExistence(timeout: 15), "no camera stand-in on this side")
        sample.tap()
        let use = byId(app, "document.capture.usePhoto")
        XCTAssertTrue(use.waitForExistence(timeout: 10), "the still never asked to be kept")
        use.tap()
    }

    /// From sign-in to the step that sends, through the pre-screen's retake.
    private func reachTheSendStep(lang: String) -> XCUIApplication {
        let app = launch(lang: lang)
        signIn(app)
        let retake = byId(app, "rejected.retake")
        XCTAssertTrue(retake.waitForExistence(timeout: 25), "no retake on the rejected screen")
        retake.tap()
        XCTAssertTrue(byLabel(app, L("document.capture.front.title", lang)).waitForExistence(timeout: 20))
        addSide(app)
        XCTAssertTrue(byId(app, "document.sideAdded.front").waitForExistence(timeout: 15))
        addSide(app)
        XCTAssertTrue(byId(app, "document.sideAdded.back").waitForExistence(timeout: 15))
        let looksRight = byId(app, "document.review.continue")
        XCTAssertTrue(looksRight.waitForExistence(timeout: 5))
        app.swipeUp()
        looksRight.tap()
        let face = byId(app, "document.sweep.useSample")
        XCTAssertTrue(face.waitForExistence(timeout: 15), "no face step")
        face.tap()
        XCTAssertTrue(byId(app, "document.send.button").waitForExistence(timeout: 15), "no step that sends")
        return app
    }

    /// Line 5 as the app draws it: the route filled in from the labels the
    /// Profile tab, the Account sheet, its Privacy section and the row show.
    private func route(_ lang: String) -> String {
        ["feed.tab.profile.label", "feed.profileOff.account.title", "account.section.privacy",
         "settings.privacy.verificationPhotos.row"].map { L($0, lang) }.joined(separator: " › ")
    }

    /// Contract v34 §7.2: every line of the card is on the screen, beside
    /// Send, without scrolling, at the default text size. Checked on arrival,
    /// before any swipe: each element's whole frame lies inside the window
    /// and below the navigation bar, and Send can be tapped where it is.
    private func expectWholeCardOnScreen(_ app: XCUIApplication, lang: String) {
        let window = app.windows.firstMatch.frame
        let navBottom = app.navigationBars.firstMatch.exists ? app.navigationBars.firstMatch.frame.maxY : window.minY
        let ids = ["document.consent.title"]
            + (1...5).map { "document.consent.line\($0)" }
            + ["document.consent.checkbox", "document.consent.link", "document.send.button"]
        for id in ids {
            let element = byId(app, id)
            XCTAssertTrue(element.exists, "\(lang): \(id) missing")
            let frame = element.frame
            XCTAssertFalse(frame.isEmpty, "\(lang): \(id) has no frame")
            XCTAssertGreaterThanOrEqual(frame.minY, navBottom, "\(lang): \(id) is under the navigation bar: \(frame)")
            XCTAssertLessThanOrEqual(frame.maxY, window.maxY, "\(lang): \(id) runs below the screen: \(frame) in \(window)")
            XCTAssertTrue(window.contains(frame), "\(lang): \(id) is not wholly on screen: \(frame) in \(window)")
        }
        XCTAssertTrue(byId(app, "document.send.button").isHittable, "\(lang): Send is not tappable where it is")
    }

    // MARK: - The journeys

    private func theCardInOneLanguage(lang: String) {
        let app = reachTheSendStep(lang: lang)
        let other = lang == "ar" ? "en" : "ar"

        // The card, in the chosen language only.
        XCTAssertTrue(byLabel(app, L("document.consent.title", lang)).waitForExistence(timeout: 5))
        XCTAssertFalse(byLabel(app, L("document.consent.title", other)).exists, "both languages on the card")
        XCTAssertTrue(byLabelContaining(app, L("document.consent.line4", lang)).exists)
        XCTAssertFalse(byLabelContaining(app, L("document.consent.line4", other)).exists)
        XCTAssertTrue(byId(app, "document.consent.link").exists)

        // Line 5 names the route the person really follows, in this language.
        let line5 = byId(app, "document.consent.line5")
        XCTAssertTrue(line5.label.contains(route(lang)), "line 5 does not name the route: \(line5.label)")
        XCTAssertFalse(line5.label.contains(lang == "ar" ? "الإعدادات" : "Settings"), "no Settings screen on iOS")

        // All of it beside Send, no scrolling, on this phone.
        expectWholeCardOnScreen(app, lang: lang)

        // Unticked, and Send works anyway.
        let box = byId(app, "document.consent.checkbox")
        XCTAssertTrue(box.exists)
        XCTAssertEqual(box.value as? String, L("document.consent.checkbox.off", lang), "the box must start unticked")
        let send = byId(app, "document.send.button")
        XCTAssertTrue(send.isEnabled, "Send is enabled without the tick")
        screenshot(app, named: "Consent card, unticked (\(lang))")

        box.tap()
        XCTAssertEqual(box.value as? String, L("document.consent.checkbox.on", lang))
        XCTAssertTrue(send.isEnabled)
        screenshot(app, named: "Consent card, ticked (\(lang))")

        XCTAssertTrue(send.isHittable, "Send moved off the screen after the tick")
        send.tap()
        XCTAssertTrue(byLabelContaining(app, L("document.submitting.message.kept", lang)).waitForExistence(timeout: 10),
                      "ticked: the photos are said to be kept")
        XCTAssertFalse(byLabelContaining(app, L("document.submitting.message", lang)).exists)
        screenshot(app, named: "Uploading, kept (\(lang))")
        XCTAssertTrue(byId(app, "document.submitted").waitForExistence(timeout: 25), "no answer after the check")
    }

    func testTheConsentCardReadsInEnglishStartsUntickedAndSendWorks() {
        theCardInOneLanguage(lang: "en")
    }

    func testTheConsentCardReadsInArabicOnly() {
        theCardInOneLanguage(lang: "ar")
    }

    func testSendingWithoutTheTickKeepsTodaysWords() {
        let app = reachTheSendStep(lang: "en")
        let send = byId(app, "document.send.button")
        if !send.isHittable { app.swipeUp() }
        send.tap()
        XCTAssertTrue(byLabelContaining(app, L("document.submitting.message", "en")).waitForExistence(timeout: 10),
                      "unticked: deleted the moment a reviewer decides, as today")
        XCTAssertTrue(byId(app, "document.submitted").waitForExistence(timeout: 25))
    }

    // MARK: - The route line 5 names (review fix, finding 1)

    /// Follows line 5 word for word: the Profile tab, its Account entry
    /// (the sheet is titled Account), the Privacy section and the
    /// Verification photos row — each step found by the very label the card
    /// names — then withdraws there.
    private func followTheRoute(lang: String) {
        let app = XCUIApplication()
        let language: [String] = lang == "ar"
            ? ["-AppleLanguages", "(ar)", "-AppleLocale", "ar_SA"]
            : ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchArguments = language + [
            "-freshStorage", "-mockAuth", "-noBiometrics", "-noOnboarding",
            "-mockScenario", "verified", "-mockVerification", "-mockKeptPhotos"
        ]
        app.launch()
        signIn(app)

        let steps = route(lang).components(separatedBy: " › ")
        XCTAssertEqual(steps.count, 4)
        let profile = app.buttons[steps[0]]
        XCTAssertTrue(profile.waitForExistence(timeout: 25), "\(lang): no tab named \(steps[0])")
        profile.tap()
        let account = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", steps[1])).firstMatch
        XCTAssertTrue(account.waitForExistence(timeout: 10), "\(lang): Profile has no entry named \(steps[1])")
        account.tap()
        XCTAssertTrue(app.navigationBars[steps[1]].waitForExistence(timeout: 10), "\(lang): the sheet is not titled \(steps[1])")

        let row = byId(app, "settings.privacy.verificationPhotos.row")
        var swipes = 0
        while !(row.exists && row.isHittable) && swipes < 8 {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(row.exists, "\(lang): no Verification photos row")
        XCTAssertEqual(row.label, steps[3])
        XCTAssertTrue(byLabel(app, steps[2]).exists, "\(lang): no section named \(steps[2])")
        screenshot(app, named: "Profile › Account › Privacy › Verification photos (\(lang))")

        byId(app, "settings.privacy.verificationPhotos.button").tap()
        let confirm = byId(app, "settings.privacy.verificationPhotos.confirmButton")
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "no in-place confirmation")
        // The confirmation opens below the row, which can be at the bottom
        // of the sheet, over the home indicator where a tap does not land:
        // bring its button well up before tapping it.
        swipes = 0
        let safeBottom = app.windows.firstMatch.frame.maxY - 120
        while (!confirm.isHittable || confirm.frame.maxY > safeBottom) && swipes < 4 {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(confirm.isHittable, "\(lang): the confirmation's button is off the screen")
        confirm.tap()
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: row)
        let result = XCTWaiter().wait(for: [gone], timeout: 15)
        if result != .completed {
            print("V34DEBUG confirm=\(confirm.frame) window=\(app.windows.firstMatch.frame)")
            print("V34DEBUG \(app.debugDescription)")
            XCTFail("\(lang): the row stayed after withdrawing")
        }
    }

    func testLineFivesRouteLeadsToTheRowInEnglish() {
        followTheRoute(lang: "en")
    }

    func testLineFivesRouteLeadsToTheRowInArabic() {
        followTheRoute(lang: "ar")
    }
}
