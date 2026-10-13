import CoreSpotlight
import XCTest
@testable import Sila

/// The app's own Spotlight entry: "social" must find Known, in every language.
final class AppSearchIndexTests: XCTestCase {

    func testKeywordsAlwaysCarryTheFixedEnglishAndArabicWords() {
        for code in ["en", "ar", "de"] {
            let keywords = L10n.withLanguage(code) { AppSearchIndex.keywords() }
            for word in ["social", "social network", "community", "verified", "known", "rooms",
                         "معروف", "تواصل اجتماعي", "شبكة اجتماعية", "موثق"] {
                XCTAssertTrue(keywords.contains(word), "\(code): missing \(word)")
            }
        }
    }

    func testEachLanguageAddsItsOwnWordForSocialWithoutDuplicates() {
        let expected = ["de": "soziales Netzwerk", "fr": "réseau social", "ja": "SNS",
                        "ru": "соцсеть", "tr": "sosyal ağ", "zh-Hans": "社交"]
        for (code, word) in expected {
            let keywords = L10n.withLanguage(code) { AppSearchIndex.keywords() }
            XCTAssertTrue(keywords.contains(word), "\(code): missing \(word) in \(keywords)")
            XCTAssertEqual(Set(keywords.map { $0.lowercased() }).count, keywords.count, "\(code): duplicates")
            XCTAssertFalse(keywords.contains("app.spotlight.keywords"))
        }
    }

    func testItemIsTitledWithTheProductNameAndDescribedInTheLanguage() {
        let english = L10n.withLanguage("en") { AppSearchIndex.makeItem() }
        XCTAssertEqual(english.attributeSet.title, "Known")
        XCTAssertEqual(english.domainIdentifier, "app.known.search")
        XCTAssertTrue(english.attributeSet.contentDescription?.contains("social network") == true)

        let arabic = L10n.withLanguage("ar") { AppSearchIndex.makeItem() }
        XCTAssertEqual(arabic.attributeSet.title, "معروف")
        XCTAssertTrue(arabic.attributeSet.contentDescription?.contains("الشبكة الاجتماعية") == true)
    }

    func testStampChangesWithLanguage() {
        XCTAssertNotEqual(AppSearchIndex.stamp(language: "en"), AppSearchIndex.stamp(language: "ar"))
    }
}
