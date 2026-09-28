import XCTest

/// Opening the app cold, on a stored session, with no network.
///
/// Offline, a request waits for the connection to come back for up to
/// forty-five seconds before it fails, and the splash used to wait with it.
/// Now the app gives the server a few seconds, then opens on the account
/// this phone last knew, with a strip saying it cannot reach Sila, and keeps
/// asking in the background.
///
/// `-mockStoredSession` starts the app with a verified account's session in
/// the keychain (the mocks never write one), and `-mockScenario stalled`
/// makes every auth call wait as an offline one does.
final class OfflineLaunchJourneyUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    func testAnOfflineColdLaunchOpensOnTheStoredAccountInSeconds() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-mockAuth", "-mockScenario", "stalled", "-mockStoredSession",
            "-mockFeed", "-mockFeedScenario", "populated",
            "-noBiometrics",
            "-freshStorage",
        ]
        let launched = Date()
        app.launch()

        XCTAssertTrue(
            app.buttons["For You"].waitForExistence(timeout: 20),
            "the app never opened on the stored account"
        )
        let waited = Date().timeIntervalSince(launched)
        XCTAssertLessThan(waited, 20, "opened only after \(Int(waited)) s — the splash waited for the network")
        XCTAssertFalse(app.buttons["Sign In"].exists, "an offline launch signed the person out")

        let strip = app.descendants(matching: .any)["session.offline"].firstMatch
        XCTAssertTrue(strip.waitForExistence(timeout: 5), "nothing says the app cannot reach the server")
        XCTAssertTrue(strip.label.contains("Can't reach Sila"), strip.label)

        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = "Offline cold launch — the stored account, with the strip"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
