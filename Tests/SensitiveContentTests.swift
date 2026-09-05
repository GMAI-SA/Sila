import XCTest
@testable import Sila

/// The author's warning, from the wire to the cover.
///
/// Three properties matter. The **text is delivered with the warning** — the
/// cover is the reader's choice and opening it must not cost a request. A
/// **category this build cannot name still covers** the post, generically:
/// the author asked for a cover, and a server whose vocabulary grew must not
/// quietly uncover it. And a **note never travels alone** — the server would
/// refuse it, and it would deserve to.
final class SensitiveContentTests: XCTestCase {

    private func decode<T: Decodable>(_ json: String, as type: T.Type = T.self) throws -> T {
        try JSONCoding.decoder.decode(T.self, from: Data(json.utf8))
    }

    private static func post(sensitive: String?, note: String? = nil, quoted: String = "null") -> String {
        let kind = sensitive.map { "\"\($0)\"" } ?? "null"
        let noteText = note.map { "\"\($0)\"" } ?? "null"
        return """
        {"id": "6f6d1a3e-0000-4000-8000-00000000ab01",
         "author": {"id": "22222222-0000-4000-8000-000000000002", "handle": "faisal",
                    "display_name": "Faisal", "avatar_url": null, "is_verified": true,
                    "country_code": "SA", "verified_since": null},
         "text": "the butler did it", "created_at": "2026-09-05T10:00:00Z",
         "scope": "international", "scope_country": null, "scope_region": null,
         "reply_to_post_id": null, "reply_count_direct": 0, "quoted_post": \(quoted),
         "metrics": {"likes": 0, "reposts": 0, "replies": 0, "views": 0, "bookmarks": 0},
         "viewer": {"liked": false, "reposted": false, "bookmarked": false, "can_reply": true, "reply_block_reason": null},
         "sensitive": \(kind), "sensitive_note": \(noteText)}
        """
    }

    // MARK: - Decoding

    func testTheWarningAndTheNoteArriveWithTheText() throws {
        let post: Post = try decode(Self.post(sensitive: "spoiler", note: "Spoilers for episode 3"))
        XCTAssertEqual(post.sensitive, .spoiler)
        XCTAssertEqual(post.sensitiveNote, "Spoilers for episode 3")
        XCTAssertEqual(post.text, "the butler did it", "delivered; the cover is the reader's choice")
    }

    func testNoWarningIsNoWarningAndANoteWithoutOneIsDropped() throws {
        let plain: Post = try decode(Self.post(sensitive: nil))
        XCTAssertNil(plain.sensitive)
        XCTAssertNil(plain.sensitiveNote)
        let stray: Post = try decode(Self.post(sensitive: nil, note: "orphan"))
        XCTAssertNil(stray.sensitiveNote, "a note describes a cover; without one it is nothing")
        let absent: Post = try decode(Self.post(sensitive: nil).replacingOccurrences(
            of: ", \"sensitive\": null, \"sensitive_note\": null", with: ""
        ))
        XCTAssertNil(absent.sensitive, "a server that predates warnings has none")
    }

    func testAnUnknownCategoryStillCovers() throws {
        let post: Post = try decode(Self.post(sensitive: "scary"))
        XCTAssertEqual(post.sensitive, .other, "the author asked for a cover; the vocabulary growing must not remove it")
    }

    func testAQuotedPostKeepsItsOwnWarning() throws {
        let inner = Self.post(sensitive: "violence", note: "Crash footage")
            .replacingOccurrences(of: "ab01", with: "ab02")
        let post: Post = try decode(Self.post(sensitive: nil, quoted: inner))
        XCTAssertNil(post.sensitive, "the quoting post made no claim of its own")
        XCTAssertEqual(post.quotedPost?.sensitive, .violence, "a quote is not a way to read around a cover")
        XCTAssertEqual(post.quotedPost?.sensitiveNote, "Crash footage")
    }

    // MARK: - Sending

    private func encoded(_ draft: PostDraft) throws -> String {
        String(decoding: try JSONCoding.encoder.encode(CreatePostBody(draft: draft)), as: UTF8.self)
    }

    func testTheBodyCarriesTheWarningAndOmitsItWhenThereIsNone() throws {
        let plain = try encoded(PostDraft(text: "hello", scope: .international))
        XCTAssertFalse(plain.contains("sensitive"), "no warning, no field — not an explicit null")

        let warned = try encoded(PostDraft(
            text: "hello", scope: .international, sensitive: .spoiler, sensitiveNote: "  Episode 3  "
        ))
        XCTAssertTrue(warned.contains("\"sensitive\":\"spoiler\""))
        XCTAssertTrue(warned.contains("\"sensitive_note\":\"Episode 3\""), "trimmed")
    }

    func testANoteNeverTravelsAlone() throws {
        let body = try encoded(PostDraft(text: "hello", scope: .international, sensitiveNote: "orphan"))
        XCTAssertFalse(body.contains("sensitive_note"), "the server would refuse it, and should")
    }

    func testTheNoteIsCappedAtTheServersLimit() throws {
        let body = try encoded(PostDraft(
            text: "hello", scope: .international, sensitive: .other,
            sensitiveNote: String(repeating: "n", count: 200)
        ))
        XCTAssertTrue(body.contains(String(repeating: "n", count: SensitiveContentLimits.maximumNoteLength) + "\""))
        XCTAssertFalse(body.contains(String(repeating: "n", count: SensitiveContentLimits.maximumNoteLength + 1)))
    }

    // MARK: - The notification row

    private static func notification(excerpt: String?, sensitive: String?) -> String {
        let text = excerpt.map { "\"\($0)\"" } ?? "null"
        let kind = sensitive.map { "\"\($0)\"" } ?? "null"
        return """
        {"id": "11111111-0000-4000-8000-000000000001", "kind": "reply",
         "actor": {"id": "22222222-0000-4000-8000-000000000002", "handle": "noura",
                   "display_name": "Noura", "avatar_url": null, "is_verified": true,
                   "country_code": "SA", "verified_since": null},
         "post_id": "6f6d1a3e-0000-4000-8000-00000000ab01", "post_excerpt": \(text),
         "post_sensitive": \(kind), "read": false, "created_at": "2026-09-05T10:00:00Z"}
        """
    }

    func testACoveredPostWithNoNoteIsNotADeletedPost() throws {
        let row: UserNotification = try decode(Self.notification(excerpt: nil, sensitive: "spoiler"))
        XCTAssertEqual(row.postSensitive, .spoiler)
        XCTAssertFalse(row.postWasDeleted, "no excerpt because it is covered, not because it is gone")
        XCTAssertTrue(row.accessibilityDescription.contains(NotificationCopy.covered(.spoiler, note: nil)))

        let gone: UserNotification = try decode(Self.notification(excerpt: nil, sensitive: nil))
        XCTAssertTrue(gone.postWasDeleted)
    }

    func testTheRowShowsTheKindAndTheNoteNeverTheWords() throws {
        let row: UserNotification = try decode(Self.notification(excerpt: "Final score inside", sensitive: "violence"))
        let line = NotificationCopy.covered(.violence, note: row.postExcerpt)
        XCTAssertTrue(line.contains("Final score inside"))
        XCTAssertTrue(line.lowercased().contains("violent"))
        XCTAssertNotEqual(NotificationCopy.covered(.spoiler, note: nil), NotificationCopy.covered(.violence, note: nil))
    }

    // MARK: - Copy

    func testEveryKindHasItsOwnTitle() {
        let titles = Set(SensitiveKind.allCases.map(SensitiveCopy.title))
        XCTAssertEqual(titles.count, SensitiveKind.allCases.count, "three promises, three sentences")
        XCTAssertTrue(SensitiveCopy.title(.spoiler).lowercased().contains("spoiler"))
        XCTAssertTrue(SensitiveCopy.title(.violence).lowercased().contains("violen"))
        XCTAssertFalse(SensitiveCopy.accessibilityLabel(.spoiler, note: "Episode 3").isEmpty)
        XCTAssertTrue(SensitiveCopy.quotedLabel(.violence, note: nil).contains(SensitiveCopy.title(.violence)))
    }
}
