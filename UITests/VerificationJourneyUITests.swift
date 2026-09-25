import XCTest

/// Contract v25 through the real UI: a submission waiting for review is taken
/// back and the methods are offered again, and a rejection by the document
/// pre-screen says why and goes straight back to the camera.
///
/// Runs against `AuthServiceMock` and `VerificationServiceMock`, so it needs
/// no network and spends no identity.
final class VerificationJourneyUITests: XCTestCase {

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

    private func L(_ key: String, _ lang: String = "en") -> String {
        Self.catalogue[key]?[lang] ?? key
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

    // MARK: - Withdraw and start again

    func testAWaitingSubmissionIsWithdrawnAndTheMethodsAreOfferedAgain() {
        let app = launch(["-mockScenario", "pendingReview", "-mockVerification"])
        signIn(app)

        let withdraw = byId(app, "verification.withdraw")
        XCTAssertTrue(withdraw.waitForExistence(timeout: 20), "the wall offers the withdrawal while a submission waits")
        screenshot(app, named: "Wall under review, with Withdraw and start again")

        // Asked first, in place — and "keep it" leaves everything as it was.
        withdraw.tap()
        let keep = byId(app, "verification.withdraw.keep")
        XCTAssertTrue(keep.waitForExistence(timeout: 5), "no confirmation step")
        XCTAssertTrue(byLabel(app, L("verification.withdraw.confirm.title")).exists)
        screenshot(app, named: "Withdrawal confirmation")
        keep.tap()
        XCTAssertTrue(withdraw.waitForExistence(timeout: 5))
        XCTAssertFalse(byId(app, "verification.withdraw.confirm").exists)

        withdraw.tap()
        let confirm = byId(app, "verification.withdraw.confirm")
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()

        // Both claims are on file, so the method choice opens straight away.
        XCTAssertTrue(
            byId(app, "verification.method.nafath.comingSoon").waitForExistence(timeout: 15),
            "withdrawing did not return to the method choice"
        )
        screenshot(app, named: "Method choice after the withdrawal")
    }

    // MARK: - The pre-screen's rejection

    private func assertScreenedOut(lang: String) {
        let app = launch(["-mockScenario", "screenedOut", "-mockVerificationScenario", "rejected"], lang: lang)
        signIn(app)

        XCTAssertTrue(
            byLabel(app, L("auth.rejected.screened.title", lang)).waitForExistence(timeout: 20),
            "the rejected screen does not say the photos could not be used"
        )
        // The reason in words, in the reader's language — never the code.
        let sentence = L("auth.rejected.reason.notADocument", lang)
        XCTAssertTrue(byLabelContaining(app, String(sentence.prefix(30))).exists, "the reason is not shown")
        XCTAssertFalse(byLabelContaining(app, "not_a_document").exists, "the code reached the screen")
        // The appeal stays; "Try another way" gives way to the retake.
        XCTAssertTrue(byLabel(app, L("auth.rejected.appeal", lang)).exists, "no appeal")
        XCTAssertFalse(byLabel(app, L("auth.rejected.tryAgain", lang)).exists)
        screenshot(app, named: "Pre-screen rejection (\(lang))")

        let retake = byId(app, "rejected.retake")
        XCTAssertTrue(retake.waitForExistence(timeout: 5), "no Try again")
        retake.tap()

        // Straight to the camera for the ID card the mock says was sent,
        // with Photos and Files beside it.
        XCTAssertTrue(byId(app, "document.upload.photo").waitForExistence(timeout: 20), "the retake did not open the capture step")
        XCTAssertTrue(byId(app, "document.upload.file").exists)
        XCTAssertTrue(byLabel(app, L("document.capture.front.title", lang)).exists)
        XCTAssertTrue(byId(app, "document.changeDocument").exists)
        screenshot(app, named: "Retake at the capture step (\(lang))")

        // Cancelling goes back to the reason and the appeal.
        app.navigationBars.buttons[L("common.cancel", lang)].tap()
        XCTAssertTrue(
            byLabel(app, L("auth.rejected.screened.title", lang)).waitForExistence(timeout: 20),
            "cancelling the retake lost the rejected screen"
        )
    }

    func testAPreScreenRejectionSaysWhyAndGoesStraightBackToTheCamera() {
        assertScreenedOut(lang: "en")
    }

    func testThePreScreenRejectionReadsInArabic() {
        assertScreenedOut(lang: "ar")
    }
}
