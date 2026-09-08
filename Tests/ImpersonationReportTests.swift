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
