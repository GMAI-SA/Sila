import XCTest
@testable import Sila

/// Contract v37: the automated news account and its posts decode, and nothing
/// about them can blank a feed or make an ordinary account look like news.
final class NewsAccountTests: XCTestCase {

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONCoding.decoder.decode(T.self, from: Data(json.utf8))
    }

    private let newsAuthor = """
    {"id": "6f1c3a52-9a0e-4c55-9d43-0e2f6a1b7c01", "handle": "knownnews",
     "display_name": "Known News", "display_name_ar": "أخبار معروف",
     "account_type": "news", "avatar_url": null, "is_verified": false,
     "country_code": null, "verified_since": null, "verified_name": null, "vouched_by": null}
    """

    private let personAuthor = """
    {"id": "2b7d1e44-5c3f-4a8e-b1d2-9f0a3c6e8b02", "handle": "yuki",
     "display_name": "Yuki Tanaka", "is_verified": true, "country_code": "SA"}
    """

    private func postJSON(author: String, extra: String = "") -> String {
        """
        {"id": "9d2a6b10-3e4f-4c1a-8b7d-5e6f7a8b9c03", "author": \(author),
         "text": "ملخص عربي", "language": "ar", "created_at": "2026-10-13T08:20:00Z",
         "scope": "country", "scope_country": "SA", "reply_count_direct": 0,
         "metrics": {"likes": 0, "reposts": 0, "replies": 0, "views": 0, "bookmarks": 0},
         "viewer": {}\(extra)}
        """
    }

    private let newsBlock = """
    , "news": {"url": "https://www.arabnews.com/node/123", "title": "Saudi Arabia launches a programme",
     "source_name": "Arab News", "source_name_ar": "عرب نيوز", "source_domain": "arabnews.com",
     "published_at": "2026-10-13T08:10:00Z", "summary_ar": "ملخص عربي", "summary_en": "An English summary.",
     "image_url": null, "countries": ["SA"]}
    """

    // MARK: - Author

    func testTheNewsAccountDecodesAsNews() throws {
        let user = try decode(UserSummary.self, newsAuthor)
        XCTAssertEqual(user.accountType, .news)
        XCTAssertTrue(user.isNewsAccount)
        XCTAssertEqual(user.displayNameAr, "أخبار معروف")
        XCTAssertFalse(user.isVerified)
        XCTAssertNil(user.countryCode)
        XCTAssertNil(user.avatarURL)
    }

    func testTheArabicNameIsShownInAnArabicInterfaceOnly() throws {
        let user = try decode(UserSummary.self, newsAuthor)
        XCTAssertEqual(L10n.withLanguage("en") { user.displayName }, "Known News")
        if L10n.language(for: "ar") != nil {
            XCTAssertEqual(L10n.withLanguage("ar") { user.displayName }, "أخبار معروف")
        }
    }

    func testAMissingAccountTypeIsAPerson() throws {
        let user = try decode(UserSummary.self, personAuthor)
        XCTAssertEqual(user.accountType, .person)
        XCTAssertFalse(user.isNewsAccount)
        XCTAssertNil(user.displayNameAr)
        XCTAssertTrue(user.isVerified)
        XCTAssertEqual(user.countryCode, "SA")
        XCTAssertEqual(user.displayName, "Yuki Tanaka")
    }

    func testAnUnknownAccountTypeIsAPerson() throws {
        let json = personAuthor.replacingOccurrences(of: "\"handle\"", with: "\"account_type\": \"robot\", \"handle\"")
        let user = try decode(UserSummary.self, json)
        XCTAssertEqual(user.accountType, .person)
        XCTAssertTrue(user.isVerified, "an unknown type must not strip a person's seal")
    }

    func testAMalformedAccountTypeIsAPerson() throws {
        let json = personAuthor.replacingOccurrences(of: "\"handle\"", with: "\"account_type\": 7, \"handle\"")
        let user = try decode(UserSummary.self, json)
        XCTAssertEqual(user.accountType, .person)
    }

    func testTheNewsAccountNeverWearsTheSealOrAFlagWhateverArrives() throws {
        let json = newsAuthor
            .replacingOccurrences(of: "\"is_verified\": false", with: "\"is_verified\": true")
            .replacingOccurrences(of: "\"country_code\": null", with: "\"country_code\": \"SA\"")
        let user = try decode(UserSummary.self, json)
        XCTAssertFalse(user.isVerified)
        XCTAssertNil(user.countryCode)
    }

    func testTheNewsFlagSurvivesTheSessionCopy() throws {
        let user = try decode(UserSummary.self, newsAuthor)
        let data = try JSONEncoder().encode(user)
        let decoder = JSONDecoder()
        let again = try decoder.decode(UserSummary.self, from: data)
        XCTAssertEqual(again.accountType, .news)
        XCTAssertEqual(again.displayNameAr, "أخبار معروف")
        XCTAssertEqual(L10n.withLanguage("en") { again.displayName }, "Known News")
    }

    // MARK: - Posts

    func testANewsPostDecodesItsArticle() throws {
        let post = try decode(Post.self, postJSON(author: newsAuthor, extra: newsBlock))
        let news = try XCTUnwrap(post.news)
        XCTAssertTrue(post.author.isNewsAccount)
        XCTAssertEqual(news.url?.absoluteString, "https://www.arabnews.com/node/123")
        XCTAssertEqual(news.title, "Saudi Arabia launches a programme")
        XCTAssertEqual(news.sourceName, "Arab News")
        XCTAssertEqual(news.sourceNameAr, "عرب نيوز")
        XCTAssertEqual(news.displayDomain, "arabnews.com")
        XCTAssertNotNil(news.publishedAt)
        XCTAssertNil(news.imageURL)
        XCTAssertEqual(news.countries, ["SA"])
        XCTAssertEqual(news.summaries(languageCode: "ar").map { $0.language }, ["ar", "en"])
        XCTAssertEqual(news.summaries(languageCode: "en").map { $0.language }, ["en", "ar"])
        XCTAssertEqual(news.summaries(languageCode: "fr").first?.text, "An English summary.")
        XCTAssertEqual(news.sourceDisplayName(languageCode: "ar"), "عرب نيوز")
        XCTAssertEqual(news.sourceDisplayName(languageCode: "en"), "Arab News")
    }

    func testAPersonsPostHasNoArticle() throws {
        let plain = try decode(Post.self, postJSON(author: personAuthor))
        XCTAssertNil(plain.news)
        let explicitNull = try decode(Post.self, postJSON(author: personAuthor, extra: ", \"news\": null"))
        XCTAssertNil(explicitNull.news)
        XCTAssertEqual(explicitNull.text, "ملخص عربي")
    }

    func testAMalformedArticleCostsTheCardNeverThePost() throws {
        let broken = try decode(Post.self, postJSON(author: newsAuthor, extra: ", \"news\": \"oops\""))
        XCTAssertNil(broken.news)
        XCTAssertEqual(broken.text, "ملخص عربي")
        let empty = try decode(Post.self, postJSON(author: newsAuthor, extra: ", \"news\": {}"))
        XCTAssertNil(empty.news, "an article with no link and no summary is nothing to draw")
    }

    func testOnlyWebLinksAreKept() throws {
        let block = newsBlock.replacingOccurrences(of: "https://www.arabnews.com/node/123", with: "javascript:alert(1)")
        let post = try decode(Post.self, postJSON(author: newsAuthor, extra: block))
        XCTAssertNil(post.news?.url)
        XCTAssertNotNil(post.news, "the summaries still stand")
        XCTAssertNil(PostNews.webURL("file:///etc/passwd"))
        XCTAssertNil(PostNews.webURL("/relative/path"))
        XCTAssertNotNil(PostNews.webURL("http://example.com/a"))
    }

    func testAFeedPageWithANewsPostAndAPersonsPostDecodesBoth() throws {
        let json = "{\"posts\": [\(postJSON(author: newsAuthor, extra: newsBlock)), \(postJSON(author: personAuthor))], \"next_cursor\": null, \"has_more\": false}"
        let page = try decode(FeedPage.self, json)
        XCTAssertEqual(page.posts.count, 2)
        XCTAssertNotNil(page.posts[0].news)
        XCTAssertNil(page.posts[1].news)
    }

    // MARK: - Safety

    @MainActor
    func testTheNewsAccountCannotBeReportedAsAnImpostor() throws {
        let news = try decode(UserSummary.self, newsAuthor)
        let person = try decode(UserSummary.self, personAuthor)
        XCTAssertTrue(SafetyTarget(user: news).isNewsAccount)
        XCTAssertFalse(SafetyTarget(user: person).isNewsAccount)
        XCTAssertEqual(SafetyTarget(user: news), SafetyTarget(handle: "knownnews", name: news.displayName),
                       "the flag does not make it a different target")
    }
}
