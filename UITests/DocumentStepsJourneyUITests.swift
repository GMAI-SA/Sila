import XCTest

/// The document step the owner called "step 3", through the real UI, in
/// English and in Arabic: each side says it was added, with its picture and a
/// check, and what comes next; the review shows both sides with a Retake on
/// each; the upload counts up, then the server checks, then "Received".
///
/// Runs against the mocks (a simulator has no camera, so each side is the
/// sample photo), slowed with `-mockSlowDocumentUpload` so the progress and
/// the check can be seen.
final class DocumentStepsJourneyUITests: XCTestCase {

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
            "-mockSlowDocumentUpload"
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

    /// The simulator's sample photo for the side on screen, kept.
    private func addSide(_ app: XCUIApplication) {
        let sample = byId(app, "document.mock.useSample")
        XCTAssertTrue(sample.waitForExistence(timeout: 15), "no camera stand-in on this side")
        sample.tap()
        let use = byId(app, "document.capture.usePhoto")
        XCTAssertTrue(use.waitForExistence(timeout: 10), "the still never asked to be kept")
        use.tap()
    }

    // MARK: - The journey

    private func walkTheDocumentSteps(lang: String) {
        let app = launch(lang: lang)
        signIn(app)

        // The pre-screen turned the last ID card away: straight to its camera.
        let retake = byId(app, "rejected.retake")
        XCTAssertTrue(retake.waitForExistence(timeout: 25), "no retake on the rejected screen")
        retake.tap()
        XCTAssertTrue(byLabel(app, L("document.capture.front.title", lang)).waitForExistence(timeout: 20))

        // The front: kept, read, and then unmistakably in — its picture and a
        // check, "Front added", and the back asked for next.
        addSide(app)
        let frontCard = byId(app, "document.sideAdded.front")
        XCTAssertTrue(frontCard.waitForExistence(timeout: 15), "nothing said the front was added")
        XCTAssertTrue(byLabelContaining(app, L("document.side.front.added", lang)).exists)
        XCTAssertTrue(byLabel(app, L("document.capture.back.title", lang)).exists, "the next side is not named")
        XCTAssertTrue(byId(app, "document.retake.front").exists)
        XCTAssertFalse(byLabel(app, L("document.capture.front.title", lang)).exists, "still on the front's page")
        screenshot(app, named: "Front added, now the back (\(lang))")

        // The back: the review shows both sides, each with its own Retake.
        addSide(app)
        XCTAssertTrue(byId(app, "document.sideAdded.back").waitForExistence(timeout: 15), "nothing said the back was added")
        XCTAssertTrue(byId(app, "document.sideAdded.front").exists)
        XCTAssertTrue(byLabelContaining(app, L("document.side.back.added", lang)).exists)
        XCTAssertTrue(byId(app, "document.retake.front").exists)
        XCTAssertTrue(byId(app, "document.retake.back").exists)
        screenshot(app, named: "Review with both sides (\(lang))")

        // Retaking the back keeps the front, and comes back to the review.
        byId(app, "document.retake.back").tap()
        XCTAssertTrue(byLabel(app, L("document.capture.back.title", lang)).waitForExistence(timeout: 10))
        XCTAssertTrue(byId(app, "document.sideAdded.front").exists, "retaking the back lost the front")
        addSide(app)
        XCTAssertTrue(byId(app, "document.sideAdded.back").waitForExistence(timeout: 15))

        let looksRight = byId(app, "document.review.continue")
        XCTAssertTrue(looksRight.waitForExistence(timeout: 5))
        // Below the details, under the home indicator until scrolled to.
        app.swipeUp()
        looksRight.tap()
        let face = byId(app, "document.sweep.useSample")
        XCTAssertTrue(face.waitForExistence(timeout: 15), "no face step")
        face.tap()

        // The upload counts up in percent; then the server's check; then the
        // answer — never a spinner with no words.
        let uploading = byId(app, "document.upload.progress")
        XCTAssertTrue(uploading.waitForExistence(timeout: 10), "no upload progress")
        let words = L("document.submitting.uploading", lang).components(separatedBy: "%@").first ?? ""
        XCTAssertTrue(uploading.label.contains(words.trimmingCharacters(in: .whitespaces)), uploading.label)
        XCTAssertTrue(uploading.label.rangeOfCharacter(from: .decimalDigits) != nil, "no percentage: \(uploading.label)")
        screenshot(app, named: "Uploading with progress (\(lang))")
        XCTAssertTrue(byId(app, "document.checking").waitForExistence(timeout: 15), "nothing said the server was checking")
        XCTAssertTrue(byLabelContaining(app, L("document.submitting.uploaded", lang)).exists)
        screenshot(app, named: "Checking your documents (\(lang))")
        XCTAssertTrue(byId(app, "document.submitted").waitForExistence(timeout: 20), "no answer after the check")
        XCTAssertTrue(byLabelContaining(app, L("document.submitted.received", lang)).exists)
        XCTAssertTrue(byLabel(app, L("document.submitted.title", lang)).exists)
        screenshot(app, named: "Received, under review (\(lang))")
    }

    func testEachSideSaysItWasAddedAndTheUploadCountsUp() {
        walkTheDocumentSteps(lang: "en")
    }

    func testTheDocumentStepsReadInArabic() {
        walkTheDocumentSteps(lang: "ar")
    }
}
