import XCTest
@testable import Sila

/// The zone parser against ICAO's own specimens, and the repair pass against
/// the misreads a phone camera actually makes.
final class MRZParserTests: XCTestCase {

    private let td3 = """
    P<UTOERIKSSON<<ANNA<MARIA<<<<<<<<<<<<<<<<<<<
    L898902C36UTO7408122F1204159ZE184226B<<<<<10
    """

    private let td1 = """
    I<UTOD231458907<<<<<<<<<<<<<<<
    7408122F1204159UTO<<<<<<<<<<<6
    ERIKSSON<<ANNA<MARIA<<<<<<<<<<
    """

    private func utc(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    // MARK: - Check digits

    func testCheckDigitMatchesTheICAOWorkedExamples() {
        XCTAssertEqual(MRZParser.checkDigit("L898902C3"), "6")
        XCTAssertEqual(MRZParser.checkDigit("740812"), "2")
        XCTAssertEqual(MRZParser.checkDigit("120415"), "9")
        XCTAssertEqual(MRZParser.checkDigit("<<<<<<<<<<<<<<"), "0")
        XCTAssertNil(MRZParser.checkDigit("abc"), "lower case is not a zone character")
    }

    // MARK: - Specimens

    func testThePassportSpecimenParsesAndVerifies() throws {
        let zone = try XCTUnwrap(MRZParser.parse(td3))
        XCTAssertTrue(zone.isValid, "\(zone.errors)")
        XCTAssertEqual(zone.format, "TD3")
        XCTAssertEqual(zone.documentCode, "P")
        XCTAssertEqual(zone.documentNumber, "L898902C3")
        XCTAssertEqual(zone.nationalityRaw, "UTO")
        XCTAssertNil(zone.nationality, "a fictional issuer must not become a badge")
        XCTAssertEqual(zone.dateOfBirth, utc(1974, 8, 12))
        XCTAssertEqual(zone.expiryDate, utc(2012, 4, 15))
        XCTAssertEqual(zone.sex, "F")
        XCTAssertEqual(zone.surname, "ERIKSSON")
        XCTAssertEqual(zone.givenNames, "ANNA MARIA")
    }

    func testTheIDCardSpecimenParsesAndVerifies() throws {
        let zone = try XCTUnwrap(MRZParser.parse(td1))
        XCTAssertTrue(zone.isValid, "\(zone.errors)")
        XCTAssertEqual(zone.format, "TD1")
        XCTAssertEqual(zone.documentNumber, "D23145890")
        XCTAssertEqual(zone.dateOfBirth, utc(1974, 8, 12))
        XCTAssertEqual(zone.expiryDate, utc(2012, 4, 15))
        XCTAssertEqual(zone.surname, "ERIKSSON")
    }

    func testASingleMisreadCharacterIsRefused() throws {
        let tampered = td3.replacingOccurrences(of: "L898902C36", with: "L898902C86")
        let zone = try XCTUnwrap(MRZParser.parse(tampered))
        XCTAssertFalse(zone.isValid)
        XCTAssertTrue(zone.errors.contains("document_number"))
        XCTAssertTrue(zone.errors.contains("composite"))
    }

    func testSomethingThatIsNotAZoneIsNil() {
        XCTAssertNil(MRZParser.parse(""))
        XCTAssertNil(MRZParser.parse("hello world"))
        XCTAssertNil(MRZParser.parse("P<UTOERIKSSON<<ANNA<MARIA<<<<<<<<<<<<<<<<<<<"), "one line is not a zone")
    }

    func testWhitespaceAndCaseAreNotMisreads() throws {
        let noisy = "  p<utoeriksson<<anna<maria<<<<<<<<<<<<<<<<<<<  \n\n L898902C36UTO 7408122F1204159ZE184226B<<<<<10 \n"
        let zone = try XCTUnwrap(MRZParser.parse(noisy))
        XCTAssertTrue(zone.isValid)
    }

    // MARK: - Repair

    func testAnOForAZeroInTheBirthDateIsRepairedAndVerified() throws {
        // The camera read "74O812" — a letter O where a digit belongs.
        let misread = td3.replacingOccurrences(of: "7408122F", with: "74O8122F")
        XCTAssertFalse(MRZParser.parse(misread)?.isValid ?? true, "strict parse must refuse it")
        let repaired = try XCTUnwrap(MRZParser.parseRepairing(misread))
        XCTAssertTrue(repaired.isValid, "\(repaired.errors)")
        XCTAssertEqual(repaired.dateOfBirth, utc(1974, 8, 12))
        XCTAssertFalse(repaired.text.contains("74O8"), "the sent zone is the repaired one")
    }

    func testRepairNeverTouchesTheDocumentNumber() throws {
        // A genuine letter O in a document number must survive; only digit
        // fields are candidates for repair, and the composite decides.
        let number = "O12345678"
        let zone = try XCTUnwrap(MRZParser.parseRepairing(Self.passport(number: number, nationality: "USA")))
        XCTAssertTrue(zone.isValid, "\(zone.errors)")
        XCTAssertEqual(zone.documentNumber, number)
    }

    func testARepairThatDoesNotVerifyIsStillRefused() throws {
        let misread = td3.replacingOccurrences(of: "7408122F", with: "74O8132F")
        let zone = try XCTUnwrap(MRZParser.parseRepairing(misread))
        XCTAssertFalse(zone.isValid)
    }

    // MARK: - Countries

    func testAlpha3MapsToThePlatformsAlpha2() {
        XCTAssertEqual(CountryCode.fromAlpha3("USA"), "US")
        XCTAssertEqual(CountryCode.fromAlpha3("SAU"), "SA")
        XCTAssertEqual(CountryCode.fromAlpha3("ESP"), "ES")
        XCTAssertEqual(CountryCode.fromAlpha3("GBR"), "GB")
        XCTAssertEqual(CountryCode.fromAlpha3("D"), "DE", "Germany prints D in a zone")
        XCTAssertEqual(CountryCode.fromAlpha3("GBN"), "GB")
        XCTAssertEqual(CountryCode.fromAlpha3("egy"), "EG")
    }

    func testNonCountriesMapToNothing() {
        for code in ["UTO", "XXA", "XXB", "UNO", "EUE", "", "<<<", "ZZZ"] {
            XCTAssertNil(CountryCode.fromAlpha3(code), code)
        }
    }

    func testARealNationalityBecomesABadge() throws {
        let zone = try XCTUnwrap(MRZParser.parse(Self.passport(number: "X12345678", nationality: "SAU")))
        XCTAssertTrue(zone.isValid, "\(zone.errors)")
        XCTAssertEqual(zone.nationality, "SA")
        XCTAssertEqual(zone.issuingCountry, "SA")
    }

    // MARK: - Text from the camera

    func testTheZoneIsPickedOutOfEverythingElseOnThePage() {
        let lines = [
            "PASSPORT",
            "UNITED STATES OF AMERICA",
            "Surname DOE",
            "P<USADOE<<JOHN<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<",
            "X123456782USA9001013M3001019<<<<<<<<<<<<<<04"
        ]
        let zone = DocumentTextReader.zone(from: lines)
        XCTAssertEqual(zone?.components(separatedBy: "\n").count, 2)
        XCTAssertEqual(zone?.components(separatedBy: "\n").first, "P<USADOE<<JOHN<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<")
    }

    func testGuillemetsAreTheOneSubstitutionRepairedBeforeParsing() {
        let lines = [
            "P«USADOE««JOHN««««««««««««««««««««««««««««««",
            "X123456782USA9001013M3001019««««««««««««««04"
        ]
        XCTAssertNotNil(DocumentTextReader.zone(from: lines))
    }

    func testAPageWithoutAZoneYieldsNothing() {
        XCTAssertNil(DocumentTextReader.zone(from: ["DRIVER LICENSE", "DOE, JOHN", "DOB 01/01/1990"]))
    }

    func testTheSimulatorSampleVerifies() throws {
        let zone = try XCTUnwrap(MRZParser.parse(SampleCapture.passportZone()))
        XCTAssertTrue(zone.isValid, "\(zone.errors)")
        XCTAssertEqual(zone.nationality, "US")
    }

    // MARK: - Helpers

    /// A TD3 zone with correct check digits.
    static func passport(number: String, nationality: String, dob: String = "900101", expiry: String = "300101", issuing: String? = nil) -> String {
        let padded = number.padding(toLength: 9, withPad: "<", startingAt: 0)
        var line2 = padded + MRZParser.checkDigit(padded)! + nationality + dob + MRZParser.checkDigit(dob)! + "M"
        line2 += expiry + MRZParser.checkDigit(expiry)! + String(repeating: "<", count: 14) + "<"
        let chars = Array(line2)
        let composite = String(chars[0..<10]) + String(chars[13..<20]) + String(chars[21..<43])
        line2 += MRZParser.checkDigit(composite)!
        let line1 = ("P<" + (issuing ?? nationality) + "DOE<<JOHN").padding(toLength: 44, withPad: "<", startingAt: 0)
        return line1 + "\n" + line2
    }
}
