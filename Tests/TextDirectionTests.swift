import XCTest
import SwiftUI
@testable import Sila

/// The rule this file exists to hold: **a post's direction comes from the post,
/// not from the app.**
///
/// Sila's users read Arabic and quote English at each other all day. If the
/// feed laid every post out in the interface's direction, an Arabic post read
/// on an English phone would be left-aligned with its full stop on the wrong
/// end, and an English post read on an Arabic phone would be right-aligned with
/// its bullet points reversed. Both are the same bug, and both are what these
/// tests refuse to let back in.
final class TextDirectionTests: XCTestCase {

    override func tearDown() {
        L10n.use(nil)
        LanguageDirectory.shared.clear()
        super.tearDown()
    }

    private func post(text: String, language: String? = nil) -> Post {
        Post(
            id: UUID(),
            author: UserSummary(id: UUID(), handle: "aziz", displayName: "عبدالعزيز", isVerified: true),
            text: text,
            createdAt: Date(),
            language: language
        )
    }

    // MARK: - The headline case

    /// An Arabic post rendered by an app running in English still reads
    /// right-to-left.
    func testArabicPostIsRightToLeftWhileTheAppRunsInEnglish() {
        L10n.use("en")
        XCTAssertFalse(L10n.isRightToLeft, "precondition: the interface is left-to-right")

        let arabic = post(text: "الرياض اليوم فيها جو حلو", language: "ar")
        XCTAssertEqual(TextDirection.of(arabic), .rightToLeft)
        XCTAssertEqual(TextDirection.of(arabic).layoutDirection, LayoutDirection.rightToLeft)
    }

    /// And the mirror image: an English post inside an Arabic app.
    func testEnglishPostIsLeftToRightWhileTheAppRunsInArabic() {
        guard L10n.use("ar") else {
            return XCTFail("the build has no Arabic resources")
        }
        XCTAssertTrue(L10n.isRightToLeft, "precondition: the interface is right-to-left")

        let english = post(text: "Shipping the Arabic build tonight.", language: "en")
        XCTAssertEqual(TextDirection.of(english), .leftToRight)
    }

    // MARK: - Where the answer comes from

    /// The server's `language` outranks the text.
    ///
    /// A mostly-English Arabic post — a quote, a link, a product name — starts
    /// with a strong Latin character, and the character scan would call it
    /// left-to-right. The server saw the whole post.
    func testServerLanguageOutranksTheFirstStrongCharacter() {
        L10n.use("en")
        let mixed = post(text: "SwiftUI ما يدعم هذا الشيء بشكل تلقائي", language: "ar")
        XCTAssertEqual(TextDirection.firstStrongDirection(in: mixed.text), .leftToRight)
        XCTAssertEqual(TextDirection.of(mixed), .rightToLeft, "the server's language must win")
    }

    /// With no `language`, the Unicode bidi algorithm's first-strong rule decides.
    func testFallsBackToTheFirstStrongCharacterWhenTheServerSentNoLanguage() {
        L10n.use("en")
        XCTAssertEqual(TextDirection.of(post(text: "مرحبا everyone")), .rightToLeft)
        XCTAssertEqual(TextDirection.of(post(text: "Hello للجميع")), .leftToRight)
    }

    /// Digits, punctuation and emoji carry no direction, so they are skipped
    /// rather than treated as left-to-right.
    func testWeakAndNeutralCharactersAreSkipped() {
        XCTAssertEqual(TextDirection.firstStrongDirection(in: "2026 — 👋 السلام عليكم"), .rightToLeft)
        XCTAssertEqual(TextDirection.firstStrongDirection(in: "  #1! (2026) hello"), .leftToRight)
    }

    /// Content with no direction of its own inherits the interface's, rather
    /// than being assigned one.
    func testDirectionlessContentInheritsTheInterface() {
        XCTAssertNil(TextDirection.firstStrongDirection(in: "2026 🎉 — 100%"))

        L10n.use("en")
        XCTAssertEqual(TextDirection.of(post(text: "2026 🎉")), .leftToRight)

        guard L10n.use("ar") else { return XCTFail("the build has no Arabic resources") }
        XCTAssertEqual(TextDirection.of(post(text: "2026 🎉")), .rightToLeft)
    }

    /// An empty post does not crash and does not invent a direction.
    func testEmptyTextInheritsTheInterface() {
        L10n.use("en")
        XCTAssertEqual(TextDirection.of(post(text: "")), .leftToRight)
    }

    // MARK: - The server's language directory

    /// `GET /languages` is the authority, including when it disagrees with the
    /// script table.
    func testTheServerDirectoryOverridesTheBuiltInScriptTable() {
        let directory = LanguageDirectory(options: [
            LanguageOption(code: "ku", name: "Kurdish", nativeName: "کوردی", rtl: false)
        ])
        XCTAssertEqual(directory.isRightToLeft("ku"), false)
        XCTAssertEqual(
            TextDirection.resolve(languageCode: "ku", text: nil, directory: directory),
            .leftToRight
        )
    }

    /// A language the server never mentioned falls back to the script table…
    func testUnlistedRightToLeftLanguageStillResolvesFromItsScript() {
        let directory = LanguageDirectory(options: [
            LanguageOption(code: "en", name: "English", nativeName: "English", rtl: false)
        ])
        XCTAssertEqual(directory.isRightToLeft("fa"), true)
    }

    /// …and a language neither knows returns `nil`, so the caller looks at the
    /// text instead of trusting a fabricated `false`.
    func testGenuinelyUnknownLanguageReturnsNilRatherThanGuessing() {
        let directory = LanguageDirectory(options: [])
        XCTAssertNil(directory.isRightToLeft("zz"))
        XCTAssertEqual(
            TextDirection.resolve(languageCode: "zz", text: "نص عربي", directory: directory),
            .rightToLeft,
            "an unknown language must defer to the text, not left-align it"
        )
    }

    /// Region subtags do not change a script's direction.
    func testRegionSubtagsAreIgnored() {
        let directory = LanguageDirectory(options: [
            LanguageOption(code: "ar", name: "Arabic", nativeName: "العربية", rtl: true),
            LanguageOption(code: "en", name: "English", nativeName: "English", rtl: false)
        ])
        XCTAssertEqual(directory.isRightToLeft("ar-SA"), true)
        XCTAssertEqual(directory.isRightToLeft("ar_EG"), true)
        XCTAssertEqual(directory.isRightToLeft("EN-GB"), false)
    }

    // MARK: - Decoding

    /// A post decodes its `language` and normalises it.
    func testPostDecodesAndNormalisesItsLanguage() throws {
        let json = """
        {
          "id": "\(UUID().uuidString)",
          "author": {"id": "\(UUID().uuidString)", "handle": "aziz", "display_name": "عبدالعزيز", "is_verified": true},
          "text": "مرحبا",
          "language": "AR-sa",
          "created_at": "2026-08-28T09:15:00Z",
          "scope": "international"
        }
        """
        let decoded = try JSONCoding.decoder.decode(Post.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.language, "ar")
        XCTAssertEqual(TextDirection.of(decoded), .rightToLeft)
    }

    /// A post with no `language` field decodes to `nil`, not to a guess.
    func testMissingLanguageDecodesToNil() throws {
        let json = """
        {
          "id": "\(UUID().uuidString)",
          "author": {"id": "\(UUID().uuidString)", "handle": "aziz", "display_name": "Aziz", "is_verified": true},
          "text": "hello",
          "created_at": "2026-08-28T09:15:00Z",
          "scope": "international"
        }
        """
        let decoded = try JSONCoding.decoder.decode(Post.self, from: Data(json.utf8))
        XCTAssertNil(decoded.language)
    }

    /// An empty `language` is the same fact as a missing one.
    func testBlankLanguageDecodesToNil() throws {
        let json = """
        {
          "id": "\(UUID().uuidString)",
          "author": {"id": "\(UUID().uuidString)", "handle": "aziz", "display_name": "Aziz", "is_verified": true},
          "text": "hello",
          "language": "",
          "created_at": "2026-08-28T09:15:00Z",
          "scope": "international"
        }
        """
        let decoded = try JSONCoding.decoder.decode(Post.self, from: Data(json.utf8))
        XCTAssertNil(decoded.language)
    }

    /// A `LanguageOption` with no `rtl` field answers from its script rather
    /// than defaulting to `false` and left-aligning every Arabic post.
    func testLanguageOptionWithoutRtlFlagInfersFromScript() throws {
        let json = """
        [{"code": "ar", "name": "Arabic", "native_name": "العربية"},
         {"code": "en", "name": "English", "native_name": "English"}]
        """
        let decoded = try JSONCoding.decoder.decode([LanguageOption].self, from: Data(json.utf8))
        XCTAssertEqual(decoded.first(where: { $0.code == "ar" })?.rtl, true)
        XCTAssertEqual(decoded.first(where: { $0.code == "en" })?.rtl, false)
    }

    /// The endpoint's response decodes whether it is wrapped or bare.
    func testLanguagesResponseAcceptsBothEnvelopes() throws {
        let wrapped = """
        {"languages": [{"code": "ar", "name": "Arabic", "native_name": "العربية", "rtl": true}]}
        """
        let bare = """
        [{"code": "ar", "name": "Arabic", "native_name": "العربية", "rtl": true}]
        """
        for payload in [wrapped, bare] {
            let decoded = try JSONCoding.decoder.decode(LanguagesResponse.self, from: Data(payload.utf8))
            XCTAssertEqual(decoded.languages.map(\.code), ["ar"])
            XCTAssertEqual(decoded.languages.first?.rtl, true)
        }
    }

    /// Fetching populates the directory the views read.
    func testFetchingLanguagesPopulatesTheSharedDirectory() async throws {
        LanguageDirectory.shared.clear()
        let options = try await LanguageServiceMock().fetchLanguages()
        XCTAssertFalse(options.isEmpty)
        XCTAssertEqual(LanguageDirectory.shared.isRightToLeft("ur"), true)
        XCTAssertEqual(LanguageDirectory.shared.isRightToLeft("fr"), false)
    }
}
