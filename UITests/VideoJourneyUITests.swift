import XCTest

/// Video posts (contract v28), through the real UI, against the mocked video
/// server.
///
/// "Video" picks a sample the app makes on the simulator
/// (`-mockVideoPick`), so no journey depends on what the simulator's photo
/// library holds; everything after the pick is the app's own: compressing,
/// the resumable upload, the post that waits for its video, the author's
/// "preparing" line, and the player. The mocked server keeps what it was
/// sent on disk, so the relaunch journey finds it where it left it; signing
/// in again after the relaunch is the same mocked account, whose uploads are
/// kept for it.
final class VideoJourneyUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(
        pick: String = "short",
        scenario: String = "success",
        reset: Bool = true,
        app: XCUIApplication = XCUIApplication()
    ) -> XCUIApplication {
        app.launchArguments = [
            "-mockAuth", "-mockScenario", "verified",
            "-mockFeed", "-mockFeedScenario", "populated",
            "-mockVideoScenario", scenario,
            "-mockVideoPick", pick,
            "-videoAutoplay", "off",
            "-noBiometrics",
            "-AppleLanguages", "(en)",
        ] + (reset ? ["-resetVideoUploads", "-freshStorage"] : [])
        app.launch()
        signIn(app)
        return app
    }

    /// Signs the mocked verified account in, as a person does. The same
    /// account every time, so a relaunch finds its own uploads.
    private func signIn(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons["Sign In"].waitForExistence(timeout: 20), "never reached the welcome screen")
        app.buttons["Sign In"].tap()
        let email = app.textFields.firstMatch
        // A tap that lands while the welcome screen is still settling can
        // go nowhere; a second one is what a person would do.
        if !email.waitForExistence(timeout: 8), app.buttons["Sign In"].exists {
            app.buttons["Sign In"].tap()
        }
        XCTAssertTrue(email.waitForExistence(timeout: 10), "no email field on the sign-in screen")
        email.tap()
        email.typeText("aziz@example.com")
        let password = app.secureTextFields.firstMatch
        XCTAssertTrue(password.waitForExistence(timeout: 5), "no password field")
        password.tap()
        password.typeText("Passw0rd!234")
        app.buttons.matching(identifier: "Sign In").element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["For You"].waitForExistence(timeout: 30), "a verified account did not reach the feed")
    }

    private func openComposer(_ app: XCUIApplication) {
        let button = app.descendants(matching: .any)["feed.fab"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 15), "the feed has no post button")
        button.tap()
        XCTAssertTrue(app.textViews.firstMatch.waitForExistence(timeout: 10), "the composer never opened")
    }

    private func pickVideo(_ app: XCUIApplication) {
        let add = app.buttons["composer.addVideo"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 10), "a verified account is offered no video")
        add.tap()
    }

    private func status(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["video.upload.status"].firstMatch
    }

    /// Waits until `element`'s label contains `text`.
    @discardableResult
    private func wait(_ element: XCUIElement, contains text: String, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func post(_ app: XCUIApplication, text: String) {
        let editor = app.textViews.firstMatch
        editor.tap()
        editor.typeText(text)
        app.navigationBars.buttons["Post"].firstMatch.tap()
        XCTAssertTrue(app.buttons["For You"].waitForExistence(timeout: 15), "the composer did not close")
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: - Pick → upload → processing → ready

    func testAPickedVideoUploadsIsPreparedThenPlays() throws {
        let app = launch()
        openComposer(app)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "the composer opens ready to type")
        pickVideo(app)

        XCTAssertTrue(status(app).waitForExistence(timeout: 15), "the composer never said where the upload is")
        // The keyboard goes and the video's card is brought into view, so
        // how far the upload is can be read: it used to sit under the
        // keyboard, below the scope list.
        let keyboardGone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == 0"), object: app.keyboards)
        XCTAssertEqual(XCTWaiter().wait(for: [keyboardGone], timeout: 5), .completed, "the keyboard stayed over the video")
        XCTAssertTrue(status(app).isHittable, "the upload's progress is off screen")
        let card = app.descendants(matching: .any)["composer.video"].firstMatch
        XCTAssertLessThanOrEqual(card.frame.maxY, app.windows.firstMatch.frame.maxY, "the video's card is cut off")
        shot(app, "Composer — the video just picked, in view")
        XCTAssertTrue(wait(status(app), contains: "Uploaded", timeout: 30), "the upload never finished: \(status(app).label)")
        shot(app, "Composer — video uploaded")

        post(app, text: "Riyadh at night")

        let preparing = app.descendants(matching: .any)["video.status.processing"].firstMatch
        XCTAssertTrue(preparing.waitForExistence(timeout: 15), "the author is not told the video is being prepared")
        XCTAssertTrue(preparing.label.contains("Only you can see this post"), preparing.label)
        shot(app, "Feed — the author's post, preparing")

        let play = app.buttons["video.play"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 30), "the video never became ready")
        XCTAssertFalse(preparing.exists, "the preparing line stays after the video is ready")
        shot(app, "Feed — ready, with its poster")

        play.tap()
        XCTAssertTrue(app.buttons["video.playPause"].waitForExistence(timeout: 10), "tapping play did not play")

        let captions = app.buttons["video.captions"].firstMatch
        XCTAssertTrue(captions.waitForExistence(timeout: 5), "a video with captions offers them")
        captions.tap()
        let arabic = app.buttons["Arabic (automatic)"].firstMatch
        XCTAssertTrue(arabic.waitForExistence(timeout: 5), "captions are named as automatic")
        XCTAssertTrue(app.buttons["English (automatic)"].exists)
        app.buttons["English (automatic)"].tap()
        let caption = app.descendants(matching: .any)["video.caption"].firstMatch
        XCTAssertTrue(caption.waitForExistence(timeout: 10), "the chosen captions are not shown")
        shot(app, "Feed — playing, English captions")

        app.buttons["video.fullscreen"].firstMatch.tap()
        let close = app.buttons["video.fullscreen.close"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 10), "full screen never opened")
        shot(app, "Full screen")
        close.tap()
        XCTAssertTrue(app.buttons["For You"].waitForExistence(timeout: 10))
    }

    // MARK: - Resuming

    /// The connection drops half way through a piece: the composer says it
    /// is waiting, and the upload carries on by itself.
    func testAnUploadCarriesOnAfterTheConnectionDrops() throws {
        let app = launch(scenario: "dropsOnce")
        openComposer(app)
        pickVideo(app)

        XCTAssertTrue(status(app).waitForExistence(timeout: 15))
        XCTAssertTrue(wait(status(app), contains: "Uploaded", timeout: 40),
                      "the upload did not carry on after the drop: \(status(app).label)")
        XCTAssertFalse(app.buttons["composer.video.retry"].exists, "a dropped connection is never handed to the person to retry")

        post(app, text: "Carried on")
        XCTAssertTrue(app.buttons["video.play"].firstMatch.waitForExistence(timeout: 30), "the video never became ready")
    }

    /// Post pressed while the video is still going up, then the app is
    /// switched away from, then quit altogether. The post waits above the
    /// feed, comes back after the relaunch, and appears once the video is
    /// there — without being picked or posted again.
    func testAPostWaitingForItsVideoSurvivesAnAppSwitchAndARelaunch() throws {
        // Filmed upright, as most phone videos are: its thumbnail must stay
        // inside the strip's card.
        let app = launch(pick: "portrait", scenario: "slow")
        openComposer(app)
        pickVideo(app)
        XCTAssertTrue(wait(status(app), contains: "Uploading", timeout: 20), "never started uploading: \(status(app).label)")

        post(app, text: "Waited for its video")

        let pending = app.descendants(matching: .any)["video.pending"].firstMatch
        XCTAssertTrue(pending.waitForExistence(timeout: 10), "the post waiting for its video is not shown")
        shot(app, "Feed — a post waiting for its video")

        // Switched away and back.
        XCUIDevice.shared.press(.home)
        sleep(2)
        app.activate()
        XCTAssertTrue(pending.waitForExistence(timeout: 10), "the waiting post went away with the app switch")

        // Quit, and opened again.
        app.terminate()
        let relaunched = launch(pick: "portrait", scenario: "slow", reset: false, app: XCUIApplication())
        let back = relaunched.descendants(matching: .any)["video.pending"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 15), "the waiting post did not come back after the relaunch")
        shot(relaunched, "After the relaunch — still waiting, resuming")

        // The strip goes when the post is written…
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: back)
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 90), .completed, "the upload never finished after the relaunch")
        // …and the post is the first in the feed, under the week's question
        // and the rooms live now: brought into view as a person would.
        relaunched.swipeUp()
        let posted = relaunched.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'video.status.processing' OR identifier == 'video.play'")).firstMatch
        XCTAssertTrue(posted.waitForExistence(timeout: 30), "the post never appeared once its video was there")
        XCTAssertTrue(relaunched.buttons["video.play"].firstMatch.waitForExistence(timeout: 30), "the video never became ready")
        shot(relaunched, "After the relaunch — posted and ready")
    }

    // MARK: - Over three minutes

    func testAVideoOverThreeMinutesIsRefusedWithAWayToTrimIt() throws {
        let app = launch(pick: "long")
        openComposer(app)
        pickVideo(app)

        let refusal = app.descendants(matching: .any)["composer.video.tooLong"].firstMatch
        XCTAssertTrue(refusal.waitForExistence(timeout: 30), "a video over three minutes was not refused on the phone")
        XCTAssertTrue(refusal.label.contains("longer than 3 minutes"), refusal.label)
        XCTAssertFalse(app.navigationBars.buttons["Post"].firstMatch.isEnabled, "nothing to post yet")
        shot(app, "Composer — over three minutes")

        app.buttons["composer.video.firstMinutes"].tap()
        XCTAssertTrue(wait(status(app), contains: "Uploaded", timeout: 60), "the first three minutes never went up: \(status(app).label)")
        XCTAssertFalse(refusal.exists)
    }
}
