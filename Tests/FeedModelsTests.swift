import XCTest
@testable import Sila

/// The country tab wears the everyday name, and only when it fits.
final class CountryTabNameTests: XCTestCase {

    func testTheFormalArabicNameOfSaudiArabiaBecomesTheEverydayOne() {
        let arabic = Locale(identifier: "ar")
        XCTAssertEqual(CountryCode.shortName("SA", locale: arabic), "السعودية")
        XCTAssertEqual(CountryCode.shortName("AE", locale: arabic), "الإمارات")
        XCTAssertEqual(FeedTab.myCountry.title(countryCode: "SA").isEmpty, false)
    }

    func testEnglishKeepsShortFormalNamesAndAbbreviatesTheLongOnes() {
        let english = Locale(identifier: "en")
        XCTAssertEqual(CountryCode.shortName("SA", locale: english), "Saudi Arabia")
        XCTAssertEqual(CountryCode.shortName("AE", locale: english), "UAE")
        XCTAssertEqual(CountryCode.shortName("EG", locale: english), "Egypt")
    }

    func testANameTooLongForATabAnswersNothingSoTheGenericLabelIsUsed() {
        // Nothing everyday is on file for it, and the localized name is long.
        XCTAssertNil(CountryCode.shortName("VC", locale: Locale(identifier: "fr"), limit: 8))
        XCTAssertNil(CountryCode.shortName(nil))
        XCTAssertNil(CountryCode.shortName("ZZ"))
    }
}
