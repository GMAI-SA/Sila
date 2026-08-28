import XCTest

/// Profile → Account, driven through the real UI.
///
/// Every view model here passes in isolation whether or not the screens are
/// wired together, so this is the only test that would notice the Account entry
/// point going missing, the sheet failing to present, or — the one that matters
/// most — the delete button becoming tappable before both halves of its gate
/// are satisfied.
///
/// Runs entirely against the mocks, so no real account is ever at risk.
final class AccountJourneyUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    private func launchApp(accountScenario: String = "populated") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-mockAuth", "-mockScenario", "verified",
            "-mockFeed", "-mockFeedScenario", "populated",
            "-mockAccount", "-mockAccountScenario", accountScenario,
            "-noBiometrics"
        ]
        app.launch()
        return app
    }

    private func signIn(_ app: XCUIApplication) {
        XCTAssertTrue(
            app.buttons["Sign In"].waitForExistence(timeout: 20),
            "never reached the welcome screen"
        )
        app.buttons["Sign In"].tap()

        let email = app.textFields.firstMatch
        XCTAssertTrue(email.waitForExistence(timeout: 10), "no email field")
        email.tap()
        email.typeText("aziz@example.com")

        let password = app.secureTextFields.firstMatch
        XCTAssertTrue(password.waitForExistence(timeout: 5), "no password field")
        password.tap()
        password.typeText("Passw0rd!234")

        app.buttons.matching(identifier: "Sign In").element(boundBy: 0).tap()
        XCTAssertTrue(
            app.buttons["For You"].waitForExistence(timeout: 20),
            "a verified account did not reach the feed"
        )
    }

    private func openAccount(_ app: XCUIApplication) {
        app.buttons["Profile"].tap()
        let entry = app.buttons["Account"]
        XCTAssertTrue(entry.waitForExistence(timeout: 10), "Profile has no route into Account")
        entry.tap()
    }

    /// The screen opens, and the contact number is presented as a contact
    /// detail rather than as anything resembling a verification.
    func testAccountOpensAndThePhoneIsNeverShownAsVerified() throws {
        let app = launchApp()
        signIn(app)
        openAccount(app)

        XCTAssertTrue(
            app.staticTexts["Phone number"].waitForExistence(timeout: 10),
            "the contact number row never appeared"
        )
        // The caption that must be next to it, verbatim from the domain.
        XCTAssertTrue(
            app.staticTexts.containing(
                NSPredicate(format: "label CONTAINS[c] %@", "has not checked that this number is yours")
            ).firstMatch.exists,
            "the number is shown without saying Sila has not checked it"
        )
        XCTAssertFalse(
            app.staticTexts["Verified"].exists,
            "something on the account screen is claiming a verification"
        )

        add(screenshot(app, named: "Account — settings"))
    }

    /// **The gate.** The confirm button stays inert until the password is
    /// present *and* the word is typed exactly, and typing it in lower case is
    /// not enough.
    func testDeletingRequiresBothThePasswordAndTheExactWord() throws {
        let app = launchApp()
        signIn(app)
        openAccount(app)

        let open = app.buttons["Delete account…"]
        XCTAssertTrue(open.waitForExistence(timeout: 10), "no route into deletion")
        open.tap()

        let confirm = app.buttons["Delete my account"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "the deletion form never appeared")
        XCTAssertFalse(confirm.isEnabled, "an empty form could delete an account")

        // Everything about to happen has to be on screen before it can be.
        for phrase in ["deactivated the moment", "signed out", "leave every feed", "30 days"] {
            XCTAssertTrue(
                app.staticTexts.containing(
                    NSPredicate(format: "label CONTAINS[c] %@", phrase)
                ).firstMatch.exists,
                "the confirmation screen does not mention: \(phrase)"
            )
        }

        let password = app.secureTextFields.firstMatch
        XCTAssertTrue(password.waitForExistence(timeout: 5))
        password.tap()
        password.typeText("correct-horse-battery")
        XCTAssertFalse(confirm.isEnabled, "a password alone could delete an account")

        let word = app.textFields.firstMatch
        XCTAssertTrue(word.waitForExistence(timeout: 5))
        word.tap()
        word.typeText("delete")
        XCTAssertFalse(confirm.isEnabled, "a lower-case word passed the gate")

        add(screenshot(app, named: "Account — deletion gate closed"))

        // Backspace it away rather than going through the edit menu, which is
        // not reliably present on a simulator.
        word.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "delete".count))
        word.typeText("DELETE")

        XCTAssertTrue(confirm.isEnabled, "the gate never opened for a correctly filled form")

        add(screenshot(app, named: "Account — deletion gate open"))

        // And it closes again the moment the word stops being exact.
        word.typeText(XCUIKeyboardKey.delete.rawValue)
        XCTAssertFalse(confirm.isEnabled, "a partial word still passed the gate")
    }

    /// An account inside its grace period lands on recovery, not on an error.
    func testAPendingDeletionLandsOnRecoveryWithACancelButton() throws {
        let app = launchApp(accountScenario: "pendingDeletion")
        signIn(app)
        openAccount(app)

        let cancel = app.buttons["Cancel deletion"]
        XCTAssertTrue(
            cancel.waitForExistence(timeout: 15),
            "a deactivated account did not reach the recovery screen"
        )
        XCTAssertFalse(
            app.buttons["Try again"].exists,
            "a deactivated account was offered a retry loop"
        )

        add(screenshot(app, named: "Account — recovery"))

        cancel.tap()

        XCTAssertTrue(
            app.staticTexts["Phone number"].waitForExistence(timeout: 15),
            "cancelling the deletion did not return to account settings"
        )
    }

    private func screenshot(_ app: XCUIApplication, named name: String) -> XCTAttachment {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        return attachment
    }
}
