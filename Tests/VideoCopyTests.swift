import XCTest
@testable import Sila

/// Contract v28's words (§10–§11): each refusal and each state said in the
/// app's own words, in English and in Arabic, one language at a time.
final class VideoCopyTests: XCTestCase {

    override func tearDown() {
        L10n.use(nil)
        super.tearDown()
    }

    private struct Refusal {
        let raw: String
        let code: APIErrorCode
        let key: String
        let status: Int
        var extra = ""
    }

    private static let refusals: [Refusal] = [
        Refusal(raw: "video_not_allowed", code: .videoNotAllowed, key: "video.error.notAvailable", status: 403,
                extra: #", "reason": "not_available""#),
        Refusal(raw: "video_too_long", code: .videoTooLong, key: "video.error.tooLong", status: 400,
                extra: #", "max_duration_s": 185.0"#),
        Refusal(raw: "video_too_large", code: .videoTooLarge, key: "video.error.tooLarge", status: 413,
                extra: #", "max_bytes": 314572800"#),
        Refusal(raw: "video_rate_limited", code: .videoRateLimited, key: "video.error.rateLimited", status: 429),
        Refusal(raw: "upload_expired", code: .uploadExpired, key: "video.error.uploadExpired", status: 410),
        Refusal(raw: "upload_incomplete", code: .uploadIncomplete, key: "video.error.uploadIncomplete", status: 409,
                extra: #", "committed_bytes": 0, "size_bytes": 10, "missing_offsets": [0]"#),
        Refusal(raw: "upload_chunk_invalid", code: .uploadChunkInvalid, key: "video.error.uploadFailed", status: 400),
        Refusal(raw: "video_upload_unavailable", code: .videoUploadUnavailable, key: "video.error.unavailable", status: 503),
        Refusal(raw: "video_not_found", code: .videoNotFound, key: "video.error.notFound", status: 404),
        Refusal(raw: "invalid_video", code: .invalidVideo, key: "video.error.notYours", status: 400),
        Refusal(raw: "video_used", code: .videoUsed, key: "video.error.used", status: 409),
        Refusal(raw: "video_not_uploaded", code: .videoNotUploaded, key: "video.error.notUploaded", status: 409),
        Refusal(raw: "video_processing_failed", code: .videoProcessingFailed, key: "video.error.unreadable", status: 409,
                extra: #", "failure_code": "video_unreadable""#),
        Refusal(raw: "video_removed", code: .videoRemoved, key: "video.error.removed", status: 409),
        Refusal(raw: "video_with_media", code: .videoWithMedia, key: "video.error.withMedia", status: 400),
    ]

    private func decoded(_ refusal: Refusal) -> APIError {
        let body = #"{"detail": {"code": "\#(refusal.raw)", "message": "The server's own words"\#(refusal.extra)}}"#
        return URLSessionNetworkClient.makeError(status: refusal.status, data: Data(body.utf8))
    }

    func testEveryVideoCodeIsRecognised() {
        for refusal in Self.refusals {
            XCTAssertEqual(APIErrorCode(serverCode: refusal.raw), refusal.code, refusal.raw)
            XCTAssertEqual(decoded(refusal).code, refusal.code, refusal.raw)
        }
        XCTAssertEqual(APIErrorCode(serverCode: "upload_type_mismatch"), .uploadTypeMismatch)
    }

    func testEachIsSaidInTheAppsOwnWords() {
        XCTAssertTrue(L10n.use("en"))
        for refusal in Self.refusals {
            let message = decoded(refusal).userMessage
            XCTAssertEqual(message, L10n.t(refusal.key), refusal.raw)
            XCTAssertNotEqual(message, refusal.key, "\(refusal.key) is missing from the catalog")
            XCTAssertNotEqual(message, "The server's own words", "\(refusal.raw) repeats the server")
        }
    }

    func testEachHasItsOwnArabicSentence() {
        XCTAssertTrue(L10n.use("en"))
        let english = Dictionary(uniqueKeysWithValues: Self.refusals.map { ($0.raw, decoded($0).userMessage) })
        guard L10n.use("ar") else { return XCTFail("the build has no Arabic resources") }
        for refusal in Self.refusals {
            let arabic = decoded(refusal).userMessage
            XCTAssertNotEqual(arabic, english[refusal.raw], "\(refusal.raw) renders English in Arabic")
            XCTAssertNotNil(arabic.range(of: "\\p{Arabic}", options: .regularExpression), refusal.raw)
            XCTAssertNil(arabic.range(of: "[A-Za-z]", options: .regularExpression), "\(refusal.raw) mixes in English: \(arabic)")
        }
    }

    /// One code, two situations: the words follow the reason.
    func testNotAllowedSaysWhichOfTheTwoItIs() {
        XCTAssertTrue(L10n.use("en"))
        let off = #"{"detail": {"code": "video_not_allowed", "message": "x", "reason": "not_available"}}"#
        let unverified = #"{"detail": {"code": "video_not_allowed", "message": "x", "reason": "not_verified"}}"#
        XCTAssertEqual(URLSessionNetworkClient.makeError(status: 403, data: Data(off.utf8)).userMessage,
                       "Video posts aren't available yet.")
        XCTAssertEqual(URLSessionNetworkClient.makeError(status: 403, data: Data(unverified.utf8)).userMessage,
                       "Only verified members can post videos.")
    }

    /// Posting a failed video is said in the failure's own words.
    func testAFailedVideoIsSaidInItsFailuresWords() {
        XCTAssertTrue(L10n.use("en"))
        for (code, key) in [("video_too_long", "video.error.tooLong"), ("video_unreadable", "video.error.unreadable"),
                            ("video_processing_failed", "video.error.processingFailed"),
                            ("upload_expired", "video.error.uploadExpired")] {
            let body = #"{"detail": {"code": "video_processing_failed", "message": "x", "failure_code": "\#(code)"}}"#
            XCTAssertEqual(URLSessionNetworkClient.makeError(status: 409, data: Data(body.utf8)).userMessage, L10n.t(key), code)
            XCTAssertEqual(VideoCopy.failure(code: code), L10n.t(key), code)
        }
    }

    // MARK: - The author's words (§11)

    func testTheAuthorIsToldWhereTheirVideoStands() {
        XCTAssertTrue(L10n.use("en"))
        let id = UUID()
        XCTAssertEqual(VideoCopy.authorNotice(for: PostVideo(id: id, status: .processing)),
                       "Preparing your video. Only you can see this post until it's ready.")
        XCTAssertEqual(VideoCopy.authorNotice(for: PostVideo(id: id, status: .held)),
                       "Your video is being reviewed before others can see it.")
        XCTAssertEqual(VideoCopy.authorNotice(for: PostVideo(id: id, status: .failed, failure: VideoFailure(code: "video_too_long"))),
                       "This video is longer than 3 minutes. Trim it and try again.")
        XCTAssertEqual(VideoCopy.authorNotice(for: PostVideo(id: id, status: .removed, removedByModerator: true)),
                       "A moderator removed this video because it breaks the community guidelines.")
        XCTAssertNil(VideoCopy.authorNotice(for: PostVideo(id: id, status: .removed)), "a post being deleted: nothing to say")
        XCTAssertNil(VideoCopy.authorNotice(for: PostVideo(id: id, status: .ready)))
    }

    func testTheAuthorsWordsInArabic() {
        guard L10n.use("ar") else { return XCTFail("the build has no Arabic resources") }
        let id = UUID()
        XCTAssertEqual(VideoCopy.authorNotice(for: PostVideo(id: id, status: .processing)),
                       "جارٍ تجهيز الفيديو. لن يرى هذا المنشور أحد غيرك حتى يصبح جاهزًا.")
        XCTAssertEqual(VideoCopy.authorNotice(for: PostVideo(id: id, status: .held)), "يُراجَع الفيديو قبل أن يراه الآخرون.")
        XCTAssertEqual(VideoCopy.authorNotice(for: PostVideo(id: id, status: .removed, removedByModerator: true)),
                       "أزال أحد المشرفين هذا الفيديو لمخالفته إرشادات المجتمع.")
        XCTAssertEqual(VideoCopy.captionLabel("ar"), "العربية (تلقائية)")
        XCTAssertEqual(VideoCopy.captionLabel("en"), "الإنجليزية (تلقائية)")
        let uploading = VideoCopy.uploading(0.42)
        XCTAssertTrue(uploading.hasPrefix("جارٍ الرفع…"), uploading)
        XCTAssertTrue(uploading.contains("42"), "Western digits, like every number in the app: \(uploading)")
        XCTAssertNil(uploading.range(of: "[٠-٩]", options: .regularExpression))
    }

    func testCaptionsAreAlwaysNamedAsAutomatic() {
        XCTAssertTrue(L10n.use("en"))
        XCTAssertEqual(VideoCopy.captionLabel("ar"), "Arabic (automatic)")
        XCTAssertEqual(VideoCopy.captionLabel("en"), "English (automatic)")
        XCTAssertEqual(VideoCaptionTrack(language: "en", url: URL(fileURLWithPath: "/x.vtt")).label, "English (automatic)")
        XCTAssertTrue(VideoCopy.captionLabel("fr").hasSuffix("(automatic)"))
    }

    func testProgressIsAWholePercentAndNeverMoreThanAll() {
        XCTAssertTrue(L10n.use("en"))
        XCTAssertEqual(VideoCopy.uploading(0.42), "Uploading… 42%")
        XCTAssertEqual(VideoCopy.percent(1.7), "100%")
        XCTAssertEqual(VideoCopy.percent(-1), "0%")
        XCTAssertEqual(VideoUploadActivity.sending(sent: 100, total: 100).fraction, 0.99,
                       "not all there until the server says so")
        XCTAssertEqual(VideoUploadActivity.sending(sent: 42, total: 100).fraction, 0.42, accuracy: 0.0001)
        XCTAssertEqual(VideoUploadActivity.sending(sent: 1, total: 0).fraction, 0)
        XCTAssertEqual(VideoCopy.duration(94.2), "1:34")
    }

    func testTheRefusalBeforeUploadingOffersATrim() {
        XCTAssertTrue(L10n.use("en"))
        let refusal = VideoRefusal(source: URL(fileURLWithPath: "/x.mov"), durationSeconds: 252)
        XCTAssertEqual(refusal.message, "This video is longer than 3 minutes. Trim it and try again.")
        XCTAssertEqual(L10n.t("video.refusal.length", VideoCopy.duration(refusal.durationSeconds)), "This one is 4:12.")
    }
}
