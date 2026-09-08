import XCTest
@testable import Sila

/// Contesting a verification decision in-app (contract v13): how the appeal
/// travels, how the report carries it, and how a withdrawn badge reads.
@MainActor
final class VerificationAppealTests: XCTestCase {

    func testTheStatusReportCarriesTheAppeal() throws {
        let json = #"""
        {"status": "rejected", "rejection_reason": "verification_revoked", "submitted_at": null,
         "reviewed_at": "2026-09-08T10:00:00Z", "nationality": "JP",
         "appeal": {"id": "3f1c2b7e-2c1d-4b9a-9d5e-0c1f2a3b4c5d", "status": "pending", "submitted_at": "2026-09-08T11:00:00Z"}}
        """#
        let report = try JSONCoding.decoder.decode(VerificationStatusReport.self, from: Data(json.utf8))
        XCTAssertEqual(report.status, .rejected)
        XCTAssertEqual(report.appeal?.status, .pending)
        XCTAssertEqual(report.appeal?.id, "3f1c2b7e-2c1d-4b9a-9d5e-0c1f2a3b4c5d")
        XCTAssertNotNil(report.appeal?.submittedAt)
    }

    func testAReportWithoutAnAppealStillDecodes() throws {
        let json = #"{"status": "rejected", "rejection_reason": "Blurry", "submitted_at": null, "reviewed_at": null, "appeal": null}"#
        let report = try JSONCoding.decoder.decode(VerificationStatusReport.self, from: Data(json.utf8))
        XCTAssertNil(report.appeal)
        XCTAssertEqual(report.rejectionReason, "Blurry")
    }

    func testAnUnknownAppealStatusIsStillAnAppealOnFile() throws {
        let json = #"{"id": "x", "status": "escalated"}"#
        let receipt = try JSONCoding.decoder.decode(VerificationAppealReceipt.self, from: Data(json.utf8))
        XCTAssertEqual(receipt.status, .unknown)
        XCTAssertEqual(receipt.status.label, VerificationAppealStatus.pending.label, "shown as submitted, never as an error")
    }

    func testTheStatusVocabularyMatchesTheServer() {
        XCTAssertEqual(VerificationAppealStatus(serverValue: "upheld"), .upheld, "upheld = the decision stands")
        XCTAssertEqual(VerificationAppealStatus(serverValue: "overturned"), .overturned, "overturned = the appeal succeeded")
        XCTAssertEqual(VerificationAppealStatus(serverValue: "PENDING"), .pending)
    }

    func testTheMockAllowsOneAppealPerDecision() async throws {
        let service = VerificationServiceMock()
        let receipt = try await service.appealVerification(message: "It was the light")
        XCTAssertEqual(receipt.status, .pending)
        XCTAssertNotNil(receipt.submittedAt)
        do {
            _ = try await service.appealVerification(message: "again")
            XCTFail("one per decision")
        } catch let error as APIError {
            XCTAssertEqual(error.code, .alreadyAppealed)
        }
        let calls = await service.recordedCalls
        XCTAssertEqual(calls, ["appealVerification", "appealVerification"])
    }

    func testAWithdrawnBadgeHasItsOwnSentenceAndIsNotRetried() {
        XCTAssertEqual(
            VerificationRejection.display("verification_revoked"),
            L10n.t("auth.rejected.reason.verificationRevoked")
        )
        XCTAssertTrue(VerificationRejection.isMachineReason("verification_revoked"))
        XCTAssertTrue(VerificationRejection.isRevocation("verification_revoked"))
        XCTAssertFalse(VerificationRejection.isRevocation("Photo does not match the document"))
    }

    func testTheAppealIsBoundedLikeTheServerBoundsIt() {
        XCTAssertEqual(VerificationAppealReceipt.maximumLength, 1_000)
    }
}
