import CoreGraphics
import XCTest
@testable import Sila

private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try JSONCoding.decoder.decode(T.self, from: Data(json.utf8))
}

/// Contract v28's shapes, read as the server sends them.
final class VideoModelsTests: XCTestCase {

    private let id = "3f0c9a4e-0000-4000-8000-00000000c0de"

    // MARK: - The video object

    func testAReadyVideoResolvesEveryFileAgainstTheAPIHost() throws {
        let video = try decode(PostVideo.self, """
        {"id": "\(id)", "status": "ready",
         "poster_url": "/api/v1/media/video/\(id)/poster.jpg",
         "hls_url": "/api/v1/media/video/\(id)/master.m3u8",
         "duration_s": 94.21, "width": 720, "height": 1280,
         "captions": [{"lang": "ar", "url": "/api/v1/media/video/\(id)/captions-ar.vtt"},
                      {"lang": "en", "url": "/api/v1/media/video/\(id)/captions-en.vtt"}],
         "post_id": null, "failure": null, "removed_by_moderator": null, "created_at": "2026-09-28T06:46:14.615030Z"}
        """)
        XCTAssertEqual(video.status, .ready)
        XCTAssertTrue(video.isPlayable)
        XCTAssertEqual(video.hlsURL?.host, AppConfig.apiBaseURL.host, "a root-relative path resolves against the API host")
        XCTAssertEqual(video.hlsURL?.path, "/api/v1/media/video/\(id)/master.m3u8")
        XCTAssertEqual(video.posterURL?.lastPathComponent, "poster.jpg")
        XCTAssertEqual(video.captions.map(\.language), ["ar", "en"])
        XCTAssertEqual(video.captions(in: "en")?.url.lastPathComponent, "captions-en.vtt")
        XCTAssertEqual(video.durationSeconds ?? 0, 94.21, accuracy: 0.001)
        XCTAssertEqual(video.aspectRatio, 720.0 / 1280.0, accuracy: 0.001, "a portrait video is taller than wide")
        XCTAssertNotNil(video.createdAt)
    }

    /// Only `ready` has public files. A wire that says otherwise is not
    /// believed: no player is ever drawn for a file that may not exist.
    func testAVideoThatIsNotReadyNeverKeepsAFile() throws {
        for status in ["uploading", "processing", "held", "failed", "removed"] {
            let video = try decode(PostVideo.self, """
            {"id": "\(id)", "status": "\(status)", "poster_url": "/api/v1/media/video/x/poster.jpg",
             "hls_url": "/api/v1/media/video/x/master.m3u8", "captions": [{"lang": "ar", "url": "/x.vtt"}]}
            """)
            XCTAssertNil(video.hlsURL, status)
            XCTAssertNil(video.posterURL, status)
            XCTAssertTrue(video.captions.isEmpty, status)
            XCTAssertFalse(video.isPlayable, status)
        }
    }

    func testAStatusThisBuildDoesNotKnowIsReadAsProcessing() throws {
        let video = try decode(PostVideo.self, #"{"id": "\#(id)", "status": "transcoding_v2", "hls_url": "/a.m3u8"}"#)
        XCTAssertEqual(video.status, .processing)
        XCTAssertFalse(video.isPlayable)
    }

    func testTheOwnersFieldsAreRead() throws {
        let failed = try decode(PostVideo.self, """
        {"id": "\(id)", "status": "failed", "failure": {"code": "video_too_long", "message": "…"}, "post_id": "\(id)"}
        """)
        XCTAssertEqual(failed.failure?.code, "video_too_long")
        XCTAssertEqual(failed.postId?.uuidString.lowercased(), id)
        let removed = try decode(PostVideo.self, #"{"id": "\#(id)", "status": "removed", "removed_by_moderator": true}"#)
        XCTAssertTrue(removed.removedByModerator)
    }

    func testAnOddSizeIsHeldToAReasonableShape() {
        XCTAssertEqual(PostVideo(id: UUID(), status: .ready, width: 4000, height: 100).aspectRatio, 16.0 / 9.0, accuracy: 0.001)
        XCTAssertEqual(PostVideo(id: UUID(), status: .ready, width: 100, height: 4000).aspectRatio, 9.0 / 16.0, accuracy: 0.001)
        XCTAssertEqual(PostVideo(id: UUID(), status: .ready).aspectRatio, 16.0 / 9.0, accuracy: 0.001, "unmeasured: 16:9")
    }

    func testAPostCarriesItsVideoAndABrokenVideoCostsOnlyTheVideo() throws {
        let post = try decode(Post.self, """
        {"id": "00000000-0000-4000-8000-000000000001",
         "author": {"id": "00000000-0000-4000-8000-000000000101", "handle": "aziz", "display_name": "Aziz", "is_verified": true},
         "text": "Riyadh at night", "created_at": "2026-09-28T10:00:00Z", "scope": "international",
         "video": {"id": "\(id)", "status": "processing", "duration_s": 12.5}}
        """)
        XCTAssertEqual(post.video?.status, .processing)
        XCTAssertEqual(post.video?.durationSeconds ?? 0, 12.5, accuracy: 0.001)

        let broken = try decode(Post.self, """
        {"id": "00000000-0000-4000-8000-000000000002",
         "author": {"id": "00000000-0000-4000-8000-000000000101", "handle": "aziz", "display_name": "Aziz", "is_verified": true},
         "text": "Still here", "created_at": "2026-09-28T10:00:00Z", "scope": "international",
         "video": {"status": "ready"}}
        """)
        XCTAssertNil(broken.video)
        XCTAssertEqual(broken.text, "Still here")
    }

    func testAQuotedPostKeepsItsVideo() {
        let video = PostVideo(id: UUID(), status: .ready, hlsURL: URL(string: "https://x/master.m3u8"))
        let quoted = Post(id: UUID(), author: FeedServiceMock.aziz, text: "q", createdAt: Date(), video: video)
        let quoting = Post(id: UUID(), author: FeedServiceMock.noor, text: "look", createdAt: Date(), quotedPost: quoted)
        XCTAssertEqual(quoting.quotedPost?.video, video)
    }

    // MARK: - Features

    func testFeaturesAreReadAndAMissingFlagIsNothingOffered() throws {
        let base = """
        "id": "11111111-2222-3333-4444-555555555555", "email": "a@example.com", "email_verified": true,
        "verification_status": "verified", "created_at": "2026-09-28T10:00:00Z"
        """
        let on = try decode(AuthUser.self, "{\(base), \"features\": {\"video\": true, \"video_upload\": true}}")
        XCTAssertEqual(on.features, AccountFeatures(video: true, videoUpload: true))
        let absent = try decode(AuthUser.self, "{\(base)}")
        XCTAssertEqual(absent.features, AccountFeatures(), "an older server offers nothing")
        let odd = try decode(AuthUser.self, "{\(base), \"features\": {\"video\": \"yes\"}}")
        XCTAssertFalse(odd.features.video)
        XCTAssertFalse(odd.features.videoUpload)
    }

    /// The cached account goes through the Keychain with these coders; the
    /// flags must survive the trip, or a cold launch would hide the picker.
    func testFeaturesSurviveTheKeychainRoundTrip() throws {
        var user = AuthServiceMock.makePair(email: "a@example.com", scenario: .verified).user
        user.features = AccountFeatures(video: true, videoUpload: true)
        let data = try JSONCoding.encoder.encode(user)
        XCTAssertEqual(try JSONCoding.decoder.decode(AuthUser.self, from: data).features, user.features)
        XCTAssertEqual(user.settingNeedsInterestPrompt(true).features, user.features)
    }

    // MARK: - Uploading

    func testAChunkedPlanIsReadAndKeptOnDiskUnchanged() throws {
        let start = try decode(VideoUploadStart.self, """
        {"video": {"id": "\(id)", "status": "uploading", "duration_s": 94.2},
         "upload": {"type": "chunked", "size_bytes": 48211234, "expires_at": "2026-09-29T08:00:00Z",
                    "status_url": "/api/v1/videos/uploads/\(id)", "complete_url": "/api/v1/videos/\(id)/complete",
                    "url": "/api/v1/videos/uploads/\(id)", "chunk_size": 5242880, "chunk_count": 10,
                    "parts_url": null, "part_size": null, "part_count": null}}
        """)
        XCTAssertEqual(start.upload.type, .chunked)
        XCTAssertEqual(start.upload.pieceSize, 5_242_880)
        XCTAssertEqual(start.upload.pieceCount, 10)
        XCTAssertEqual(start.video.status, .uploading)

        let kept = VideoUploadCheckpoint(plan: start.upload, videoId: start.video.id)
        let data = try JSONCoding.encoder.encode(kept)
        XCTAssertEqual(try JSONCoding.decoder.decode(VideoUploadCheckpoint.self, from: data), kept)
    }

    func testAPartsPlanIsRead() throws {
        let plan = try decode(VideoUploadPlan.self, """
        {"type": "parts", "size_bytes": 20000000, "expires_at": "2026-09-29T08:00:00Z",
         "status_url": "/api/v1/videos/uploads/\(id)", "complete_url": "/api/v1/videos/\(id)/complete",
         "url": null, "chunk_size": null, "chunk_count": null,
         "parts_url": "/api/v1/videos/uploads/\(id)/parts", "part_size": 8388608, "part_count": 3}
        """)
        XCTAssertEqual(plan.type, .parts)
        XCTAssertEqual(plan.pieceSize, 8_388_608)
        XCTAssertEqual(plan.pieceCount, 3)
        XCTAssertEqual(plan.partsUrl, "/api/v1/videos/uploads/\(id)/parts")
    }

    func testTheStatusAndTheTargetsAreRead() throws {
        let status = try decode(VideoUploadStatus.self, """
        {"video": {"id": "\(id)", "status": "uploading"}, "upload": null, "committed_bytes": 10485760,
         "missing_offsets": [10485760, 20971520], "missing_parts": null, "complete": false}
        """)
        XCTAssertEqual(status.committedBytes, 10_485_760)
        XCTAssertEqual(status.missingOffsets, [10_485_760, 20_971_520])
        XCTAssertFalse(status.complete)

        let targets = try decode(VideoPartTargets.self, """
        {"targets": [{"number": 1, "size": 8388608, "method": "PUT",
          "url": "https://sila-identity.oss-me-central-1.aliyuncs.com/ingest/x/original?partNumber=1&X-Amz-Signature=abc",
          "headers": {"content-length": "8388608"}, "expires_at": "2026-09-28T08:15:00Z"}]}
        """)
        XCTAssertEqual(targets.targets.first?.headers["content-length"], "8388608")
        XCTAssertEqual(targets.targets.first?.method, "PUT")
    }

    func testTheConfigIsRead() throws {
        let envelope = try decode(ServerConfigEnvelope.self, """
        {"video": {"enabled": true, "max_duration_s": 185.0, "max_upload_bytes": 314572800, "uploads_per_day": 20,
                   "renditions": ["720p", "480p"], "caption_languages": ["ar", "en"]}}
        """)
        XCTAssertEqual(envelope.video, VideoConfig(enabled: true, maxDurationSeconds: 185, maxUploadBytes: 314_572_800, uploadsPerDay: 20))
    }

    func testThePlanRequestIsSnakeCase() throws {
        let body = try JSONCoding.encoder.encode(VideoUploadStartRequest(sizeBytes: 10, durationS: 3.5, contentType: "video/mp4"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["size_bytes"] as? Int, 10)
        XCTAssertEqual(json["duration_s"] as? Double, 3.5)
        XCTAssertEqual(json["content_type"] as? String, "video/mp4")
    }

    func testAPostCarriesItsVideoIdLowerCaseAndOnlyWhenThereIsOne() throws {
        let videoId = UUID()
        let with = try JSONSerialization.jsonObject(with: JSONCoding.encoder.encode(
            CreatePostBody(draft: PostDraft(text: "", scope: .international, videoId: videoId))
        )) as? [String: Any]
        XCTAssertEqual(with?["video_id"] as? String, videoId.uuidString.lowercased())
        let without = try JSONSerialization.jsonObject(with: JSONCoding.encoder.encode(
            CreatePostBody(draft: PostDraft(text: "hi", scope: .international))
        )) as? [String: Any]
        XCTAssertNil(without?["video_id"])
        XCTAssertTrue(PostDraft(text: "", scope: .international, videoId: videoId).isPostable, "a video stands alone")
    }

    func testAThreadCarriesTheVideoOnItsOpeningPostOnly() async {
        let service = ScriptedComposerService()
        let videoId = UUID()
        let report = await service.createThread(segments: ["one", "two"], scope: .international, videoId: videoId)
        XCTAssertTrue(report.isCompleteSuccess)
        XCTAssertEqual(service.drafts.map(\.videoId), [videoId, nil])
    }

    // MARK: - Arithmetic

    func testPiecesAreTheServersArithmetic() {
        let size = 5_242_880
        let total = 48_211_234
        XCTAssertEqual(VideoPieces.count(total: total, pieceSize: size), 10)
        XCTAssertEqual(VideoPieces.count(total: 1, pieceSize: size), 1)
        XCTAssertEqual(VideoPieces.count(total: size, pieceSize: size), 1)
        XCTAssertEqual(VideoPieces.range(number: 1, total: total, pieceSize: size), 0..<size)
        XCTAssertEqual(VideoPieces.range(number: 10, total: total, pieceSize: size), (9 * size)..<total, "the last one is the rest")
        XCTAssertTrue(VideoPieces.range(number: 11, total: total, pieceSize: size).isEmpty)
        XCTAssertEqual(VideoPieces.contentRange(number: 2, total: total, pieceSize: size),
                       "bytes 5242880-10485759/48211234")
        XCTAssertEqual(VideoPieces.contentRange(number: 10, total: total, pieceSize: size),
                       "bytes 47185920-48211233/48211234")
    }

    func testWhatIsMissingIsReadFromOffsetsPartsOrTheCommittedByte() {
        let chunked = VideoUploadPlan(type: .chunked, sizeBytes: 30, statusUrl: "/s", completeUrl: "/c", url: "/u", chunkSize: 10)
        let video = PostVideo(id: UUID(), status: .uploading)
        func status(_ committed: Int, offsets: [Int]? = nil, parts: [Int]? = nil) -> VideoUploadStatus {
            VideoUploadStatus(video: video, upload: nil, committedBytes: committed, missingOffsets: offsets, missingParts: parts, complete: false)
        }
        XCTAssertEqual(VideoPieces.missing(in: status(10, offsets: [10, 20]), plan: chunked), [2, 3])
        XCTAssertEqual(VideoPieces.missing(in: status(0, offsets: [20, 0, 20]), plan: chunked), [1, 3], "out of order and twice")
        XCTAssertEqual(VideoPieces.missing(in: status(0, offsets: [15, 99]), plan: chunked), [], "an offset off the grid is not a piece")
        XCTAssertEqual(VideoPieces.missing(in: status(10), plan: chunked), [2, 3], "no list: everything from the committed byte")
        let parts = VideoUploadPlan(type: .parts, sizeBytes: 30, statusUrl: "/s", completeUrl: "/c", partsUrl: "/p", partSize: 10)
        XCTAssertEqual(VideoPieces.missing(in: status(0, parts: [3, 1]), plan: parts), [1, 3])
        XCTAssertEqual(VideoPieces.missing(in: status(30), plan: parts), [])
    }

    func testTheBackoffDoublesToAMinuteWithJitter() {
        XCTAssertEqual(VideoBackoff.delay(attempt: 1, jitter: 1), 1)
        XCTAssertEqual(VideoBackoff.delay(attempt: 2, jitter: 1), 2)
        XCTAssertEqual(VideoBackoff.delay(attempt: 4, jitter: 1), 8)
        XCTAssertEqual(VideoBackoff.delay(attempt: 20, jitter: 1), 60, "never more than a minute")
        XCTAssertEqual(VideoBackoff.delay(attempt: 4, jitter: 0), 4, "jitter takes up to half off")
        XCTAssertGreaterThanOrEqual(VideoBackoff.delay(attempt: 1, jitter: 0), 0.5)
    }

    // MARK: - Autoplay

    func testAutoplayNeedsUnmeteredWiFiAndTheSystemsConsent() {
        let wifi = VideoAutoplayPolicy.Connection(isSatisfied: true, usesWiFi: true, isConstrained: false, isExpensive: false)
        XCTAssertTrue(VideoAutoplayPolicy(connection: wifi, systemAllowsAutoplay: true, isLowPowerMode: false).allowsAutoplay)

        var lowData = wifi
        lowData.isConstrained = true
        XCTAssertFalse(VideoAutoplayPolicy(connection: lowData, systemAllowsAutoplay: true, isLowPowerMode: false).allowsAutoplay,
                       "Low Data Mode")
        var hotspot = wifi
        hotspot.isExpensive = true
        XCTAssertFalse(VideoAutoplayPolicy(connection: hotspot, systemAllowsAutoplay: true, isLowPowerMode: false).allowsAutoplay,
                       "a phone's hotspot is Wi-Fi and still somebody's data")
        let cellular = VideoAutoplayPolicy.Connection(isSatisfied: true, usesWiFi: false, isConstrained: false, isExpensive: true)
        XCTAssertFalse(VideoAutoplayPolicy(connection: cellular, systemAllowsAutoplay: true, isLowPowerMode: false).allowsAutoplay)
        XCTAssertFalse(VideoAutoplayPolicy(connection: wifi, systemAllowsAutoplay: false, isLowPowerMode: false).allowsAutoplay,
                       "Auto-Play Video Previews is off")
        XCTAssertFalse(VideoAutoplayPolicy(connection: wifi, systemAllowsAutoplay: true, isLowPowerMode: true).allowsAutoplay)
        XCTAssertFalse(VideoAutoplayPolicy(connection: .unknown, systemAllowsAutoplay: true, isLowPowerMode: false).allowsAutoplay,
                       "nothing until the network has been heard from")
    }

    func testTheCardMostInViewPlays() {
        let viewport = CGRect(x: 0, y: 0, width: 400, height: 800)
        let top = UUID(), middle = UUID(), cut = UUID()
        let frames: [UUID: CGRect] = [
            top: CGRect(x: 0, y: -150, width: 400, height: 300),     // half in view
            middle: CGRect(x: 0, y: 250, width: 400, height: 300),   // all in view
            cut: CGRect(x: 0, y: 700, width: 400, height: 300),      // a third in view
        ]
        XCTAssertEqual(VideoAutoplayPolicy.visibleFraction(of: frames[top]!, in: viewport), 0.5, accuracy: 0.001)
        XCTAssertEqual(VideoAutoplayPolicy.choose(frames, in: viewport), middle)
        XCTAssertNil(VideoAutoplayPolicy.choose([top: frames[top]!, cut: frames[cut]!], in: viewport),
                     "under 60% in view, nothing starts by itself")
        let a = UUID(), b = UUID()
        XCTAssertEqual(VideoAutoplayPolicy.choose([
            a: CGRect(x: 0, y: 0, width: 400, height: 200),
            b: CGRect(x: 0, y: 300, width: 400, height: 200),
        ], in: viewport), b, "both whole: the one nearer the middle")
    }
}

/// The captions the app draws itself.
final class WebVTTTests: XCTestCase {

    func testTheServersCaptionsAreRead() {
        let cues = WebVTT.parse("""
        WEBVTT

        1
        00:00:00.000 --> 00:00:03.038
        ترجمة تجريبية

        2
        00:00:03.038 --> 00:00:05.500 align:start position:10%
        <v Speaker>Hello &amp; welcome</v>
        second line

        NOTE this is a note

        00:01.000 --> 00:02.000
        short form
        """)
        XCTAssertEqual(cues.count, 3)
        XCTAssertEqual(cues[0], WebVTTCue(start: 0, end: 3.038, text: "ترجمة تجريبية"))
        XCTAssertEqual(cues[2].text, "Hello & welcome\nsecond line", "tags go, entities are read, settings are ignored")
        XCTAssertEqual(cues[1].start, 1, "sorted by time, the short MM:SS form included")
    }

    func testTheWordsAtAMoment() {
        let cues = [WebVTTCue(start: 0, end: 2, text: "one"), WebVTTCue(start: 2, end: 4, text: "two"),
                    WebVTTCue(start: 3, end: 5, text: "over")]
        XCTAssertEqual(WebVTT.text(at: 1, in: cues), "one")
        XCTAssertEqual(WebVTT.text(at: 2, in: cues), "two", "an end is exclusive")
        XCTAssertEqual(WebVTT.text(at: 3.5, in: cues), "two\nover")
        XCTAssertNil(WebVTT.text(at: 6, in: cues))
    }

    func testABrokenCueCostsOnlyThatCue() {
        let cues = WebVTT.parse("WEBVTT\r\n\r\n00:00:05.000 --> 00:00:01.000\r\nbackwards\r\n\r\nnonsense --> x\r\nno\r\n\r\n00:00:01.000 --> 00:00:02.000\r\nkept\r\n")
        XCTAssertEqual(cues, [WebVTTCue(start: 1, end: 2, text: "kept")])
        XCTAssertTrue(WebVTT.parse("").isEmpty)
        XCTAssertEqual(WebVTT.timestamp("01:02:03.500"), 3723.5)
        XCTAssertNil(WebVTT.timestamp("1:2:3:4"))
    }
}
