import XCTest
@testable import Sila

/// Uploads outliving the composer (contract v28 §3.1, §12): kept on disk,
/// resumed after a relaunch, posted once the video is there, and nothing of
/// an account's left behind at sign-out.
@MainActor
final class VideoUploadCenterTests: XCTestCase {

    private var directory: URL!
    private let account = UUID()

    override func setUp() async throws {
        try await super.setUp()
        directory = VideoFixtures.directory("center")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
        L10n.use(nil)
        try await super.tearDown()
    }

    private func mock(_ scenario: VideoServiceMock.MockScenario = .success, latency: TimeInterval = 0) -> VideoServiceMock {
        VideoServiceMock(scenario: scenario, directory: directory.appendingPathComponent("server"),
                         pieceLatency: latency, readyAfterReads: 1, pieceSize: 1024)
    }

    private func center(
        _ service: VideoServiceProtocol,
        composer: ComposerServiceProtocol = ScriptedComposerService(),
        preparer: FakeVideoPreparer = FakeVideoPreparer(),
        analytics: AnalyticsClient = RecordingAnalyticsClient(),
        fetchPost: (@Sendable (UUID) async throws -> Post)? = nil,
        isActive: @escaping @MainActor () -> Bool = { true }
    ) -> VideoUploadCenter {
        let center = VideoUploadCenter(
            service: service,
            preparer: preparer,
            composer: composer,
            store: VideoUploadStore(directory: directory.appendingPathComponent("store")),
            analytics: analytics,
            fetchPost: fetchPost,
            isActive: isActive,
            sleep: { _ in }
        )
        center.restore(accountId: account)
        return center
    }

    private func source(bytes: Int = 3_000) throws -> URL {
        try VideoFixtures.file(bytes: bytes, in: directory)
    }

    /// Waits for the center to settle on a phase.
    private func until(
        _ center: VideoUploadCenter,
        _ id: UUID,
        timeout: TimeInterval = 5,
        _ matches: (VideoUploadPhase?) -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !matches(center.phase(id)) {
            guard Date() < deadline else {
                return XCTFail("still \(String(describing: center.phase(id)))")
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func isUploaded(_ phase: VideoUploadPhase?) -> Bool {
        if case .uploaded? = phase { return true }
        return false
    }

    private func isFailed(_ phase: VideoUploadPhase?) -> Bool {
        if case .failed? = phase { return true }
        return false
    }

    /// Waits for `condition`, noting every phase `id` goes through.
    private func until(
        _ center: VideoUploadCenter,
        watching id: UUID,
        timeout: TimeInterval = 8,
        _ condition: () -> Bool
    ) async throws -> [VideoUploadPhase] {
        var seen: [VideoUploadPhase] = []
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if let phase = center.phase(id), seen.last != phase { seen.append(phase) }
            guard Date() < deadline else {
                XCTFail("timed out; went through \(seen)")
                return seen
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        return seen
    }

    /// A video uploaded to the mocked server and completed, as a job that
    /// got that far keeps it.
    private func completedVideo(_ service: VideoServiceMock, file: URL, bytes: Int) async throws -> PostVideo {
        try await VideoUploader(service: service, workDirectory: directory.appendingPathComponent("elsewhere"), sleep: { _ in })
            .upload(file: file, sizeBytes: bytes, durationSeconds: 12, resumeFrom: nil,
                    onCheckpoint: { _ in }, onActivity: { _ in })
    }

    // MARK: - While the composer is open

    func testAPickedVideoIsPreparedAndUploadedAtOnce() async throws {
        let service = mock()
        let preparer = FakeVideoPreparer()
        let center = center(service, preparer: preparer)
        let file = try source()
        let original = try Data(contentsOf: file)

        let info = try await preparer.inspect(file)
        let id = try XCTUnwrap(center.begin(source: file, info: info))
        try await until(center, id, isUploaded)

        guard case let .uploaded(video)? = center.phase(id) else { return XCTFail() }
        XCTAssertEqual(video.status, .processing)
        XCTAssertEqual(try Data(contentsOf: service.storedFile(video.id)), original)
        XCTAssertEqual(preparer.prepared.count, 1, "compressed on the phone first")
        let job = try XCTUnwrap(center.job(id))
        XCTAssertEqual(job.uploadedVideoId, video.id)
        XCTAssertNil(job.checkpoint, "a complete upload has no plan to keep")
        XCTAssertNil(job.sourceFileName, "the picked file goes once it is prepared")
        XCTAssertNotNil(center.thumbnail(id))
        XCTAssertTrue(center.pendingPosts.isEmpty, "nothing is posted until somebody presses Post")
    }

    /// Post pressed while the video is still going up: the composer closes,
    /// and the post is written — once — when the video is there.
    func testAPostPressedWhileUploadingIsWrittenWhenTheVideoArrives() async throws {
        let service = mock(latency: 0.05)
        let composer = ScriptedComposerService()
        let center = center(service, composer: composer)
        var posted: [Post] = []
        center.onPosted = { posted += $0 }
        let file = try source(bytes: 6_000)

        let info = try await FakeVideoPreparer().inspect(file)
        let id = try XCTUnwrap(center.begin(source: file, info: info))
        center.post(id, PendingVideoPost(text: "Riyadh at night", scope: .country("SA"), sensitive: .spoiler, sensitiveNote: "ending"))
        XCTAssertEqual(center.pendingPosts.map(\.id), [id], "the feed shows it waiting")

        let deadline = Date().addingTimeInterval(5)
        while posted.isEmpty, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }

        XCTAssertEqual(posted.count, 1)
        let draft = try XCTUnwrap(composer.drafts.first)
        XCTAssertEqual(composer.drafts.count, 1, "written once")
        XCTAssertEqual(draft.text, "Riyadh at night")
        XCTAssertEqual(draft.scope, .country("SA"))
        XCTAssertEqual(draft.sensitive, .spoiler)
        XCTAssertEqual(draft.sensitiveNote, "ending")
        XCTAssertEqual(draft.videoId, posted.first?.video?.id)
        XCTAssertEqual(posted.first?.video?.status, .processing, "the author sees it preparing")
        XCTAssertNil(center.job(id), "done: nothing kept")
        XCTAssertTrue(center.pendingPosts.isEmpty)
    }

    func testAPostPressedAfterTheUploadIsWrittenAtOnce() async throws {
        let service = mock()
        let composer = ScriptedComposerService()
        let center = center(service, composer: composer)
        var posted: [Post] = []
        center.onPosted = { posted += $0 }
        let file = try source()
        let info = try await FakeVideoPreparer().inspect(file)
        let id = try XCTUnwrap(center.begin(source: file, info: info))
        try await until(center, id, isUploaded)

        center.post(id, PendingVideoPost(text: "", scope: .international))
        let deadline = Date().addingTimeInterval(5)
        while posted.isEmpty, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(posted.count, 1)
        XCTAssertEqual(composer.drafts.first?.trimmedText, "", "a video stands alone")
    }

    // MARK: - A relaunch

    /// The app was killed half way through: the job is on disk with its plan
    /// and its post, and the next launch finishes both — sending only what
    /// the server does not have.
    func testARelaunchResumesTheUploadAndWritesThePost() async throws {
        let service = mock()
        let file = try source(bytes: 4_096)
        let store = VideoUploadStore(directory: directory.appendingPathComponent("store"))
        let prepared = try store.adopt(file, as: "job.mp4")
        let start = try await service.startUpload(sizeBytes: 4_096, durationSeconds: 12, contentType: "video/mp4")
        let piece = directory.appendingPathComponent("first")
        try Data(try Data(contentsOf: prepared)[0..<1024]).write(to: piece)
        try await service.sendChunk(start.upload, number: 1, file: piece, progress: { _ in })
        store.save([VideoUploadJob(
            accountId: account, sourceFileName: nil, fileName: "job.mp4", sizeBytes: 4_096, durationSeconds: 12,
            width: 720, height: 1280, checkpoint: VideoUploadCheckpoint(plan: start.upload, videoId: start.video.id),
            pendingPost: PendingVideoPost(text: "after a relaunch", scope: .international)
        )])

        let composer = ScriptedComposerService()
        let relaunched = center(service, composer: composer)
        var posted: [Post] = []
        relaunched.onPosted = { posted += $0 }
        XCTAssertEqual(relaunched.pendingPosts.count, 1, "the waiting post is back")

        let deadline = Date().addingTimeInterval(5)
        while posted.isEmpty, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }

        XCTAssertEqual(posted.first?.video?.id, start.video.id, "the same upload, finished")
        XCTAssertEqual(composer.drafts.first?.text, "after a relaunch")
        let calls = await service.calls
        XCTAssertEqual(calls.filter { $0 == "start" }.count, 1, "no new plan")
        XCTAssertEqual(calls.filter { $0.hasPrefix("chunk") }.sorted(), ["chunk 1", "chunk 2", "chunk 3", "chunk 4"],
                       "chunk 1 was not sent again")
        XCTAssertTrue(store.load().isEmpty)
    }

    /// A draft's video with no post waiting belonged to a composer that is
    /// gone: it is let go, here and on the server. Another account's jobs are
    /// never resumed.
    func testARelaunchLetsGoOfDraftsAndOtherAccounts() async throws {
        let service = mock()
        let store = VideoUploadStore(directory: directory.appendingPathComponent("store"))
        let draftVideo = try await service.startUpload(sizeBytes: 10, durationSeconds: 3, contentType: "video/mp4").video.id
        store.write(Data([1, 2, 3]), as: "draft.mp4")
        store.write(Data([4, 5, 6]), as: "other.mp4")
        store.save([
            VideoUploadJob(accountId: account, sourceFileName: nil, fileName: "draft.mp4", sizeBytes: 3, durationSeconds: 3,
                           width: 1, height: 1, uploadedVideoId: draftVideo),
            VideoUploadJob(accountId: UUID(), sourceFileName: nil, fileName: "other.mp4", sizeBytes: 3, durationSeconds: 3,
                           width: 1, height: 1, pendingPost: PendingVideoPost(text: "not yours", scope: .international)),
        ])

        let relaunched = center(service)
        XCTAssertTrue(relaunched.jobs.isEmpty)
        XCTAssertTrue(store.load().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url(for: "draft.mp4").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url(for: "other.mp4").path), "another account's file goes too")
        try await Task.sleep(nanoseconds: 100_000_000)
        let calls = await service.calls
        XCTAssertTrue(calls.contains("discard"), "the abandoned draft is removed on the server")
    }

    // MARK: - Giving up, and signing out

    func testRemovingTheVideoStopsItAndDeletesItEverywhere() async throws {
        let service = mock()
        let center = center(service)
        let file = try source()
        let info = try await FakeVideoPreparer().inspect(file)
        let id = try XCTUnwrap(center.begin(source: file, info: info))
        try await until(center, id, isUploaded)
        guard case let .uploaded(video)? = center.phase(id) else { return XCTFail() }

        center.discard(id)

        XCTAssertNil(center.job(id))
        XCTAssertNil(center.phase(id))
        try await Task.sleep(nanoseconds: 100_000_000)
        let status = try await service.fetchVideo(video.id).status
        XCTAssertEqual(status, .removed, "the server removes every file of it")
        let left = (try? FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("store").path)) ?? []
        XCTAssertEqual(left.filter { $0.hasSuffix(".mp4") || $0.hasSuffix(".jpg") }, [])
    }

    func testSigningOutLeavesNothingOnThePhone() async throws {
        let service = mock(.slow, latency: 1.5)
        let center = center(service)
        let file = try source()
        let info = try await FakeVideoPreparer().inspect(file)
        let id = try XCTUnwrap(center.begin(source: file, info: info))
        center.post(id, PendingVideoPost(text: "x", scope: .international))

        center.forgetAll()

        XCTAssertTrue(center.jobs.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("store").path))
        center.restore(accountId: account)
        XCTAssertTrue(center.jobs.isEmpty, "nothing comes back for the next person either")
    }

    func testTheSessionSweepRemovesUploadsToo() throws {
        let uploads = directory.appendingPathComponent("uploads")
        try FileManager.default.createDirectory(at: uploads, withIntermediateDirectories: true)
        try Data([1]).write(to: uploads.appendingPathComponent("x.mp4"))
        SessionLeftovers(
            directory: directory,
            responseCache: URLCache(memoryCapacity: 1 << 20, diskCapacity: 0, diskPath: nil),
            videoUploads: uploads
        ).sweep()
        XCTAssertFalse(FileManager.default.fileExists(atPath: uploads.path))
    }

    // MARK: - Refusals

    func testARefusalStopsWithWordsAndNoRetry() async throws {
        let analytics = RecordingAnalyticsClient()
        let center = center(mock(.notAllowed), analytics: analytics)
        let file = try source()
        let info = try await FakeVideoPreparer().inspect(file)
        let id = try XCTUnwrap(center.begin(source: file, info: info))
        try await until(center, id) { if case .failed? = $0 { return true }; return false }
        guard case let .failed(failure)? = center.phase(id) else { return XCTFail() }
        XCTAssertFalse(failure.canRetry)
        XCTAssertEqual(failure.message, L10n.t("video.error.notVerified"))
        XCTAssertTrue(analytics.recorded.contains { $0.event == .videoUploadFailed && $0.properties["code"] == "video_not_allowed" })
    }

    func testAFileThePhoneCannotPrepareIsSaidPlainly() async throws {
        let preparer = FakeVideoPreparer()
        preparer.prepareFailure = VideoPreparationError.unreadable
        let center = center(mock(), preparer: preparer)
        let file = try source()
        let info = try await preparer.inspect(file)
        let id = try XCTUnwrap(center.begin(source: file, info: info))
        try await until(center, id) { if case .failed? = $0 { return true }; return false }
        guard case let .failed(failure)? = center.phase(id) else { return XCTFail() }
        XCTAssertEqual(failure.message, L10n.t("video.error.unreadable"))
    }

    func testAPostTheServerRefusesIsSaidOnThePendingCard() async throws {
        let composer = ScriptedComposerService()
        composer.failOnCall = 1
        composer.failure = .api(code: .videoNotAllowed, message: L10n.t("video.error.notAvailable"), status: 403)
        let center = center(mock(), composer: composer)
        let file = try source()
        let info = try await FakeVideoPreparer().inspect(file)
        let id = try XCTUnwrap(center.begin(source: file, info: info))
        center.post(id, PendingVideoPost(text: "x", scope: .international))
        try await until(center, id) { if case .failed? = $0 { return true }; return false }
        guard case let .failed(failure)? = center.phase(id) else { return XCTFail() }
        XCTAssertEqual(failure.message, L10n.t("video.error.notAvailable"))
        XCTAssertEqual(center.pendingPosts.count, 1, "kept, so it can be discarded or tried again")
    }

    // MARK: - An app switch while compressing

    /// Post pressed while the video is still being compressed, then the
    /// person switches to another app and iOS stops the export. Nothing is
    /// refused: the job waits, still getting ready, and starts again from
    /// the picked file when the app is back, and the post is written.
    func testCompressingStoppedInTheBackgroundStartsAgainWhenTheAppIsBack() async throws {
        let service = mock()
        let composer = ScriptedComposerService()
        let preparer = FakeVideoPreparer()
        preparer.prepareFailures = [VideoPreparationError.interrupted]
        let screen = Screen()
        screen.active = false
        let center = center(service, composer: composer, preparer: preparer, isActive: { screen.active })
        var posted: [Post] = []
        center.onPosted = { posted += $0 }
        let file = try source()
        let info = try await preparer.inspect(file)

        let id = try XCTUnwrap(center.begin(source: file, info: info))
        center.post(id, PendingVideoPost(text: "Posted, then off to another app", scope: .international))
        _ = try await until(center, watching: id) { preparer.attempts == 1 }
        try await Task.sleep(nanoseconds: 100_000_000)

        guard case .preparing? = center.phase(id) else {
            return XCTFail("an export iOS stopped is not the person's failure: \(String(describing: center.phase(id)))")
        }
        XCTAssertEqual(center.pendingPosts.map(\.id), [id], "the post still waits above the feed")
        XCTAssertNotNil(center.job(id)?.sourceFileName, "the picked file is kept to compress again")
        let early = await service.calls
        XCTAssertFalse(early.contains("start"), "nothing is sent before it is compressed")

        screen.active = true
        center.sceneDidBecomeActive()
        let seen = try await until(center, watching: id) { !posted.isEmpty }

        XCTAssertFalse(seen.contains { isFailed($0) }, "never shown as failed: \(seen)")
        XCTAssertEqual(preparer.attempts, 2, "compressed again once the app was back")
        XCTAssertEqual(composer.drafts.map(\.text), ["Posted, then off to another app"])
        XCTAssertNil(center.job(id))
    }

    /// Stopped with the app on screen — the media services restarted — it
    /// starts again at once, by itself. Only when that keeps happening is
    /// the person told, with Retry beside the words.
    func testCompressingStoppedOnScreenStartsAgainAtOnceAndOnlyThenOffersRetry() async throws {
        let preparer = FakeVideoPreparer()
        preparer.prepareFailures = [VideoPreparationError.interrupted]
        let first = center(mock(), preparer: preparer)
        let file = try source()
        let info = try await preparer.inspect(file)
        let once = try XCTUnwrap(first.begin(source: file, info: info))
        let seen = try await until(first, watching: once) { isUploaded(first.phase(once)) }
        XCTAssertFalse(seen.contains { isFailed($0) }, "one stop is never seen: \(seen)")
        XCTAssertEqual(preparer.attempts, 2)

        let stubborn = FakeVideoPreparer()
        stubborn.prepareFailures = Array(repeating: VideoPreparationError.interrupted,
                                         count: VideoUploadCenter.maximumInterruptionsOnScreen + 1)
        let second = center(mock(), preparer: stubborn)
        let again = try XCTUnwrap(second.begin(source: try source(), info: info))
        try await until(second, again) { isFailed($0) }
        guard case let .failed(failure)? = second.phase(again) else { return XCTFail() }
        XCTAssertTrue(failure.canRetry, "Retry is offered")
        XCTAssertEqual(failure.message, L10n.t("video.error.prepareInterrupted"))
        XCTAssertEqual(stubborn.attempts, VideoUploadCenter.maximumInterruptionsOnScreen + 1)

        second.retry(again)
        try await until(second, again, isUploaded)
        XCTAssertEqual(stubborn.attempts, VideoUploadCenter.maximumInterruptionsOnScreen + 2)
    }

    func testAStoppedCompressionIsSaidInEachLanguageAndATrueFailureStaysFinal() {
        XCTAssertTrue(L10n.use("en"))
        let english = VideoUploadCenter.failure(for: VideoPreparationError.interrupted)
        XCTAssertTrue(english.canRetry)
        XCTAssertEqual(english.message, "We couldn't finish getting this video ready. Try again.")
        XCTAssertFalse(VideoUploadCenter.failure(for: VideoPreparationError.unreadable).canRetry,
                       "a file that cannot be read is still said to be one, with no Retry")
        guard L10n.use("ar") else { return XCTFail("the build has no Arabic resources") }
        let arabic = VideoUploadCenter.failure(for: VideoPreparationError.interrupted).message
        XCTAssertEqual(arabic, "تعذّر إكمال تجهيز هذا الفيديو. حاول مرة أخرى.")
        XCTAssertNil(arabic.range(of: "[A-Za-z]", options: .regularExpression), "Arabic only: \(arabic)")
    }

    // MARK: - A post whose answer never arrived

    /// Post pressed, the video goes up, and the post is written — but its
    /// answer is lost in a lift. The next try is told the video is on a post
    /// already: that post is this one, so it is shown, once, not refused.
    func testAPostWrittenWhoseAnswerWasLostIsShownNotRefused() async throws {
        let service = mock()
        let composer = CommittingComposerService(videos: service)
        composer.loseAnswers = 1
        let center = center(service, composer: composer, fetchPost: { try composer.post($0) })
        var posted: [Post] = []
        center.onPosted = { posted += $0 }
        let file = try source()
        let info = try await FakeVideoPreparer().inspect(file)

        let id = try XCTUnwrap(center.begin(source: file, info: info))
        center.post(id, PendingVideoPost(text: "Written in the lift", scope: .international))
        let seen = try await until(center, watching: id) { !posted.isEmpty }

        XCTAssertFalse(seen.contains { isFailed($0) }, "\(seen)")
        XCTAssertEqual(composer.written.count, 1, "written once")
        XCTAssertEqual(composer.drafts.count, 2, "the second try found it written")
        XCTAssertEqual(posted.map(\.id), composer.written.map(\.id), "the feed shows the post the server has")
        XCTAssertEqual(posted.first?.video?.id, composer.written.first?.video?.id)
        XCTAssertNil(center.job(id))
        XCTAssertTrue(center.pendingPosts.isEmpty)
    }

    /// The app was killed straight after the post was written, before it
    /// could let go of the job. The relaunch finds the post rather than
    /// failing on it at every launch.
    func testARelaunchAfterThePostWasWrittenShowsThatPostOnce() async throws {
        let service = mock()
        let composer = CommittingComposerService(videos: service)
        let file = try source(bytes: 2_048)
        let video = try await completedVideo(service, file: file, bytes: 2_048)
        let pending = PendingVideoPost(text: "Written before the kill", scope: .international)
        let written = try await composer.createPost(pending.draft(videoId: video.id))
        let store = VideoUploadStore(directory: directory.appendingPathComponent("store"))
        _ = try store.adopt(file, as: "job.mp4")
        store.save([VideoUploadJob(accountId: account, sourceFileName: nil, fileName: "job.mp4", sizeBytes: 2_048,
                                   durationSeconds: 12, width: 720, height: 1280, uploadedVideoId: video.id,
                                   pendingPost: pending)])

        let relaunched = center(service, composer: composer, fetchPost: { try composer.post($0) })
        var posted: [Post] = []
        relaunched.onPosted = { posted += $0 }
        let deadline = Date().addingTimeInterval(5)
        while !relaunched.jobs.isEmpty, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }

        XCTAssertEqual(posted.map(\.id), [written.id])
        XCTAssertEqual(composer.written.count, 1, "not written a second time")
        XCTAssertTrue(store.load().isEmpty, "nothing is left to fail at the next launch")
    }

    /// The upload finished in a background wake, and the app was suspended
    /// before the post was written — for more than a day, so the server let
    /// the unposted video go. The file is still on the phone: it goes up
    /// again without a word, and the post is written.
    func testAVideoTheServerLetGoBeforeItsPostGoesUpAgainWithoutAWord() async throws {
        let service = mock()
        let composer = CommittingComposerService(videos: service)
        let file = try source(bytes: 3_000)
        let original = try Data(contentsOf: file)
        let first = try await completedVideo(service, file: file, bytes: 3_000)
        await service.remove(first.id, byModerator: false)
        let store = VideoUploadStore(directory: directory.appendingPathComponent("store"))
        _ = try store.adopt(file, as: "job.mp4")
        store.save([VideoUploadJob(accountId: account, sourceFileName: nil, fileName: "job.mp4", sizeBytes: 3_000,
                                   durationSeconds: 12, width: 720, height: 1280, uploadedVideoId: first.id,
                                   pendingPost: PendingVideoPost(text: "Two days later", scope: .international))])

        let relaunched = center(service, composer: composer, fetchPost: { try composer.post($0) })
        var posted: [Post] = []
        relaunched.onPosted = { posted += $0 }
        let id = try XCTUnwrap(relaunched.jobs.first?.id)
        let seen = try await until(relaunched, watching: id) { !posted.isEmpty }

        XCTAssertFalse(seen.contains { isFailed($0) }, "\(seen)")
        let video = try XCTUnwrap(posted.first?.video)
        XCTAssertNotEqual(video.id, first.id, "a new video")
        XCTAssertEqual(try Data(contentsOf: service.storedFile(video.id)), original, "from the file kept on the phone")
        XCTAssertEqual(composer.written.count, 1)
        XCTAssertEqual(composer.written.first?.text, "Two days later")
    }

    /// A moderator's removal is not a sweep: it is said, in its words, and
    /// the video is not sent again.
    func testAVideoAModeratorRemovedIsSaidAndNotSentAgain() async throws {
        let service = mock()
        let composer = CommittingComposerService(videos: service)
        let file = try source(bytes: 3_000)
        let first = try await completedVideo(service, file: file, bytes: 3_000)
        await service.remove(first.id, byModerator: true)
        let store = VideoUploadStore(directory: directory.appendingPathComponent("store"))
        _ = try store.adopt(file, as: "job.mp4")
        store.save([VideoUploadJob(accountId: account, sourceFileName: nil, fileName: "job.mp4", sizeBytes: 3_000,
                                   durationSeconds: 12, width: 720, height: 1280, uploadedVideoId: first.id,
                                   pendingPost: PendingVideoPost(text: "x", scope: .international))])

        let relaunched = center(service, composer: composer)
        let id = try XCTUnwrap(relaunched.jobs.first?.id)
        try await until(relaunched, id) { isFailed($0) }
        guard case let .failed(failure)? = relaunched.phase(id) else { return XCTFail() }
        XCTAssertEqual(failure.message, L10n.t("video.error.removed"))
        XCTAssertFalse(failure.canRetry)
        let starts = await service.calls.filter { $0 == "start" }.count
        XCTAssertEqual(starts, 1, "only the first upload")
        XCTAssertTrue(composer.written.isEmpty)
    }

    // MARK: - Pieces left by a process that ended

    func testPiecesLeftByAnEndedProcessAreClearedAtLaunch() throws {
        let pieces = directory.appendingPathComponent("store/\(VideoUploader.piecesFolder)", isDirectory: true)
        try FileManager.default.createDirectory(at: pieces, withIntermediateDirectories: true)
        for number in 1...3 {
            try Data(count: 1024).write(to: pieces.appendingPathComponent("\(UUID().uuidString)-\(number).part"))
        }

        _ = center(mock())

        let left = (try? FileManager.default.contentsOfDirectory(atPath: pieces.path)) ?? []
        XCTAssertTrue(left.isEmpty, "\(left)")
    }

    func testAPendingPostKeepsItsWholeAudience() {
        let pending = PendingVideoPost(text: "  hi  ", scope: .region(.gcc), quotedPostId: UUID(), communityId: UUID())
        let videoId = UUID()
        let draft = pending.draft(videoId: videoId)
        XCTAssertEqual(draft.text, "hi")
        XCTAssertEqual(draft.scope, .region(.gcc))
        XCTAssertEqual(draft.quotedPostId, pending.quotedPostId)
        XCTAssertEqual(draft.communityId, pending.communityId)
        XCTAssertEqual(draft.videoId, videoId)
        XCTAssertNil(draft.sensitive)
        XCTAssertEqual(PendingVideoPost(text: "", scope: .country("SA")).composeScope, .country("SA"))
    }
}

/// The author's own videos, watched until they are ready.
@MainActor
final class VideoStatusBoardTests: XCTestCase {

    func testAWatchedVideoIsReadUntilItIsReady() async throws {
        let directory = VideoFixtures.directory("board")
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = VideoServiceMock(directory: directory, pieceLatency: 0, readyAfterReads: 3, pieceSize: 1024)
        let file = try VideoFixtures.file(bytes: 500, in: directory)
        let start = try await service.startUpload(sizeBytes: 500, durationSeconds: 3, contentType: "video/mp4")
        try await service.sendChunk(start.upload, number: 1, file: file, progress: { _ in })
        let processing = try await service.complete(start.upload)

        let board = VideoStatusBoard(service: service, sleep: { _ in try await Task.sleep(nanoseconds: 1_000_000) })
        board.watch(processing)
        board.watch(processing)

        let deadline = Date().addingTimeInterval(5)
        while board.current(processing).status != .ready, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(board.current(processing).status, .ready)
        XCTAssertTrue(board.current(processing).isPlayable)
        let reads = await service.calls.filter { $0 == "video" }.count
        XCTAssertEqual(reads, 3, "one poll however many cards show it, and none once it is ready")
    }

    func testTheLastCardGoingAwayStopsThePoll() async throws {
        let directory = VideoFixtures.directory("board")
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = VideoServiceMock(directory: directory, pieceLatency: 0, readyAfterReads: 1_000, pieceSize: 1024)
        let video = PostVideo(id: UUID(), status: .processing)
        let board = VideoStatusBoard(service: service, sleep: { _ in try await Task.sleep(nanoseconds: 5_000_000) })
        board.watch(video)
        board.unwatch(video.id)
        try await Task.sleep(nanoseconds: 100_000_000)
        let reads = await service.calls.count
        XCTAssertLessThanOrEqual(reads, 1)
    }

    func testASettledVideoIsNeverPolled() async throws {
        let directory = VideoFixtures.directory("board")
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = VideoServiceMock(directory: directory, pieceLatency: 0)
        let board = VideoStatusBoard(service: service, sleep: { _ in })
        board.watch(PostVideo(id: UUID(), status: .ready))
        board.watch(PostVideo(id: UUID(), status: .failed))
        try await Task.sleep(nanoseconds: 50_000_000)
        let calls = await service.calls
        XCTAssertTrue(calls.isEmpty)
    }
}

/// Whether the app is on screen, as a test says.
@MainActor
final class Screen {
    var active = true
}
