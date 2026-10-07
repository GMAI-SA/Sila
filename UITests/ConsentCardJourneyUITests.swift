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
        XCTAssertTrue(byId(app, "document.send.title").waitForExistence(timeout: 15), "no step that sends")
        return app
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

        if !send.isHittable { app.swipeUp() }
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
}
