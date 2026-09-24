import XCTest
@testable import Sila

/// Nafath is "coming soon" (backend 770d671): the status says so in
/// `methods`, and until it is live every nationality — Saudis included —
/// verifies with a passport or ID card.
final class NafathComingSoonTests: XCTestCase {

    private func report(_ json: String) throws -> VerificationStatusReport {
        try JSONCoding.decoder.decode(VerificationStatusReport.self, from: Data(json.utf8))
    }

    func testTheStatusSaysWhetherNafathIsOpen() throws {
        XCTAssertFalse(try report(#"{"status": "unstarted", "methods": {"nafath": "coming_soon", "document": "available"}}"#).nafathAvailable)
        XCTAssertTrue(try report(#"{"status": "unstarted", "methods": {"nafath": "available", "document": "available"}}"#).nafathAvailable)
        XCTAssertFalse(try report(#"{"status": "unstarted"}"#).nafathAvailable, "an older server reads as not available")
    }

    @MainActor
    func testTheMethodSheetOffersTheDocumentRouteToASaudiWhileNafathIsComingSoon() {
        let closed = VerificationMethodSheet(declaredNationality: "SA", nafathAvailable: false, onChangeNationality: {}, onChoose: { _ in })
        XCTAssertTrue(closed.offersDocumentRoute)
        let open = VerificationMethodSheet(declaredNationality: "SA", nafathAvailable: true, onChangeNationality: {}, onChoose: { _ in })
        XCTAssertFalse(open.offersDocumentRoute, "with Nafath live a Saudi uses Nafath")
        let foreign = VerificationMethodSheet(declaredNationality: "EG", nafathAvailable: true, onChangeNationality: {}, onChoose: { _ in })
        XCTAssertTrue(foreign.offersDocumentRoute)
    }

    func testTheWallDoesNotSendASaudiStraightToNafathWhileItIsClosed() {
        XCTAssertFalse(VerificationWallViewModel.routesStraightToNafath(claim: "SA", nafathAvailable: false))
        XCTAssertTrue(VerificationWallViewModel.routesStraightToNafath(claim: "sa", nafathAvailable: true))
        XCTAssertFalse(VerificationWallViewModel.routesStraightToNafath(claim: "EG", nafathAvailable: true))
    }

    /// Web-parity review: a Saudi whose claim was already on file was sent
    /// straight into Nafath by Start while it was still coming soon.
    func testStartDoesNotSendAnAlreadyDeclaredSaudiToAClosedNafath() {
        XCTAssertEqual(VerificationWallViewModel.startStep(declared: "SA", nafathAvailable: false), .chooseMethod)
        XCTAssertEqual(VerificationWallViewModel.startStep(declared: "SA", nafathAvailable: true), .nafath)
        XCTAssertEqual(VerificationWallViewModel.startStep(declared: "EG", nafathAvailable: true), .chooseMethod)
        XCTAssertEqual(VerificationWallViewModel.startStep(declared: nil, nafathAvailable: true), .pickNationality)
    }

    func testNafathUnavailableHasItsOwnSentence() {
        let error = APIError.api(code: .nafathUnavailable, message: "server words", status: 503)
        XCTAssertEqual(error.userMessage, L10n.t("error.nafathUnavailable"))
    }

    func testTheMockStartRefusesWhileComingSoon() async {
        let service = VerificationServiceMock(scenario: .nafathComingSoon)
        do {
            _ = try await service.startNafath(nationalID: "1000000008")
            XCTFail("Nafath started while coming soon")
        } catch let error as APIError {
            XCTAssertEqual(error.code, .nafathUnavailable)
        } catch {
            XCTFail("\(error)")
        }
    }

    func testTheAuthMockDefaultsToComingSoon() async throws {
        let closed = try await AuthServiceMock(scenario: .pendingReview, nafathAvailable: false).verificationStatus()
        XCTAssertFalse(closed.nafathAvailable)
        let open = try await AuthServiceMock(scenario: .pendingReview, nafathAvailable: true).verificationStatus()
        XCTAssertTrue(open.nafathAvailable)
    }
}
