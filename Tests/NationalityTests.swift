import XCTest
@testable import Sila

/// The declared nationality: how it travels, how the wall reads it, and how a
/// rejection it causes is shown.
@MainActor
final class NationalityTests: XCTestCase {

    func testTheStatusReportCarriesTheClaim() throws {
        let json = #"{"status": "unstarted", "rejection_reason": null, "submitted_at": null, "reviewed_at": null, "nationality": "es"}"#
        let report = try JSONCoding.decoder.decode(VerificationStatusReport.self, from: Data(json.utf8))
        XCTAssertEqual(report.nationality, "ES", "normalised like every other code")
    }

    func testAReportWithoutTheFieldStillDecodes() throws {
        let json = #"{"status": "pending_review", "rejection_reason": null, "submitted_at": null, "reviewed_at": null}"#
        let report = try JSONCoding.decoder.decode(VerificationStatusReport.self, from: Data(json.utf8))
        XCTAssertNil(report.nationality)
        XCTAssertEqual(report.status, .pendingReview)
    }

    func testDeclaringSendsTheCodeAndRefusesNonCountries() async throws {
        let service = VerificationServiceMock()
        let report = try await service.setNationality("us")
        XCTAssertEqual(report.nationality, "US")
        do {
            _ = try await service.setNationality("EU")
            XCTFail("EU is not a country")
        } catch let error as APIError {
            XCTAssertEqual(error.code, .invalidCountry)
        }
        let calls = await service.recordedCalls
        XCTAssertEqual(calls, ["setNationality", "setNationality"])
    }

    func testTheWallAdoptsADeclaredNationality() {
        let viewModel = VerificationWallViewModel(status: .unstarted, service: AuthServiceMock(scenario: .unstarted), analytics: RecordingAnalyticsClient())
        XCTAssertNil(viewModel.declaredNationality)
        viewModel.adopt(VerificationStatusReport(status: .unstarted, nationality: "FR"))
        XCTAssertEqual(viewModel.declaredNationality, "FR")
        XCTAssertEqual(viewModel.status, .unstarted)
    }

    func testASaudiClaimHidesTheDocumentRoute() {
        XCTAssertFalse(VerificationMethodSheet(declaredNationality: "SA") { _ in }.offersDocumentRoute)
        XCTAssertTrue(VerificationMethodSheet(declaredNationality: "US") { _ in }.offersDocumentRoute)
        XCTAssertTrue(VerificationMethodSheet(declaredNationality: nil) { _ in }.offersDocumentRoute)
    }

    func testMachineReasonsReadAsSentencesAndReviewerWordsPassThrough() {
        XCTAssertEqual(VerificationRejection.display("nationality_mismatch"), "The nationality on the identity you presented does not match the nationality you selected.")
        XCTAssertEqual(VerificationRejection.display("document_expired"), "The identity document you presented has expired.")
        XCTAssertEqual(VerificationRejection.display("under_minimum_age"), "The identity you presented is under the minimum age for Sila.")
        XCTAssertEqual(VerificationRejection.display("The photo is blurry"), "The photo is blurry")
        XCTAssertNil(VerificationRejection.display(nil))
        XCTAssertNil(VerificationRejection.display("  "))
        XCTAssertTrue(VerificationRejection.isMachineReason("document_expired"))
        XCTAssertFalse(VerificationRejection.isMachineReason("The photo is blurry"))
    }

    func testEveryCountryIsOfferedAndNothingThatIsNotOne() {
        let codes = Set(NationalityPickerSheet.allCountries(locale: Locale(identifier: "en_US")).map(\.code))
        for expected in ["SA", "US", "ES", "EG", "JP", "IR", "IL", "GB", "DE"] {
            XCTAssertTrue(codes.contains(expected), expected)
        }
        for notACountry in ["EU", "ZZ", "UK", "XA"] {
            XCTAssertFalse(codes.contains(notACountry), notACountry)
        }
        XCTAssertGreaterThan(codes.count, 200)
        let names = NationalityPickerSheet.allCountries(locale: Locale(identifier: "en_US")).map(\.name)
        XCTAssertEqual(names, names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
    }
}
