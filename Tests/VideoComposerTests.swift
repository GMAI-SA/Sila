import AVFoundation
import XCTest
@testable import Sila

/// The composer's side of video posts (contract v28 §5, §12).
@MainActor
final class VideoComposerTests: XCTestCase {

    private var directory: URL!

    override func setUp() async throws {
        try await super.setUp()
        directory = VideoFixtures.directory("composer")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
        L10n.use(nil)
        try await super.tearDown()
    }

    private struct Harness {
        let viewModel: ComposerViewModel
        let center: VideoUploadCenter
        let composer: ScriptedComposerService
        let preparer: FakeVideoPreparer
        let service: VideoServiceMock
        let analytics: RecordingAnalyticsClient
        let posted: PostedBox
        let closed: PostedBox
    }

    final class PostedBox {
        var posts: [Post] = []
        var count = 0
    }

    private func harness(
        context: ComposerContext = .newPost,
        offersVideo: Bool = true,
        duration: Double = 12,
        latency: TimeInterval = 0
    ) -> Harness {
        let service = VideoServiceMock(directory: directory.appendingPathComponent("server"), pieceLatency: latency,
                                       readyAfterReads: 1, pieceSize: 1024)
        let composer = ScriptedComposerService()
        let preparer = FakeVideoPreparer()
        preparer.durationSeconds = duration
        let analytics = RecordingAnalyticsClient()
        let center = VideoUploadCenter(service: service, preparer: preparer, composer: composer,
                                       store: VideoUploadStore(directory: directory.appendingPathComponent("store")),
                                       analytics: analytics,
                                       sleep: { _ in try await Task.sleep(nanoseconds: 1_000_000) })
        center.restore(accountId: UUID())
        let posted = PostedBox()
        let closed = PostedBox()
        let viewModel = ComposerViewModel(
            context: context,
            author: ComposerAuthor(handle: "aziz", countryCode: "SA", isVerified: true),
            composer: composer,
            analytics: analytics,
            mentionDebounce: 0,
            videoUploads: offersVideo ? center : nil,
            onPosted: { posted.posts += $0 },
            onClose: { closed.count += 1 }
        )
        return Harness(viewModel: viewModel, center: center, composer: composer, preparer: preparer, service: service,
                       analytics: analytics, posted: posted, closed: closed)
    }

    private func pick(_ harness: Harness, bytes: Int = 3_000) async throws {
        await harness.viewModel.attachVideo(from: try VideoFixtures.file(bytes: bytes, in: directory))
    }

    private func waitUntilUploaded(_ harness: Harness) async throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if case .uploaded? = harness.viewModel.videoPhase { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("the video never finished uploading: \(String(describing: harness.viewModel.videoPhase))")
    }

    // MARK: - Where video is offered

    func testVideoIsOfferedOnlyWhenTheServerLetsThisAccountUploadOne() {
        XCTAssertTrue(harness().viewModel.canAddVideo)
        XCTAssertFalse(harness(offersVideo: false).viewModel.canAddVideo, "features.video_upload false: no picker")
        XCTAssertFalse(harness(context: .reply(to: FeedServiceMock.internationalRoot)).viewModel.canAddVideo,
                       "a reply comes from the one-line bar")
        XCTAssertTrue(harness(context: .quote(FeedServiceMock.internationalRoot)).viewModel.canAddVideo)
    }

    func testAVideoTravelsAlone() async throws {
        let h = harness()
        await h.viewModel.attach(Data([1, 2, 3]))
        XCTAssertFalse(h.viewModel.canAddVideo, "not beside pictures")
        h.viewModel.removeAttachment(at: 0)
        h.viewModel.addPoll()
        XCTAssertFalse(h.viewModel.canAddVideo, "not beside a poll")
        h.viewModel.removePoll()

        try await pick(h)
        XCTAssertTrue(h.viewModel.hasVideo)
        XCTAssertFalse(h.viewModel.allowsMedia, "no pictures or GIF beside a video")
        XCTAssertFalse(h.viewModel.canAddPoll)
        XCTAssertFalse(h.viewModel.allowsThread, "a video post is one post")
        XCTAssertFalse(h.viewModel.canAddVideo, "one video per post")
        XCTAssertTrue(h.viewModel.hasContent, "a draft with a video asks before it is thrown away")
    }

    // MARK: - Over three minutes

    func testAVideoOverThreeMinutesIsRefusedBeforeAByteIsSentWithAWayToTrimIt() async throws {
        XCTAssertTrue(L10n.use("en"))
        let h = harness(duration: 190)
        try await pick(h)

        XCTAssertNil(h.viewModel.videoJobId, "nothing uploaded")
        XCTAssertEqual(h.viewModel.videoRefusal?.message, "This video is longer than 3 minutes. Trim it and try again.")
        XCTAssertEqual(h.viewModel.videoRefusal?.durationSeconds, 190)
        XCTAssertFalse(h.viewModel.canPost)
        XCTAssertTrue(h.analytics.recorded.contains { $0.event == .videoPicked && $0.properties["result"] == "too_long" })
        let calls = await h.service.calls
        XCTAssertFalse(calls.contains("start"), "refused on the phone, not by the server")

        h.viewModel.trimRefusedVideo()
        XCTAssertNotNil(h.viewModel.trimSource, "the trimming screen opens on it")

        // The screen hands back three minutes.
        h.preparer.durationSeconds = 180
        await h.viewModel.trimmed(try VideoFixtures.file(bytes: 2_000, in: directory))
        XCTAssertNil(h.viewModel.videoRefusal)
        XCTAssertNil(h.viewModel.trimSource)
        XCTAssertNotNil(h.viewModel.videoJobId, "the trimmed video goes up")
    }

    /// Three minutes and a few seconds of padding is never refused.
    func testThreeMinutesAndTheirPaddingAreNotRefused() async throws {
        let h = harness(duration: 184.9)
        try await pick(h)
        XCTAssertNil(h.viewModel.videoRefusal)
        XCTAssertNotNil(h.viewModel.videoJobId)
    }

    func testTheFirstThreeMinutesCanBeKeptInstead() async throws {
        let h = harness(duration: 400)
        try await pick(h)
        XCTAssertNotNil(h.viewModel.videoRefusal)
        await h.viewModel.useFirstMinutes()
        XCTAssertEqual(h.preparer.trimmedTo, [VideoLimits.trimDuration])
        XCTAssertNil(h.viewModel.videoRefusal)
        XCTAssertNotNil(h.viewModel.videoJobId)
    }

    func testAFileThatIsNotAVideoIsSaidPlainly() async throws {
        XCTAssertTrue(L10n.use("en"))
        let h = harness()
        h.preparer.inspectFailure = VideoPreparationError.unreadable
        try await pick(h)
        XCTAssertNil(h.viewModel.videoJobId)
        XCTAssertEqual(h.viewModel.toast?.text, "We couldn't read this video. Export it again or choose another one.")
    }

    // MARK: - Posting

    /// Post while it is still going up: handed over, and the sheet closes.
    func testPostingWhileUploadingHandsThePostOverAndCloses() async throws {
        let h = harness(latency: 0.2)
        try await pick(h, bytes: 8_000)
        h.viewModel.setText("Riyadh at night", at: 0)
        XCTAssertTrue(h.viewModel.canPost, "a video still going up can be posted")

        await h.viewModel.post()

        XCTAssertEqual(h.closed.count, 1, "the composer closes at once")
        XCTAssertTrue(h.composer.drafts.isEmpty, "nothing is written before the video is there")
        XCTAssertEqual(h.center.pendingPosts.first?.pendingPost?.text, "Riyadh at night")
        XCTAssertNil(h.viewModel.videoJobId, "the job now belongs to the feed's strip")

        var posted: [Post] = []
        h.center.onPosted = { posted += $0 }
        let deadline = Date().addingTimeInterval(8)
        while posted.isEmpty, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(posted.count, 1)
        XCTAssertEqual(h.composer.drafts.first?.text, "Riyadh at night")
        XCTAssertNotNil(h.composer.drafts.first?.videoId)
    }

    /// Uploaded already: posted from the composer like any post, the video
    /// on it, and the feed told.
    func testPostingAnUploadedVideoWritesItNow() async throws {
        let h = harness()
        try await pick(h)
        try await waitUntilUploaded(h)
        guard case let .uploaded(video)? = h.viewModel.videoPhase else { return XCTFail() }

        await h.viewModel.post()

        XCTAssertEqual(h.composer.drafts.count, 1)
        XCTAssertEqual(h.composer.drafts.first?.videoId, video.id)
        XCTAssertEqual(h.composer.drafts.first?.trimmedText, "", "no words needed beside a video")
        XCTAssertEqual(h.posted.posts.first?.video?.id, video.id, "the author's copy shows the video preparing")
        XCTAssertEqual(h.closed.count, 1)
        XCTAssertTrue(h.center.jobs.isEmpty, "nothing left to do")
        XCTAssertTrue(h.analytics.recorded.contains { $0.event == .postPublished && $0.properties["kind"] == "video" })
    }

    func testARefusedVideoCannotBePostedButCanBeTriedAgainOrRemoved() async throws {
        let h = harness()
        await h.service.setScenario(.offline)
        try await pick(h)
        // Offline is never a refusal: it waits.
        try await Task.sleep(nanoseconds: 100_000_000)
        if case .failed? = h.viewModel.videoPhase { XCTFail("no connection is waited out, not refused") }

        await h.service.setScenario(.notAllowed)
        h.viewModel.removeVideo()
        try await pick(h)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if case .failed? = h.viewModel.videoPhase { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        guard case let .failed(failure)? = h.viewModel.videoPhase else { return XCTFail() }
        XCTAssertFalse(failure.canRetry)
        XCTAssertFalse(h.viewModel.canPost)
        h.viewModel.removeVideo()
        XCTAssertFalse(h.viewModel.hasVideo)
        XCTAssertTrue(h.viewModel.canAddVideo)
    }

    /// Post pressed on an uploaded video, and the answer lost on its way
    /// back. Pressed again, the server says the video is on a post already:
    /// the one the first press wrote. The composer closes and the feed shows
    /// that post, rather than "That video is already on a post."
    func testPostingAgainAfterALostAnswerShowsThePostThatWasWritten() async throws {
        let service = VideoServiceMock(directory: directory.appendingPathComponent("server"), pieceLatency: 0,
                                       readyAfterReads: 1, pieceSize: 1024)
        let composer = CommittingComposerService(videos: service)
        composer.loseAnswers = 1
        let center = VideoUploadCenter(service: service, preparer: FakeVideoPreparer(), composer: composer,
                                       store: VideoUploadStore(directory: directory.appendingPathComponent("store")),
                                       analytics: RecordingAnalyticsClient(),
                                       fetchPost: { try composer.post($0) }, isActive: { true }, sleep: { _ in })
        center.restore(accountId: UUID())
        var feed: [Post] = []
        center.onPosted = { feed += $0 }
        let closed = PostedBox()
        let viewModel = ComposerViewModel(
            context: .newPost,
            author: ComposerAuthor(handle: "aziz", countryCode: "SA", isVerified: true),
            composer: composer,
            analytics: RecordingAnalyticsClient(),
            mentionDebounce: 0,
            videoUploads: center,
            onPosted: { feed += $0 },
            onClose: { closed.count += 1 }
        )
        await viewModel.attachVideo(from: try VideoFixtures.file(bytes: 3_000, in: directory))
        let uploaded = Date().addingTimeInterval(5)
        while Date() < uploaded {
            if case .uploaded? = viewModel.videoPhase { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        viewModel.setText("Sent from the lift", at: 0)

        await viewModel.post()
        XCTAssertEqual(closed.count, 0, "a lost answer keeps the composer open")
        XCTAssertEqual(composer.written.count, 1, "but the post was written")

        await viewModel.post()
        XCTAssertEqual(closed.count, 1, "the second press closes it")
        let deadline = Date().addingTimeInterval(5)
        while feed.isEmpty, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }

        XCTAssertEqual(feed.map(\.id), composer.written.map(\.id), "the post the first press wrote, once")
        XCTAssertEqual(composer.written.count, 1)
        XCTAssertTrue(center.jobs.isEmpty)
    }

    func testDiscardingTheDraftTakesTheVideoWithIt() async throws {
        let h = harness()
        try await pick(h)
        XCTAssertEqual(h.center.jobs.count, 1)
        h.viewModel.requestDismiss()
        h.viewModel.confirmDiscard()
        XCTAssertTrue(h.center.jobs.isEmpty)
        XCTAssertEqual(h.closed.count, 1)
    }
}

/// The player's own state, without a stream behind it.
@MainActor
final class VideoPlaybackModelTests: XCTestCase {

    override func tearDown() {
        VideoPlaybackModel.preferredCaptionLanguage = nil
        super.tearDown()
    }

    private func video(captions: [String] = ["ar", "en"]) -> PostVideo {
        PostVideo(
            id: UUID(), status: .ready, hlsURL: nil, durationSeconds: 10,
            captions: captions.map { VideoCaptionTrack(language: $0, url: URL(string: "https://x/captions-\($0).vtt")!) }
        )
    }

    func testCaptionsAreFetchedOnceAndRemembered() async {
        let fetched = ActivityLog()
        let model = VideoPlaybackModel(video: video(), fetchCaptions: { url in
            fetched.slept(1)
            return url.lastPathComponent.contains("ar")
                ? "WEBVTT\n\n00:00:00.000 --> 00:00:05.000\nمرحبًا\n"
                : "WEBVTT\n\n00:00:00.000 --> 00:00:05.000\nHello\n"
        })
        XCTAssertNil(model.captionLanguage, "off unless chosen")

        await model.selectCaptions("ar")
        XCTAssertEqual(model.caption, "مرحبًا")
        await model.selectCaptions("en")
        XCTAssertEqual(model.caption, "Hello")
        await model.selectCaptions("ar")
        XCTAssertEqual(fetched.waits.count, 2, "each track is fetched once")
        await model.selectCaptions(nil)
        XCTAssertNil(model.caption)

        await model.selectCaptions("en")
        let next = VideoPlaybackModel(video: video(), fetchCaptions: { _ in "" })
        XCTAssertEqual(next.captionLanguage, "en", "the next video opens with the captions chosen last")
        let noEnglish = VideoPlaybackModel(video: video(captions: ["ar"]), fetchCaptions: { _ in "" })
        XCTAssertNil(noEnglish.captionLanguage, "unless it has none in that language")
    }

    func testAVideoWithNoStreamNeverPlays() {
        let model = VideoPlaybackModel(video: video(), fetchCaptions: { _ in "" })
        model.play(muted: true, autoplay: true)
        XCTAssertFalse(model.isPlaying)
        XCTAssertFalse(model.hasStarted)
        XCTAssertNil(model.player)
    }

    func testACaptionThatCannotBeFetchedShowsNothing() async {
        let model = VideoPlaybackModel(video: video(), fetchCaptions: { _ in throw APIError.transport("offline") })
        await model.selectCaptions("ar")
        XCTAssertNil(model.caption)
        XCTAssertEqual(model.captionLanguage, "ar")
    }
}

/// The phone's own side of a video, with AVFoundation for real: the samples
/// the journeys pick, measured, compressed and trimmed as a picked video is.
final class VideoPreparationTests: XCTestCase {

    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = VideoFixtures.directory("prepare")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func testAShortSampleIsMeasuredAndSentAsItIs() async throws {
        let sample = try await SampleVideoFactory.make(.short, in: directory)
        let preparer = AVVideoPreparer()
        let info = try await preparer.inspect(sample)
        XCTAssertEqual(info.durationSeconds, 3, accuracy: 0.2)
        XCTAssertEqual(info.width, 320)
        XCTAssertEqual(info.height, 240)
        XCTAssertFalse(info.isTooLong)

        let prepared = try await preparer.prepare(sample, to: directory.appendingPathComponent("up.mp4")) { _ in }
        XCTAssertEqual(prepared.sizeBytes, AVVideoPreparer.fileSize(sample),
                       "a small H.264 file is sent as it is: re-encoding it would only cost time and quality")
        let thumbnail = await preparer.thumbnail(sample)
        XCTAssertNotNil(thumbnail.flatMap(UIImage.init(data:)))
    }

    func testALargeSampleIsCompressedToAbout720p() async throws {
        let sample = try await SampleVideoFactory.make(.big, in: directory)
        let preparer = AVVideoPreparer()
        let prepared = try await preparer.prepare(sample, to: directory.appendingPathComponent("up.mp4")) { _ in }
        XCTAssertLessThanOrEqual(max(prepared.width, prepared.height), 1280)
        XCTAssertLessThan(prepared.sizeBytes, AVVideoPreparer.fileSize(sample), "a 20 Mbit/s source comes out smaller")
        XCTAssertEqual(prepared.durationSeconds, 5, accuracy: 0.3)
    }

    func testALongSampleIsTooLongAndItsFirstThreeMinutesAreNot() async throws {
        let sample = try await SampleVideoFactory.make(.long, in: directory)
        let preparer = AVVideoPreparer()
        let info = try await preparer.inspect(sample)
        XCTAssertEqual(info.durationSeconds, 190, accuracy: 1)
        XCTAssertTrue(info.isTooLong)

        let trimmed = try await preparer.trim(sample, to: directory.appendingPathComponent("trim.mp4"),
                                              seconds: VideoLimits.trimDuration)
        let after = try await preparer.inspect(trimmed)
        XCTAssertLessThanOrEqual(after.durationSeconds, VideoLimits.maximumDuration)
        XCTAssertEqual(after.durationSeconds, 180, accuracy: 2)
    }

    /// An export that did not complete: only the person's own cancelling is
    /// a cancellation, and only a failure on screen with no sign of an
    /// interruption says the file is at fault. Anything else — iOS taking
    /// back its time, the app in the background, the media services
    /// restarting — is compressed again.
    func testAnExportStoppedByAnythingButThePersonIsCompressedAgain() {
        func reading(_ status: AVAssetExportSession.Status, _ error: Error? = nil,
                     cancelled: Bool = false, away: Bool = false) -> Error? {
            AVVideoPreparer.failure(status: status, error: error, cancelledByCaller: cancelled, wentToBackground: away)
        }
        func av(_ code: AVError.Code, underlying: NSError? = nil) -> NSError {
            NSError(domain: AVFoundationErrorDomain, code: code.rawValue,
                    userInfo: underlying.map { [NSUnderlyingErrorKey: $0] } ?? [:])
        }
        XCTAssertNil(reading(.completed, away: true))
        XCTAssertTrue(reading(.cancelled, cancelled: true) is CancellationError, "the person took the video off")
        XCTAssertTrue(reading(.failed, av(.unknown), cancelled: true) is CancellationError)
        XCTAssertEqual(reading(.cancelled, away: true) as? VideoPreparationError, .interrupted, "iOS took its time back")
        XCTAssertEqual(reading(.cancelled) as? VideoPreparationError, .interrupted)
        XCTAssertEqual(reading(.failed, av(.operationInterrupted)) as? VideoPreparationError, .interrupted)
        XCTAssertEqual(reading(.failed, av(.mediaServicesWereReset)) as? VideoPreparationError, .interrupted)
        let encoderTaken = av(.unknown, underlying: NSError(domain: NSOSStatusErrorDomain, code: AVVideoPreparer.encoderSessionInvalid))
        XCTAssertEqual(reading(.failed, encoderTaken) as? VideoPreparationError, .interrupted,
                       "the hardware encoder taken from an app in the background")
        XCTAssertEqual(reading(.failed, av(.decodeFailed), away: true) as? VideoPreparationError, .interrupted,
                       "whatever it says, a failure in the background is tried again on screen")
        XCTAssertEqual(reading(.failed, av(.decodeFailed)) as? VideoPreparationError, .unreadable,
                       "on screen, with no sign of an interruption, the file is at fault")
        XCTAssertEqual(reading(.failed) as? VideoPreparationError, .unreadable)
    }

    /// The time iOS lends is asked for and handed back, and a trip to the
    /// background while it is held is noted.
    @MainActor
    func testTheBackgroundTimeNotesATripAway() {
        let away = VideoBackgroundTime.begin("A test")
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        XCTAssertTrue(away.finish())
        XCTAssertTrue(away.finish(), "safe to finish twice")

        let stayed = VideoBackgroundTime.begin("A test")
        if UIApplication.shared.applicationState != .background {
            XCTAssertFalse(stayed.finish(), "never away")
        }
        stayed.finish()
    }

    func testSomethingThatIsNotAVideoIsUnreadable() async throws {
        let file = directory.appendingPathComponent("notes.mp4")
        try Data("not a video".utf8).write(to: file)
        do {
            _ = try await AVVideoPreparer().inspect(file)
            XCTFail("text is not a video")
        } catch {
            XCTAssertEqual(error as? VideoPreparationError, .unreadable)
        }
    }
}
