import XCTest
@testable import Sila

/// Numbers, dates and plural rules under both languages.
///
/// Two decisions are asserted here that a reader might otherwise think are
/// accidents:
///
/// * **Arabic gets Arabic plural grammar** — all six categories, from the
///   catalog, never from an `if count == 1`.
/// * **Arabic keeps Western digits.** CLDR's default numbering system for
///   Arabic is `arab` (`١٢٣`), and every formatter would produce it unasked.
///   Saudi product UI does not: banks, government portals and every competing
///   social app show `123`. A follower count in Arabic-Indic digits reads as a
///   rendering fault, not as localisation.
final class LocalizedFormattingTests: XCTestCase {

    override func tearDown() {
        L10n.use(nil)
        super.tearDown()
    }

    private func withArabic(_ body: () -> Void) {
        guard L10n.use("ar") else {
            return XCTFail("the build has no Arabic resources — the catalog did not compile")
        }
        body()
        L10n.use(nil)
    }

    // MARK: - Language selection

    /// The build ships both languages, and asking for one that is not there
    /// fails loudly instead of quietly serving English.
    func testLanguageSelection() {
        XCTAssertTrue(L10n.use("ar"))
        XCTAssertEqual(L10n.languageCode, "ar")
        XCTAssertTrue(L10n.isRightToLeft)

        XCTAssertTrue(L10n.use("en"))
        XCTAssertEqual(L10n.languageCode, "en")
        XCTAssertFalse(L10n.isRightToLeft)

        XCTAssertFalse(L10n.use("xx"), "a missing language must not silently fall back")
        XCTAssertEqual(L10n.languageCode, "en", "the failed switch left the previous language alone")
    }

    /// `withLanguage` restores whatever was there before, including on a throw.
    func testWithLanguageRestoresThePreviousState() {
        L10n.use("en")
        struct Boom: Error {}
        XCTAssertThrowsError(
            try L10n.withLanguage("ar") {
                XCTAssertEqual(L10n.languageCode, "ar")
                throw Boom()
            }
        )
        XCTAssertEqual(L10n.languageCode, "en")
    }

    /// A key with no catalog entry renders as itself rather than as a blank.
    func testMissingKeyIsVisibleRatherThanSilent() {
        XCTAssertEqual(L10n.t("no.such.key.exists"), "no.such.key.exists")
    }

    // MARK: - Arabic plural categories

    /// The six categories, each on a count that only that category covers.
    ///
    /// This is the test that would have caught the `count == 1 ? … : …`
    /// pattern the whole codebase used before: every one of these counts
    /// except `1` would have taken the same branch.
    func testArabicPluralsResolveThroughAllSixCategories() {
        withArabic {
            XCTAssertEqual(L10n.plural("post.likes.count.accessibility", 0), "لا إعجابات", "zero")
            XCTAssertEqual(L10n.plural("post.likes.count.accessibility", 1), "إعجاب واحد", "one")
            XCTAssertEqual(L10n.plural("post.likes.count.accessibility", 2), "إعجابان", "two")
            XCTAssertEqual(L10n.plural("post.likes.count.accessibility", 3), "3 إعجابات", "few")
            XCTAssertEqual(L10n.plural("post.likes.count.accessibility", 10), "10 إعجابات", "few, upper bound")
            XCTAssertEqual(L10n.plural("post.likes.count.accessibility", 11), "11 إعجابًا", "many")
            XCTAssertEqual(L10n.plural("post.likes.count.accessibility", 99), "99 إعجابًا", "many, upper bound")
            XCTAssertEqual(L10n.plural("post.likes.count.accessibility", 100), "100 إعجاب", "other")
            XCTAssertEqual(L10n.plural("post.likes.count.accessibility", 1_000), "1,000 إعجاب", "other")
        }
    }

    /// Arabic's categories repeat every hundred — 103 is "few", not "other".
    ///
    /// No hand-written branch has ever got this right by accident.
    func testArabicPluralCategoriesRepeatAcrossHundreds() {
        withArabic {
            XCTAssertEqual(L10n.plural("post.likes.count.accessibility", 103), "103 إعجابات", "103 is few")
            XCTAssertEqual(L10n.plural("post.likes.count.accessibility", 111), "111 إعجابًا", "111 is many")
            XCTAssertEqual(L10n.plural("post.likes.count.accessibility", 101), "101 إعجاب", "101 is other")
        }
    }

    /// English still gets English grammar out of the same key.
    func testEnglishPluralsAreUnchanged() {
        L10n.use("en")
        XCTAssertEqual(L10n.plural("post.likes.count.accessibility", 1), "1 like")
        XCTAssertEqual(L10n.plural("post.likes.count.accessibility", 2), "2 likes")
        XCTAssertEqual(L10n.plural("post.likes.count.accessibility", 0), "0 likes")
    }

    // MARK: - Western digits

    /// Every number-bearing formatter, in Arabic, with Latin digits.
    func testArabicKeepsWesternDigits() {
        withArabic {
            let samples = [
                SLFormat.number(1_234_567),
                SLFormat.compactCount(1_200),
                SLFormat.compactCount(3_400_000),
                SLFormat.date(Date(timeIntervalSince1970: 1_760_000_000)),
                SLFormat.dateTime(Date(timeIntervalSince1970: 1_760_000_000)),
                SLFormat.monthAndYear(Date(timeIntervalSince1970: 1_760_000_000)),
                SLFormat.seconds(125),
                L10n.plural("post.likes.count.accessibility", 42)
            ]
            for sample in samples {
                XCTAssertFalse(
                    sample.unicodeScalars.contains { (0x0660...0x0669).contains($0.value) },
                    "'\(sample)' contains Arabic-Indic digits"
                )
                XCTAssertFalse(
                    sample.unicodeScalars.contains { (0x06F0...0x06F9).contains($0.value) },
                    "'\(sample)' contains Eastern Arabic-Indic digits"
                )
            }
        }
    }

    /// The formatting locale is Arabic for its *rules* and Latin for its digits.
    func testFormattingLocaleKeepsArabicRulesAndLatinDigits() {
        withArabic {
            XCTAssertEqual(L10n.formattingLocale.language.languageCode?.identifier, "ar")
            XCTAssertEqual(L10n.formattingLocale.numberingSystem.identifier, "latn")
        }
    }

    // MARK: - Numbers

    func testGroupedIntegers() {
        L10n.use("en")
        XCTAssertEqual(SLFormat.number(0), "0")
        XCTAssertEqual(SLFormat.number(999), "999")
        XCTAssertEqual(SLFormat.number(1_000), "1,000")
        XCTAssertEqual(SLFormat.number(1_234_567), "1,234,567")
    }

    /// The English abbreviations are byte-identical to the hand-rolled ones
    /// they replaced, which is what keeps the existing feed tests honest.
    func testCompactCountsMatchTheirEnglishPredecessor() {
        L10n.use("en")
        XCTAssertEqual(SLFormat.compactCount(0), "0")
        XCTAssertEqual(SLFormat.compactCount(999), "999")
        XCTAssertEqual(SLFormat.compactCount(1_000), "1K")
        XCTAssertEqual(SLFormat.compactCount(1_200), "1.2K")
        XCTAssertEqual(SLFormat.compactCount(12_000), "12K")
        XCTAssertEqual(SLFormat.compactCount(1_500_000), "1.5M")
        XCTAssertEqual(SLFormat.compactCount(12_000_000), "12M")
    }

    /// An abbreviation never rounds a count up. Claiming fifty followers
    /// somebody does not have is a worse error than a blunt number.
    func testCompactCountsRoundDown() {
        L10n.use("en")
        XCTAssertEqual(SLFormat.compactCount(1_090), "1K")
        XCTAssertEqual(SLFormat.compactCount(1_999), "1.9K")
    }

    /// Arabic abbreviates with its own words, not with `K` and `M`.
    func testArabicCompactCountsUseArabicSuffixes() {
        withArabic {
            XCTAssertTrue(SLFormat.compactCount(1_200).contains("ألف"), SLFormat.compactCount(1_200))
            XCTAssertTrue(SLFormat.compactCount(3_400_000).contains("مليون"), SLFormat.compactCount(3_400_000))
        }
    }

    // MARK: - Dates

    /// Dates speak Arabic — month names included.
    func testDatesAreLocalised() {
        let moment = Date(timeIntervalSince1970: 1_760_000_000)

        L10n.use("en")
        let english = SLFormat.monthAndYear(moment)
        XCTAssertTrue(english.contains("October"), english)

        withArabic {
            let arabic = SLFormat.monthAndYear(moment)
            XCTAssertFalse(arabic.contains("October"), arabic)
            XCTAssertTrue(
                arabic.unicodeScalars.contains { (0x0600...0x06FF).contains($0.value) },
                "the Arabic month name never arrived: \(arabic)"
            )
        }
    }

    /// Relative time picks up Arabic's dual — "قبل ساعتين", not "قبل 2 ساعة".
    /// A hand-written formatter in this codebase would not have.
    func testRelativeTimeUsesArabicDualForm() {
        withArabic {
            let twoHoursAgo = SLFormat.relative(Date(timeIntervalSinceNow: -7_200))
            XCTAssertTrue(twoHoursAgo.contains("ساعتين"), twoHoursAgo)
        }
    }

    // MARK: - Durations

    func testSecondsReadAsAClock() {
        L10n.use("en")
        XCTAssertEqual(SLFormat.seconds(0), "0")
        XCTAssertEqual(SLFormat.seconds(45), "45")
        XCTAssertEqual(SLFormat.seconds(60), "1:00")
        XCTAssertEqual(SLFormat.seconds(125), "2:05")
        XCTAssertEqual(SLFormat.seconds(-5), "0", "a negative countdown is zero, not '-5'")
    }
}
