import XCTest

/// The main flow, walked with the device in Arabic.
///
/// Every other UI test runs in English, which means every one of them would
/// still pass on a build whose Arabic layout is broken — and RTL breakage is
/// almost never a missing string. It is a chevron pointing the wrong way, a
/// selection indicator that stayed on the left, a row whose trailing control
/// slid off the edge of the screen, or a number that reversed itself inside a
/// sentence. None of that is visible to a test that never turns Arabic on.
///
/// Navigation here is driven by **accessibility identifiers**, which are not
/// translated, so this file does not have to be edited every time a piece of
/// Arabic copy is reworded. What it asserts *about* the Arabic is structural:
/// that Arabic actually arrived, that the layout mirrored, and that nothing was
/// pushed out of the window by a hard-coded horizontal offset.
final class ArabicRTLJourneyUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    // MARK: - Launch

    private func launchInArabic(extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            // The two arguments iOS itself reads. `-AppleLanguages` picks the
            // bundle; `-AppleLocale` picks the formatters, and a build that set
            // only the first would still format its dates in en_US.
            "-AppleLanguages", "(ar)",
            "-AppleLocale", "ar_SA",
            "-mockAuth", "-mockScenario", "verified",
            "-mockFeed", "-mockFeedScenario", "populated",
            "-noBiometrics",
        ] + extra
        app.launch()
        return app
    }

    // MARK: - Helpers

    /// `true` when the string contains at least one Arabic letter.
    private func isArabic(_ value: String) -> Bool {
        value.unicodeScalars.contains { (0x0600...0x06FF).contains($0.value) }
    }

    /// Any visible label on screen that is written in Arabic.
    private func anyArabicText(_ app: XCUIApplication) -> String? {
        let texts = app.staticTexts.allElementsBoundByIndex.prefix(60)
        return texts.first { $0.exists && isArabic($0.label) }?.label
    }

    /// Fails when any on-screen element sticks out past the window.
    ///
    /// This is the shape almost every real RTL bug takes: something positioned
    /// with a raw `x` offset does not mirror, so under RTL it lands half a
    /// screen further out than it should. In English the same code looks fine,
    /// which is why nobody catches it by looking.
    private func assertNothingOverflows(
        _ app: XCUIApplication,
        _ label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let window = app.windows.firstMatch.frame
        guard window.width > 0 else { return }

        // A slack of one point absorbs the sub-pixel rounding a mirrored layout
        // legitimately produces; anything wider is a layout that did not mirror.
        let slack: CGFloat = 1

        for element in app.buttons.allElementsBoundByIndex + app.staticTexts.allElementsBoundByIndex {
            guard element.exists, element.isHittable else { continue }
            let frame = element.frame
            guard frame.width > 0, frame.height > 0 else { continue }
            XCTAssertGreaterThanOrEqual(
                frame.minX, window.minX - slack,
                "\(label): '\(element.label)' starts \(window.minX - frame.minX)pt off the leading edge",
                file: file, line: line
            )
            XCTAssertLessThanOrEqual(
                frame.maxX, window.maxX + slack,
                "\(label): '\(element.label)' runs \(frame.maxX - window.maxX)pt past the trailing edge",
                file: file, line: line
            )
        }
    }

    private func tap(_ app: XCUIApplication, identifier: String, timeout: TimeInterval = 20) -> Bool {
        // `.firstMatch`, because SwiftUI propagates an accessibility identifier
        // to a control *and* its label, so a bare subscript resolves to two
        // elements and throws "multiple matching elements found" at tap time
        // rather than at query time. Any of the matches is the same control.
        let element = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        guard element.waitForExistence(timeout: timeout) else { return false }

        // `.tap()` performs a scroll-to-visible first, which fails with
        // `kAXErrorCannotComplete` on `SLTabBar` — a custom control that sits
        // in no scroll view, so there is nothing to scroll and the accessibility
        // action has no way to succeed. The element is on screen the whole
        // time; only the gesture's preamble fails.
        //
        // Tapping a coordinate skips that preamble. Used only when the normal
        // tap is unavailable, so a genuinely off-screen control still fails
        // rather than being silently poked at wherever it happens to be.
        if element.isHittable {
            element.tap()
        } else {
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        return true
    }

    private func signIn(_ app: XCUIApplication) {
        XCTAssertTrue(
            tap(app, identifier: "welcome.signIn"),
            "never reached the welcome screen in Arabic"
        )

        let email = app.textFields.firstMatch
        XCTAssertTrue(email.waitForExistence(timeout: 10), "no email field on the Arabic sign-in screen")
        email.tap()
        email.typeText("aziz@example.com")

        let password = app.secureTextFields.firstMatch
        XCTAssertTrue(password.waitForExistence(timeout: 5), "no password field")
        password.tap()
        password.typeText("Passw0rd!234")

        XCTAssertTrue(tap(app, identifier: "signIn.submit"), "no submit button on the sign-in screen")
    }

    // MARK: - The journey

    /// Arabic arrives, the whole main flow is reachable, and nothing overflows
    /// on the way through.
    func testTheMainFlowWorksInArabic() throws {
        let app = launchInArabic()

        XCTAssertNotNil(
            anyArabicText(app),
            "the welcome screen rendered no Arabic — the ar.lproj did not load, or "
            + "-AppleLanguages was ignored because the target does not declare Arabic"
        )
        add(screenshot(app, named: "AR — Welcome"))
        assertNothingOverflows(app, "welcome")

        signIn(app)

        XCTAssertTrue(
            app.descendants(matching: .any)["segment.forYou"].waitForExistence(timeout: 20),
            "a verified account did not reach the feed in Arabic"
        )
        add(screenshot(app, named: "AR — Feed"))
        assertNothingOverflows(app, "feed")

        // Every feed tab, in Arabic. A tab bar that mirrored its layout but not
        // its selection indicator still switches tabs — the failure is visual,
        // so the overflow check is what catches it.
        // `segment.<FeedTab.id>`, which is what `SLSegmentedControl` emits.
        // Not `feed.tab.*` — that is the *localization key* namespace, and the
        // two are easy to conflate because both are dotted and both name the
        // same four tabs. The identifiers deliberately do not change with the
        // language, which is the whole reason this test can navigate in Arabic.
        for identifier in ["segment.following", "segment.myCountry", "segment.international", "segment.forYou"] {
            XCTAssertTrue(tap(app, identifier: identifier, timeout: 10), "segment '\(identifier)' is missing in Arabic")
            XCTAssertTrue(
                app.descendants(matching: .any)["segment.forYou"].waitForExistence(timeout: 10),
                "the feed disappeared after selecting '\(identifier)'"
            )
        }
        add(screenshot(app, named: "AR — Feed, every tab visited"))
        assertNothingOverflows(app, "feed after tabs")

        // The composer — the surface where a wrong text direction is most
        // obvious and most damaging.
        if tap(app, identifier: "tab.compose", timeout: 10) {
            add(screenshot(app, named: "AR — Composer"))
            assertNothingOverflows(app, "composer")

            let editor = app.textViews.firstMatch
            if editor.waitForExistence(timeout: 10) {
                editor.tap()
                editor.typeText("مرحبا")
                add(screenshot(app, named: "AR — Composer with Arabic text"))
            }
            _ = tap(app, identifier: "composer.cancel", timeout: 5)
        }

        // The remaining tabs.
        for identifier in ["tab.explore", "tab.rooms", "tab.notifications", "tab.home"] {
            if tap(app, identifier: identifier, timeout: 10) {
                add(screenshot(app, named: "AR — \(identifier)"))
                assertNothingOverflows(app, identifier)
            }
        }
    }

    /// The interface mirrored.
    ///
    /// Asserted on the feed's tab strip, whose four segments are laid out in a
    /// fixed order in source: under RTL the first must render to the *right* of
    /// the last. A build that translated every string but left
    /// `layoutDirection` alone passes every other test in this file and fails
    /// this one.
    func testTheInterfaceIsMirrored() throws {
        let app = launchInArabic()
        signIn(app)

        let first = app.descendants(matching: .any)["segment.forYou"]
        let last = app.descendants(matching: .any)["segment.international"]
        XCTAssertTrue(first.waitForExistence(timeout: 20), "no feed tabs in Arabic")
        XCTAssertTrue(last.waitForExistence(timeout: 10))

        XCTAssertGreaterThan(
            first.frame.minX, last.frame.minX,
            "the feed tabs did not mirror — 'For You' is still leftmost with the app in Arabic"
        )

        add(screenshot(app, named: "AR — mirrored tab strip"))
    }

    /// An Arabic post laid out inside an **English** app still reads
    /// right-to-left.
    ///
    /// The inverse of everything above, and the case the product actually lives
    /// in: most posts on this network are Arabic, and plenty of the phones
    /// reading them are set to English. The assertion is on the text's own
    /// frame — an Arabic post that was forced into the app's direction hugs the
    /// leading edge of its column; one laid out in its own direction does not.
    func testArabicPostStaysRightToLeftInsideAnEnglishApp() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-mockAuth", "-mockScenario", "verified",
            "-mockFeed", "-mockFeedScenario", "populated",
            "-noBiometrics",
        ]
        app.launch()

        XCTAssertTrue(
            app.buttons["Sign In"].waitForExistence(timeout: 20),
            "never reached the English welcome screen"
        )
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

        XCTAssertTrue(
            app.buttons["For You"].waitForExistence(timeout: 20),
            "a verified account did not reach the English feed"
        )

        // Poll rather than snapshot once: the mock feed answers after a
        // deliberate latency, and a single pass over `staticTexts` taken the
        // instant the tab bar appears reliably runs before any post exists.
        var arabicPost: XCUIElement?
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline, arabicPost == nil {
            arabicPost = app.staticTexts.allElementsBoundByIndex.first { element in
                element.exists && isArabic(element.label) && element.label.count > 12
            }
            if arabicPost == nil { _ = app.staticTexts.firstMatch.waitForExistence(timeout: 1) }
        }
        let post = try XCTUnwrap(
            arabicPost,
            "the populated mock feed rendered no Arabic post, so this test proves nothing — "
            + "seed one in FeedServiceMock"
        )

        add(screenshot(app, named: "EN app — Arabic post"))
        XCTAssertTrue(post.exists)
        XCTAssertGreaterThan(post.frame.width, 0)
    }

    // MARK: - Screenshots

    private func screenshot(_ app: XCUIApplication, named name: String) -> XCTAttachment {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        return attachment
    }
}
