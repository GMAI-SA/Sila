import XCTest

/// The Alerts tab, driven through the real UI.
///
/// The view models pass in isolation whether or not the tab is wired to
/// anything, so this is the only test that would notice the shell still showing
/// the old stub, a row that says nothing about what happened, or a notification
/// tap that goes nowhere.
///
/// Runs entirely against the mocks, so nothing on a real account is marked read.
final class NotificationsJourneyUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    private func launchApp(scenario: String = "populated") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-mockAuth", "-mockScenario", "verified",
            "-mockFeed", "-mockFeedScenario", "populated",
            "-mockNotifications", "-mockNotificationsScenario", scenario,
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

    private func openAlerts(_ app: XCUIApplication) {
        let tab = app.buttons["Alerts"]
        XCTAssertTrue(tab.waitForExistence(timeout: 10), "no Alerts tab")
        tab.tap()
    }

    private func screenshot(_ app: XCUIApplication, named name: String) -> XCTAttachment {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        return attachment
    }

    /// **The tab is real.** Rows that name what happened, the server's unread
    /// count, and the one control that clears anything.
    func testTheAlertsTabListsWhatActuallyHappened() throws {
        let app = launchApp()
        signIn(app)
        openAlerts(app)

        // Each kind states itself. A generic "new notification" row here would
        // be the failure this screen exists to avoid.
        let reply = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] 'replied to you'"))
            .firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 15), "no reply row on the notifications tab")

        let follow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] 'followed you'"))
            .firstMatch
        XCTAssertTrue(follow.exists, "no follow row on the notifications tab")

        // The count and the button that acts on it.
        XCTAssertTrue(
            app.staticTexts["3 unread"].waitForExistence(timeout: 5),
            "the unread summary is missing or disagrees with the mocked server"
        )
        XCTAssertTrue(app.buttons["Mark all read"].exists, "no explicit mark-all control")

        // The deleted post keeps its row rather than vanishing from history.
        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS[c] 'has been deleted'"))
                .firstMatch
                .exists,
            "the notification about a deleted post was dropped instead of rendered"
        )

        add(screenshot(app, named: "Notifications — populated"))
    }

    /// Nothing clears until somebody says so, and then the count follows the
    /// server rather than the screen.
    func testMarkAllReadIsTheOnlyThingThatClearsTheList() throws {
        let app = launchApp()
        signIn(app)
        openAlerts(app)

        let summary = app.staticTexts["3 unread"]
        XCTAssertTrue(summary.waitForExistence(timeout: 15), "no unread summary")

        // Leaving and returning must not clear anything — that would destroy
        // the signal with no way to get it back.
        app.buttons["Home"].tap()
        openAlerts(app)
        XCTAssertTrue(
            app.staticTexts["3 unread"].waitForExistence(timeout: 10),
            "visiting the tab marked notifications read by itself"
        )

        app.buttons["Mark all read"].tap()

        XCTAssertTrue(
            app.staticTexts["Nothing unread"].waitForExistence(timeout: 10),
            "the explicit mark-all control did not clear the count"
        )
        add(screenshot(app, named: "Notifications — all read"))
    }

    /// The switches are reachable from the list they govern — which is where
    /// somebody being pestered by likes goes looking for them.
    func testTheNotificationSwitchesAreReachableFromTheList() throws {
        let app = launchApp()
        signIn(app)
        openAlerts(app)

        let settings = app.buttons["Notification settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 15), "no route into notification settings")
        settings.tap()

        XCTAssertTrue(
            app.switches["Likes"].waitForExistence(timeout: 10),
            "the noisiest kind has no switch"
        )
        for kind in ["Replies", "Mentions", "Reposts", "New followers"] {
            XCTAssertTrue(app.switches[kind].exists, "\(kind) has no switch")
        }
        add(screenshot(app, named: "Notification settings"))
    }
}
