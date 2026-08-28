import XCTest
@testable import Sila

/// Every ``VerificationStatus`` must map to a coherent wall presentation, and
/// the wall's view model must reflect what `/verification/status` returns.
@MainActor
final class VerificationWallTests: XCTestCase {

    // MARK: Presentation mapping — all five states

    func testEveryStatusProducesANonEmptyPresentation() {
        for status in VerificationStatus.allCases {
            let presentation = WallPresentation.make(for: status)
            XCTAssertFalse(presentation.title.isEmpty, "\(status) has no title")
            XCTAssertFalse(presentation.message.isEmpty, "\(status) has no message")
            XCTAssertFalse(presentation.badgeText.isEmpty, "\(status) has no badge")
            XCTAssertFalse(presentation.icon.isEmpty, "\(status) has no icon")
        }
    }

    func testUnstartedAsksTheUserToStartVerification() {
        let presentation = WallPresentation.make(for: .unstarted)
        XCTAssertEqual(presentation.badgeText, "Action Required")
        XCTAssertEqual(presentation.badgeStyle, .warning)
        XCTAssertEqual(presentation.primaryActionTitle, "Start Verification")
        XCTAssertFalse(presentation.showsProcessingAnimation)
    }

    func testInProgressAsksTheUserToContinue() {
        let presentation = WallPresentation.make(for: .inProgress)
        XCTAssertEqual(presentation.badgeText, "Action Required")
        XCTAssertEqual(presentation.primaryActionTitle, "Continue Verification")
        XCTAssertFalse(presentation.showsProcessingAnimation)
    }

    func testPendingReviewShowsTheProcessingIndicatorAndOffersNoAction() {
        let presentation = WallPresentation.make(for: .pendingReview)
        XCTAssertEqual(presentation.badgeText, "Under Review")
        XCTAssertEqual(presentation.badgeStyle, .verified)
        XCTAssertNil(presentation.primaryActionTitle, "There is nothing for the user to do while waiting")
        XCTAssertTrue(presentation.showsProcessingAnimation)
    }

    func testVerifiedOffersEntryToTheApp() {
        let presentation = WallPresentation.make(for: .verified)
        XCTAssertEqual(presentation.badgeText, "Verified")
        XCTAssertEqual(presentation.primaryActionTitle, "Enter Sila")
        XCTAssertFalse(presentation.showsProcessingAnimation)
    }

    func testRejectedIsColouredAsDangerAndOffersAnAppeal() {
        let presentation = WallPresentation.make(for: .rejected)
        XCTAssertEqual(presentation.badgeText, "Rejected")
        XCTAssertEqual(presentation.badgeStyle, .danger)
        XCTAssertEqual(presentation.primaryActionTitle, "Appeal")
    }

    func testOnlyVerifiedGrantsAccess() {
        for status in VerificationStatus.allCases {
            XCTAssertEqual(status.grantsAccess, status == .verified, "\(status) gates incorrectly")
        }
    }

    // MARK: View model

    func testRefreshAdoptsTheServerStatus() async {
        let service = AuthServiceMock(scenario: .rejected)
        let viewModel = VerificationWallViewModel(
            status: .pendingReview,
            service: service,
            analytics: RecordingAnalyticsClient()
        )

        await viewModel.refresh()

        XCTAssertEqual(viewModel.status, .rejected)
        XCTAssertEqual(viewModel.presentation.badgeText, "Rejected")
        XCTAssertNotNil(viewModel.rejectionReason)
    }

    func testRefreshSurfacesTheSubmissionTimestamp() async {
        let service = AuthServiceMock(scenario: .pendingReview)
        let viewModel = VerificationWallViewModel(
            status: .pendingReview,
            service: service,
            analytics: RecordingAnalyticsClient()
        )

        await viewModel.refresh()

        XCTAssertNotNil(viewModel.submittedText)
        XCTAssertTrue(viewModel.submittedText?.hasPrefix("Submitted ") == true)
    }

    func testUnstartedHasNoSubmissionTimestamp() async {
        let service = AuthServiceMock(scenario: .unstarted)
        let viewModel = VerificationWallViewModel(
            status: .unstarted,
            service: service,
            analytics: RecordingAnalyticsClient()
        )

        await viewModel.refresh()

        XCTAssertNil(viewModel.submittedText)
    }

    func testRefreshFailureKeepsTheLastKnownStatusAndExplains() async {
        let service = AuthServiceMock(scenario: .offline)
        let viewModel = VerificationWallViewModel(
            status: .pendingReview,
            service: service,
            analytics: RecordingAnalyticsClient()
        )

        await viewModel.refresh()

        XCTAssertEqual(viewModel.status, .pendingReview, "A failed poll must not blank the screen")
        XCTAssertEqual(viewModel.toast?.kind, .error)
    }

    func testStartVerificationIsTrackedAndStubbedHonestly() {
        let analytics = RecordingAnalyticsClient()
        let viewModel = VerificationWallViewModel(
            status: .unstarted,
            service: AuthServiceMock(scenario: .unstarted),
            analytics: analytics
        )

        viewModel.startVerification()

        XCTAssertEqual(analytics.events, [.verificationStarted])
        XCTAssertEqual(viewModel.toast?.kind, .info)
    }
}
