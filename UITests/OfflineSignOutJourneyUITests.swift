import XCTest

/// Signing out with no network.
///
/// Offline, a request waits for the connection to come back for up to
/// forty-five seconds before it fails, and sign-out used to wait with it
/// before the welcome screen came back. Now the server gets a few seconds
/// (`AppConfig.signOutDeadline`) and the phone signs out without it.
///
/// `-mockStoredSession` opens the app on a verified account's stored session,
/// and `-mockScenario stalled` makes every auth call — the logout included —
/// wait as an offline one does.
final class OfflineSignOutJourneyUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    func testSigningOutOfflineReturnsToTheWelcomeScreenInSeconds() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-mockAuth", "-mockScenario", "stalled", "-mockStoredSession",
            "-mockFeed", "-mockFeedScenario", "populated",
            "-noBiometrics",
            "-freshStorage",
        ]
        app.launch()

        XCTAssertTrue(
            app.buttons["For You"].waitForExistence(timeout: 20),
            "the app never opened on the stored account"
        )
        app.buttons["Profile"].tap()
        let signOut = app.buttons["Sign out"]
        XCTAssertTrue(signOut.waitForExistence(timeout: 10), "the Profile tab has no sign-out")

        let tapped = Date()
        signOut.tap()

        XCTAssertTrue(
            app.buttons["Sign In"].waitForExistence(timeout: 20),
            "sign-out never reached the welcome screen"
        )
        let waited = Date().timeIntervalSince(tapped)
        XCTAssertLessThan(waited, 15, "signed out only after \(Int(waited)) s — sign-out waited for the network")
        XCTAssertFalse(app.buttons["For You"].exists, "the feed outlived the sign-out")

        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = "Offline sign-out — the welcome screen, in seconds"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
