import XCTest

/// "Choose your @handle" through the real UI (contract v33), in English and
/// in Arabic: right after sign-up the first suggestion is in the field; taken,
/// reserved and invalid are each said in a line as the person types; Save
/// takes a free one and the wall follows. And in account settings, Change
/// opens the same chooser.
///
/// Runs against the mocks: a registration's code gives the account the
/// random `@user7k2m9q4x`, not yet chosen.
final class HandleJourneyUITests: XCTestCase {

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

    private func launch(_ arguments: [String], lang: String) -> XCUIApplication {
        let app = XCUIApplication()
        let language: [String] = lang == "ar"
            ? ["-AppleLanguages", "(ar)", "-AppleLocale", "ar_SA"]
            : ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchArguments = language + ["-freshStorage", "-mockAuth", "-noBiometrics"] + arguments
        app.launch()
        return app
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

    /// Replaces whatever the handle field holds with `text`.
    private func type(_ text: String, into field: XCUIElement) {
        // At the end of what is there — the field reads left to right in
        // both languages — so every delete takes a character.
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let current = (field.value as? String) ?? ""
        let deletes = String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 2)
        field.typeText(deletes + text)
    }

    /// Waits for the line under the field to say `line`.
    private func expectStatus(_ app: XCUIApplication, _ line: String, _ message: String) {
        expectLabel(byId(app, "handle.status"), line, message)
    }

    /// Waits for `element` to read `label`.
    private func expectLabel(_ element: XCUIElement, _ label: String, _ message: String) {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if element.exists, element.label == label { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        XCTFail("\(message): it said \(element.label)")
    }

    // MARK: - After sign-up

    private func signUpAndChoose(lang: String) {
        let app = launch(["-mockScenario", "unstarted"], lang: lang)

        let create = byId(app, "welcome.createAccount")
        XCTAssertTrue(create.waitForExistence(timeout: 20), "never reached the welcome screen")
        create.tap()
        let email = app.textFields.firstMatch
        XCTAssertTrue(email.waitForExistence(timeout: 10), "no email field")
        email.tap()
        email.typeText("new@example.com")
        // Shown, not secure: a secure new-password field is taken over by
        // the simulator's Automatic Strong Password before a key is typed.
        for field in ["auth.field.password.label", "auth.register.confirmPassword.label"] {
            // In Arabic the field's name is isolated inside the sentence
            // (FSI…PDI), so the label is matched by its parts.
            let prefix = L("ds.textField.show", lang).components(separatedBy: "%@")[0]
            let show = app.descendants(matching: .any).matching(NSPredicate(
                format: "label BEGINSWITH %@ AND label CONTAINS %@ AND NOT (label CONTAINS %@)",
                prefix, L(field, lang), field == "auth.field.password.label" ? L("auth.register.confirmPassword.label", lang) : "\u{1}"
            )).firstMatch
            XCTAssertTrue(show.waitForExistence(timeout: 5), "no Show for \(field)")
            show.tap()
        }
        let password = app.textFields.element(boundBy: 1)
        password.tap()
        password.typeText("Passw0rd!234")
        let confirm = app.textFields.element(boundBy: 2)
        confirm.tap()
        confirm.typeText("Passw0rd!234")
        let submit = byLabel(app, L("auth.register.submit", lang))
        XCTAssertTrue(submit.waitForExistence(timeout: 5))
        submit.tap()

        // The emailed code.
        let firstBox = app.textFields.firstMatch
        // The address is shown masked (n•w@example.com).
        XCTAssertTrue(byLabelContaining(app, "w@example.com").waitForExistence(timeout: 15), "no code screen")
        firstBox.tap()
        firstBox.typeText("123456")

        // Straight to the handle, before anything else: a suggestion is in
        // the field, and the random one can be kept.
        XCTAssertTrue(byId(app, "handle.title").waitForExistence(timeout: 20), "sign-up did not offer a handle")
        XCTAssertTrue(byLabel(app, L("account.handle.choose.title", lang)).exists)
        let field = byId(app, "handle.field")
        XCTAssertEqual(field.value as? String, "aziz_alwakeel", "the first suggestion is not in the field")
        XCTAssertTrue(byLabel(app, "@azizalwakeel").exists, "the other suggestions are not offered")
        let keep = byId(app, "handle.keep")
        XCTAssertTrue(keep.exists)
        XCTAssertTrue(keep.label.contains("@user7k2m9q4x"), keep.label)
        expectStatus(app, L("account.handle.status.available", lang), "a suggestion is free")
        screenshot(app, named: "Choose your handle (\(lang))")

        // As they type: each reason, in a line, in their language.
        type("taken", into: field)
        expectStatus(app, L("account.handle.reason.taken", lang), "a taken handle")
        XCTAssertFalse(byId(app, "handle.save").isEnabled)
        screenshot(app, named: "Handle taken (\(lang))")
        type("admin", into: field)
        expectStatus(app, L("account.handle.reason.reserved", lang), "a reserved handle")
        type("ab", into: field)
        expectStatus(app, L("account.handle.reason.invalid", lang), "too short")
        type("aziz_w", into: field)
        expectStatus(app, L("account.handle.status.available", lang), "a free handle")
        screenshot(app, named: "Handle available (\(lang))")

        byId(app, "handle.save").tap()

        // Taken, and the wall follows — the step is not offered again.
        XCTAssertTrue(
            byLabel(app, L("auth.wall.unstarted.action", lang)).waitForExistence(timeout: 20),
            "saving did not go on to the verification wall"
        )
        XCTAssertFalse(byId(app, "handle.title").exists)
        screenshot(app, named: "Wall after choosing a handle (\(lang))")
    }

    func testANewAccountChoosesItsHandle() {
        signUpAndChoose(lang: "en")
    }

    func testANewAccountChoosesItsHandleInArabic() {
        signUpAndChoose(lang: "ar")
    }

    // MARK: - An older account, and settings

    /// An account still on its random handle is offered the choice once,
    /// gently: "Keep @user… for now" goes on to the feed. Then Change in
    /// account settings opens the same chooser and takes a new one.
    func testAnOlderAccountMayKeepItsHandleAndChangeItInSettings() {
        let app = launch(["-mockScenario", "verified", "-mockHandleUnchosen", "-noOnboarding"], lang: "en")
        let start = byId(app, "welcome.signIn")
        XCTAssertTrue(start.waitForExistence(timeout: 20))
        start.tap()
        let email = app.textFields.firstMatch
        XCTAssertTrue(email.waitForExistence(timeout: 10))
        email.tap()
        email.typeText("aziz@example.com")
        let password = app.secureTextFields.firstMatch
        password.tap()
        password.typeText("Passw0rd!234")
        byId(app, "signIn.submit").tap()

        XCTAssertTrue(byId(app, "handle.title").waitForExistence(timeout: 20), "the older account was not offered a handle")
        XCTAssertTrue(byLabelContaining(app, "@user7k2m9q4x").exists, "the given handle is not named")
        screenshot(app, named: "Offered once to an older account")
        byId(app, "handle.keep").tap()
        // A sheet over the feed, put away by Keep.
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: byId(app, "handle.title"))
        wait(for: [gone], timeout: 15)
        XCTAssertTrue(app.buttons["Profile"].waitForExistence(timeout: 20), "Keep did not go on to the feed")

        app.buttons["Profile"].tap()
        let entry = app.buttons["Account"]
        XCTAssertTrue(entry.waitForExistence(timeout: 10), "Profile has no route into Account")
        entry.tap()
        let change = byId(app, "account.handle.change")
        XCTAssertTrue(change.waitForExistence(timeout: 15), "settings have no Change for the handle")
        change.tap()

        let field = byId(app, "handle.field")
        XCTAssertTrue(field.waitForExistence(timeout: 10), "Change did not open the chooser")
        XCTAssertTrue(byLabel(app, L("account.handle.change.title", "en")).exists)
        XCTAssertFalse(byId(app, "handle.keep").exists, "settings offer no Keep")
        type("aziz_new", into: field)
        expectStatus(app, L("account.handle.status.available", "en"), "a free handle")
        screenshot(app, named: "Change your handle in settings")
        byId(app, "handle.save").tap()

        expectLabel(byId(app, "account.handle.current"), "@aziz_new", "settings do not show the new handle")
        screenshot(app, named: "Settings show the new handle")
    }
}
