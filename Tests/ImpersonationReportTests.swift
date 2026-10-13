import XCTest
@testable import Sila

/// Reporting a faked identity: the form asks who is being impersonated, will
/// not send without an answer, and puts that answer on the wire only with the
/// reason it belongs to.
@MainActor
final class ImpersonationReportTests: XCTestCase {

    private var account: ReportSubject {
        .account(SafetyTarget(user: FeedServiceMock.yuki))
    }

    func testImpersonationAsksWhoAndWillNotSendWithoutAnAnswer() {
        var draft = ReportDraft(subject: account, reason: .impersonation)
        XCTAssertTrue(draft.asksWhoIsImpersonated)
        XCTAssertFalse(draft.isSubmittable)
        XCTAssertNotNil(draft.validationError)
        XCTAssertNil(draft.request, "an unanswered form cannot become a request")

        draft.claimedIdentity = "  Ministry of Interior  "
        XCTAssertTrue(draft.isSubmittable)
        XCTAssertEqual(draft.request?.claimedIdentity, "Ministry of Interior")
    }

    func testASingleCharacterIsNotAName() {
        var draft = ReportDraft(subject: account, reason: .impersonation, claimedIdentity: "X")
        XCTAssertFalse(draft.isSubmittable)
        draft.claimedIdentity = "XY"
        XCTAssertTrue(draft.isSubmittable)
    }

    func testOtherReasonsNeitherAskNorSendIt() {
        let draft = ReportDraft(subject: account, reason: .spam, claimedIdentity: "Riyadh Bank")
        XCTAssertFalse(draft.asksWhoIsImpersonated)
        XCTAssertTrue(draft.isSubmittable)
        XCTAssertNil(draft.request?.claimedIdentity, "only sent with the reason it belongs to")
    }

    func testTheNameGoesOnTheWireUnderTheServersKey() throws {
        let request = ReportRequest(userHandle: "impostor", reason: .impersonation, claimedIdentity: "Riyadh Bank")
        let body = String(decoding: try JSONCoding.encoder.encode(request), as: UTF8.self)
        XCTAssertTrue(body.contains("\"claimed_identity\":\"Riyadh Bank\""))
        XCTAssertTrue(body.contains("\"reason\":\"impersonation\""))
    }

    func testTheKeyIsAbsentRatherThanNullWhenThereIsNoName() throws {
        let request = ReportRequest(userHandle: "someone", reason: .spam, claimedIdentity: "Riyadh Bank")
        let body = String(decoding: try JSONCoding.encoder.encode(request), as: UTF8.self)
        XCTAssertFalse(body.contains("claimed_identity"))
    }

    func testAnOverlongNameIsRefusedBeforeItIsSent() {
        let draft = ReportDraft(
            subject: account, reason: .impersonation,
            claimedIdentity: String(repeating: "a", count: SafetyLimits.maximumClaimedIdentityLength + 1)
        )
        XCTAssertFalse(draft.isSubmittable)
    }
}

// MARK: - Once per thing (contract v40)

/// A second report of the same thing is "already reported": the server
/// answers so, and the app shows Reported instead of offering the form again.
@MainActor
final class ReportOncePerThingTests: XCTestCase {

    func testTheReceiptSaysWhenItWasReportedAlready() throws {
        let again = try JSONDecoder().decode(ReportReceipt.self, from: Data(#"{"id":"r1","status":"open","already_reported":true}"#.utf8))
        XCTAssertTrue(again.alreadyReported)
        let first = try JSONDecoder().decode(ReportReceipt.self, from: Data(#"{"id":"r1","status":"open"}"#.utf8))
        XCTAssertFalse(first.alreadyReported, "an older server's receipt is a fresh report")
    }

    func testKeysMatchTheServers() {
        let id = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!
        let who = SafetyTarget(handle: "Yuki", name: "Yuki Tanaka")
        XCTAssertEqual(ReportSubject.post(id: id, author: who, excerpt: "").reportKey, "post:6f9619ff-8b86-d011-b42d-00c04fc964ff")
        XCTAssertEqual(ReportSubject.roomMessage(id: id, author: who, excerpt: "").reportKey, "room_message:6f9619ff-8b86-d011-b42d-00c04fc964ff")
        XCTAssertEqual(ReportSubject.account(who).reportKey, "user:yuki")
    }

    func testAReportedThingIsShownAsReportedAndNotOfferedAgain() {
        let viewModel = SafetyViewModel(
            service: SafetyServiceMock(scenario: .populated),
            analytics: RecordingAnalyticsClient(),
            viewerHandle: "aziz"
        )
        let who = SafetyTarget(handle: "yuki", name: "Yuki Tanaka")
        let subject = ReportSubject.account(who)
        XCTAssertEqual(viewModel.menu(for: who)?.isReported, false)

        viewModel.markReported(subject)
        XCTAssertEqual(viewModel.menu(for: who)?.isReported, true)
        viewModel.openReport(subject)
        XCTAssertNil(viewModel.presentedReport, "a second report is not offered")
        XCTAssertNotNil(viewModel.toast, "the person is told it was reported already")
    }

    func testFilingAReportRemembersIt() async {
        let viewModel = SafetyViewModel(
            service: SafetyServiceMock(scenario: .populated),
            analytics: RecordingAnalyticsClient(),
            viewerHandle: "aziz"
        )
        let subject = ReportSubject.account(SafetyTarget(handle: "yuki", name: "Yuki Tanaka"))
        let sheet = viewModel.reportViewModel(for: subject)
        sheet.draft.reason = .spam
        await sheet.submit()
        XCTAssertTrue(viewModel.isReported(subject))
    }
}
