import XCTest
@testable import Sila

/// Avatar paths arrive root-relative and must be resolved before use.
///
/// The server returns `avatar_url` as `/api/v1/media/avatars/<file>.jpg`.
/// `URL(string:)` accepts that happily and yields a URL with no scheme and no
/// host, which `AsyncImage` cannot fetch. The failure mode is the quiet kind:
/// no error, no crash, just an avatar that is permanently blank — which looks
/// like "nobody set a picture" rather than like a bug.
///
/// It stayed latent until contract v5 because uploading a picture was not
/// possible, so the field was always `null`.
final class AvatarURLResolutionTests: XCTestCase {

    private func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        try JSONCoding.decoder.decode(T.self, from: Data(json.utf8))
    }

    private func userSummary(avatar: String) -> String {
        """
        {
          "id": "6c1b1f7e-5a3d-4b2a-9d21-0c1f2a3b4c5d",
          "handle": "aziz",
          "display_name": "Abdulaziz",
          "avatar_url": \(avatar),
          "is_verified": true,
          "country_code": "SA",
          "verified_since": "2026-08-28T09:15:00Z"
        }
        """
    }

    // MARK: - The resolver

    func testARootRelativePathBecomesLoadable() {
        let resolved = AppConfig.mediaURL("/api/v1/media/avatars/abc.jpg")
        XCTAssertEqual(resolved?.scheme, "https")
        XCTAssertEqual(resolved?.host, "sila.gmai.sa")
        XCTAssertEqual(resolved?.path, "/api/v1/media/avatars/abc.jpg")
    }

    /// If the server ever starts sending absolute URLs (a CDN, say), they must
    /// pass through untouched rather than being re-based onto the API origin.
    func testAnAbsoluteURLIsLeftAlone() {
        let resolved = AppConfig.mediaURL("https://cdn.example.com/a.jpg")
        XCTAssertEqual(resolved?.absoluteString, "https://cdn.example.com/a.jpg")
    }

    func testEmptyAndNilBecomeNil() {
        XCTAssertNil(AppConfig.mediaURL(nil))
        XCTAssertNil(AppConfig.mediaURL(""))
    }

    // MARK: - Every type that carries an avatar

    /// `UserSummary` is the author on every post in every feed, so this one
    /// decode governs whether avatars render anywhere at all.
    func testPostAuthorAvatarResolvesToAnAbsoluteURL() throws {
        let user = try decode(
            UserSummary.self,
            from: userSummary(avatar: "\"/api/v1/media/avatars/abc.jpg\"")
        )
        let url = try XCTUnwrap(user.avatarURL)
        XCTAssertNotNil(url.host, "a hostless URL cannot be loaded by AsyncImage")
        XCTAssertEqual(url.absoluteString, "https://sila.gmai.sa/api/v1/media/avatars/abc.jpg")
    }

    func testSignedInUserAvatarResolvesToAnAbsoluteURL() throws {
        let json = """
        {
          "id": "6c1b1f7e-5a3d-4b2a-9d21-0c1f2a3b4c5d",
          "email": "aziz@example.com",
          "handle": "aziz",
          "display_name": "Abdulaziz",
          "avatar_url": "/api/v1/media/avatars/abc.jpg",
          "verification_status": "verified",
          "country_code": "SA"
        }
        """
        let user = try decode(AuthUser.self, from: json)
        let url = try XCTUnwrap(user.avatarURL)
        XCTAssertNotNil(url.host)
        XCTAssertEqual(url.absoluteString, "https://sila.gmai.sa/api/v1/media/avatars/abc.jpg")
    }

    func testAMissingAvatarStaysNil() throws {
        let user = try decode(UserSummary.self, from: userSummary(avatar: "null"))
        XCTAssertNil(user.avatarURL)
    }
}
