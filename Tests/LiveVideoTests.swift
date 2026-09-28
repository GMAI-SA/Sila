import AVFoundation
import XCTest
@testable import Sila

/// Contract v28 against the staging backend and its video worker, through
/// the app's own services, uploader and decoders: the flags, a small video
/// made on the simulator compressed and sent through a background session,
/// posted before it is ready, watched to ready, played; an upload resumed
/// half way; and the refusals in the app's words.
///
/// **Disposable accounts only, on staging only.** Each run registers its own
/// `itest-ios-…@example.com` accounts through staging's dev routes; the one
/// that uploads is made verified by the dev hook, the pipeline's stand-in.
/// The screen's verdict is set to "ok" through `/dev/videos/{id}/screening`,
/// so a test pattern and a tone never wait on the vision model. The post is
/// deleted at the end, which deletes every file of its video, and the
/// resumed upload is discarded. It never runs the shared test-user purge.
///
/// ```
/// ssh -N -L 8101:127.0.0.1:8101 -i ~/.ssh/geniusai_new ubuntu@185.216.21.10 &
/// TEST_RUNNER_SILA_LIVE_API=1 TEST_RUNNER_SILA_API_ORIGIN=http://127.0.0.1:8101 \
///   xcodebuild … test -only-testing:SilaTests/LiveVideoTests
/// ```
final class LiveVideoTests: XCTestCase {

    private let password = "Passw0rd!234"
    private var directory: URL!
    private var cleanup: [() async -> Void] = []

    override func setUpWithError() throws {
        _ = try LiveTarget.api()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("live-video-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        for step in cleanup.reversed() { await step() }
        cleanup = []
        if let directory { try? FileManager.default.removeItem(at: directory) }
        try await super.tearDown()
    }

    // MARK: - Disposable accounts

    private struct Account {
        let email: String
        let token: String
        let auth: AuthService
        let tokens: StaticAccessTokenProvider
    }

    private func account(verified: Bool) async throws -> Account {
        let tag = UUID().uuidString.prefix(10).lowercased()
        let email = "itest-ios-video\(verified ? "v" : "u")\(tag)@example.com"
        let auth = AuthService(
            network: LiveTarget.network(),
            store: AuthTokenStore(keychain: InMemoryKeychainClient(), storage: InMemoryStorageClient()),
            biometrics: StubBiometricAuthenticator(),
            analytics: RecordingAnalyticsClient()
        )
        _ = try await auth.register(email: email, password: password)
        let peek = try await LiveTarget.dev("otp/peek", query: [URLQueryItem(name: "email", value: email)])
        let code = try XCTUnwrap(peek["code"] as? String, "no code recorded for \(email)")
        let pair = try await auth.verifyOTP(email: email, code: code, purpose: .register, password: password)
        if verified {
            _ = try await LiveTarget.dev("user/set", body: [
                "email": email, "verification_status": "verified", "country_code": "SA",
            ])
        }
        return Account(email: email, token: pair.token.accessToken, auth: auth,
                       tokens: StaticAccessTokenProvider(token: pair.token.accessToken))
    }

    private func videoService(_ account: Account, transport: VideoUploadTransport) throws -> VideoService {
        VideoService(network: LiveTarget.network(), tokens: account.tokens, transport: transport,
                     analytics: RecordingAnalyticsClient(), baseURL: try LiveTarget.api())
    }

    /// A media URL moved onto the staging API's origin, path and query kept.
    private func onStaging(_ url: URL) throws -> URL {
        let api = try LiveTarget.api()
        var components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        components.scheme = api.scheme
        components.host = api.host
        components.port = api.port
        return try XCTUnwrap(components.url)
    }

    private func setScreening(_ id: UUID, _ verdict: String) async throws {
        _ = try await LiveTarget.dev("videos/\(id.uuidString.lowercased())/screening", body: ["verdict": verdict])
    }

    // MARK: - The flags

    func testTheServerOffersVideoToAVerifiedAccountOnly() async throws {
        let verified = try await account(verified: true)
        let me = try await verified.auth.currentUser()
        XCTAssertEqual(me.features, AccountFeatures(video: true, videoUpload: true), "staging has video on")

        let newcomer = try await account(verified: false)
        let theirs = try await newcomer.auth.currentUser()
        XCTAssertTrue(theirs.features.video)
        XCTAssertFalse(theirs.features.videoUpload, "an unverified account is shown no picker")

        let config = try await videoService(verified, transport: ForegroundVideoUploadTransport()).fetchConfig()
        XCTAssertTrue(config.enabled)
        XCTAssertEqual(config.maxDurationSeconds, VideoLimits.maximumDuration)
        XCTAssertEqual(config.maxUploadBytes, VideoLimits.maximumUploadBytes)
    }

    // MARK: - The whole of one video post

    func testAVideoMadeOnThePhoneGoesUpIsPostedBeforeItIsReadyAndPlays() async throws {
        let author = try await account(verified: true)
        // Through the app's own background session, under a name of its own.
        let transport = BackgroundVideoUploadTransport(identifier: "com.socialsa.sila.video-upload.live-\(UUID().uuidString)")
        let service = try videoService(author, transport: transport)

        // A three-second test pattern with a tone, compressed as the app
        // compresses anything picked.
        let sample = try await SampleVideoFactory.make(.short, in: directory)
        let prepared = try await AVVideoPreparer().prepare(sample, to: directory.appendingPathComponent("prepared.mp4")) { _ in }
        XCTAssertGreaterThan(prepared.sizeBytes, 0)
        XCTAssertEqual(prepared.durationSeconds, 3, accuracy: 0.2)

        let uploader = VideoUploader(service: service, workDirectory: directory)
        let screened = ActivityLog()
        let video = try await uploader.upload(
            file: prepared.file,
            sizeBytes: prepared.sizeBytes,
            durationSeconds: prepared.durationSeconds,
            resumeFrom: nil,
            onCheckpoint: { [weak self] checkpoint in
                guard let checkpoint, let self else { return }
                // The dev stand-in for the vision model's "ok".
                try? await self.setScreening(checkpoint.videoId, "ok")
                screened.record(checkpoint)
            },
            onActivity: { screened.record($0) }
        )
        XCTAssertEqual(video.status, .processing, "complete hands the video to the worker")
        // The transfer daemon takes tasks only from a signed app; an unsigned
        // simulator build goes through the ordinary session instead. A signed
        // run (`SILA_EXPECT_BACKGROUND=1`) must have used the daemon.
        if ProcessInfo.processInfo.environment["SILA_EXPECT_BACKGROUND"] == "1" {
            XCTAssertFalse(transport.usesForegroundFallback, "the pieces did not go through the background session")
        }
        add(XCTAttachment(string: transport.usesForegroundFallback ? "foreground fallback" : "background session"))
        XCTAssertEqual(screened.checkpoints.count, 1)
        XCTAssertEqual(screened.checkpoints.first??.plan.type, .chunked, "local storage today: the chunked plan")
        XCTAssertTrue(screened.activities.contains(.completing))

        // Posted at once: the author's alone until the video is ready.
        let composer = ComposerService(network: LiveTarget.network(), tokens: author.tokens, analytics: RecordingAnalyticsClient())
        let post = try await composer.createPost(PostDraft(text: "itest video \(UUID().uuidString.prefix(6))",
                                                           scope: .international, videoId: video.id))
        cleanup.append {
            try? await LiveTarget.network().send(APIRequest(path: "/posts/\(post.id.uuidString.lowercased())",
                                                            method: .delete, accessToken: author.token))
        }
        XCTAssertEqual(post.video?.id, video.id)
        XCTAssertNotNil(post.video.map { $0.status == .processing || $0.status == .ready })

        // Watched as the app watches it, until it is ready.
        let board = await VideoStatusBoard(service: service, sleep: { _ in try await Task.sleep(nanoseconds: 2_000_000_000) })
        await board.watch(try XCTUnwrap(post.video))
        let deadline = Date().addingTimeInterval(240)
        var ready = try XCTUnwrap(post.video)
        while !ready.status.isSettled, Date() < deadline {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            ready = await board.current(ready)
        }
        await board.unwatch(ready.id)
        XCTAssertEqual(ready.status, .ready, "the worker never published it")
        // The paths are the server's; the process resolves them against the
        // app's own host, so they are moved onto staging's before anything is
        // fetched — a live test never reads from production.
        let hlsPath = try XCTUnwrap(ready.hlsURL).path
        XCTAssertEqual(hlsPath, "/api/v1/media/video/\(ready.id.uuidString.lowercased())/master.m3u8")
        let hls = try onStaging(try XCTUnwrap(ready.hlsURL))
        XCTAssertNotNil(ready.width)

        // The stream plays as HLS, the way the card opens it.
        let asset = AVURLAsset(url: hls)
        let (playable, duration) = try await asset.load(.isPlayable, .duration)
        XCTAssertTrue(playable, "AVFoundation cannot play \(hls)")
        XCTAssertEqual(duration.seconds, 3, accuracy: 0.5)

        // The poster is a picture, and every caption track reads.
        let poster = try await URLSession.shared.data(from: try onStaging(try XCTUnwrap(ready.posterURL)))
        XCTAssertEqual((poster.1 as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual((poster.1 as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type"), "image/jpeg")
        for track in ready.captions {
            let text = try await VideoPlaybackModel.download(try onStaging(track.url))
            XCTAssertTrue(text.hasPrefix("WEBVTT"), "\(track.language) is not WebVTT")
            _ = WebVTT.parse(text)
            XCTAssertTrue(track.label.contains("("), "captions are named as automatic: \(track.label)")
        }

        // Everybody else sees it now, ready, without the owner's fields.
        let reader = try await account(verified: true)
        let feed = FeedService(network: LiveTarget.network(), tokens: reader.tokens, analytics: RecordingAnalyticsClient())
        let seen = try await feed.fetchPost(post.id)
        XCTAssertEqual(seen.video?.status, .ready)
        XCTAssertNil(seen.video?.postId, "the owner's fields are the owner's")
        XCTAssertNil(seen.video?.createdAt)
    }

    // MARK: - Resuming

    /// Chunk 1 arrived before the app went away: the uploader asks where the
    /// upload stands and sends only chunks 2 and 3.
    func testAnInterruptedUploadResumesWithOnlyWhatIsMissing() async throws {
        let author = try await account(verified: true)
        let recorder = RecordingVideoService(inner: try videoService(author, transport: ForegroundVideoUploadTransport()))
        let sample = try await SampleVideoFactory.make(.big, in: directory)
        let size = AVVideoPreparer.fileSize(sample)
        XCTAssertGreaterThan(size, 2 * VideoLimits.chunkSize, "the sample must be three chunks")

        let start = try await recorder.startUpload(sizeBytes: size, durationSeconds: 5, contentType: "video/mp4")
        cleanup.append { try? await recorder.discard(start.video.id) }
        XCTAssertEqual(start.upload.type, .chunked)
        XCTAssertEqual(start.upload.chunkSize, VideoLimits.chunkSize)
        let first = directory.appendingPathComponent("chunk-1")
        let handle = try FileHandle(forReadingFrom: sample)
        try handle.read(upToCount: VideoLimits.chunkSize)?.write(to: first)
        try handle.close()
        try await recorder.sendChunk(start.upload, number: 1, file: first, progress: { _ in })

        let before = try await recorder.uploadStatus(start.upload)
        XCTAssertEqual(before.committedBytes, VideoLimits.chunkSize)
        XCTAssertEqual(before.missingOffsets, [VideoLimits.chunkSize, 2 * VideoLimits.chunkSize])

        let video = try await VideoUploader(service: recorder, workDirectory: directory).upload(
            file: sample, sizeBytes: size, durationSeconds: 5,
            resumeFrom: VideoUploadCheckpoint(plan: start.upload, videoId: start.video.id),
            onCheckpoint: { _ in }, onActivity: { _ in }
        )
        XCTAssertEqual(video.id, start.video.id)
        XCTAssertEqual(video.status, .processing)
        let chunks = await recorder.chunks
        XCTAssertEqual(chunks, [1, 2, 3], "chunk 1 went once, before the interruption, and was not sent again: \(chunks)")
    }

    // MARK: - Refusals, in the app's words

    func testTheServersRefusalsAreSaidInTheAppsWords() async throws {
        let author = try await account(verified: true)
        let service = try videoService(author, transport: ForegroundVideoUploadTransport())
        do {
            _ = try await service.startUpload(sizeBytes: 1_000, durationSeconds: 190, contentType: "video/mp4")
            XCTFail("190 seconds is over the limit")
        } catch let error as APIError {
            XCTAssertEqual(error.code, .videoTooLong)
            XCTAssertEqual(error.userMessage, L10n.t("video.error.tooLong"))
        }
        do {
            _ = try await service.startUpload(sizeBytes: 400 * 1_048_576, durationSeconds: 10, contentType: "video/mp4")
            XCTFail("400 MB is over the limit")
        } catch let error as APIError {
            XCTAssertEqual(error.code, .videoTooLarge)
            XCTAssertEqual(error.userMessage, L10n.t("video.error.tooLarge"))
        }

        let newcomer = try await account(verified: false)
        do {
            _ = try await videoService(newcomer, transport: ForegroundVideoUploadTransport())
                .startUpload(sizeBytes: 1_000, durationSeconds: 3, contentType: "video/mp4")
            XCTFail("an unverified account cannot upload")
        } catch let error as APIError {
            XCTAssertEqual((error.code == .unverified || error.code == .videoNotAllowed), true, "\(error)")
        }
    }
}

/// The real service, with the chunks it sent written down.
actor RecordingVideoService: VideoServiceProtocol {
    let inner: VideoService
    private(set) var chunks: [Int] = []

    init(inner: VideoService) { self.inner = inner }

    func fetchConfig() async throws -> VideoConfig { try await inner.fetchConfig() }
    func startUpload(sizeBytes: Int, durationSeconds: Double, contentType: String) async throws -> VideoUploadStart {
        try await inner.startUpload(sizeBytes: sizeBytes, durationSeconds: durationSeconds, contentType: contentType)
    }
    func uploadStatus(_ plan: VideoUploadPlan) async throws -> VideoUploadStatus { try await inner.uploadStatus(plan) }
    func sendChunk(_ plan: VideoUploadPlan, number: Int, file: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        try await inner.sendChunk(plan, number: number, file: file, progress: progress)
        chunks.append(number)
        chunks.sort()
    }
    func partTargets(_ plan: VideoUploadPlan, numbers: [Int]) async throws -> [VideoPartTarget] {
        try await inner.partTargets(plan, numbers: numbers)
    }
    func sendPart(_ target: VideoPartTarget, file: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        try await inner.sendPart(target, file: file, progress: progress)
    }
    func complete(_ plan: VideoUploadPlan) async throws -> PostVideo { try await inner.complete(plan) }
    func fetchVideo(_ id: UUID) async throws -> PostVideo { try await inner.fetchVideo(id) }
    func discard(_ id: UUID) async throws { try await inner.discard(id) }
}
