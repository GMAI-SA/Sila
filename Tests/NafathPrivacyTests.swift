import XCTest
@testable import Sila

/// The Nafath privacy contract: the national ID is sent once, to one endpoint,
/// and appears nowhere that outlives the request — above all, never in an
/// analytics event.
///
/// Asserted against the **recorded events and their properties**, not against
/// intent: every event emitted across a full run of the flow is searched for
/// the digits the person typed.
@MainActor
final class NafathPrivacyTests: XCTestCase {

    /// A distinctive ID no other fixture uses, so a leak cannot hide.
    private let nationalID = "1998877665"

    /// Every value on every recorded event, flattened for searching.
    private func allRecordedText(_ analytics: RecordingAnalyticsClient) -> String {
        analytics.recorded
            .map { record in
                ([record.event.rawValue] + record.properties.flatMap { [$0.key, $0.value] })
                    .joined(separator: " ")
            }
            .joined(separator: "\n")
    }

    // MARK: - View model layer

    func testTheIDNeverAppearsInAnalyticsAcrossAFullApprovedRun() async {
        let analytics = RecordingAnalyticsClient()
        let viewModel = NafathVerificationViewModel(
            service: VerificationServiceMock(scenario: .approved, pendingPolls: 1),
            analytics: analytics,
            pollInterval: 0
        )
        viewModel.nationalID = nationalID

        await viewModel.submit()
        await viewModel.pollUntilDone()
        XCTAssertEqual(viewModel.phase, .approved, "the run must actually complete for this test to prove anything")

        let recorded = allRecordedText(analytics)
        XCTAssertFalse(recorded.contains(nationalID), "the national ID leaked into analytics: \(recorded)")
        XCTAssertFalse(recorded.contains("199887"), "even a fragment of the ID is a leak")
    }

    func testTheIDNeverAppearsInAnalyticsWhenTheStartIsRefused() async {
        let analytics = RecordingAnalyticsClient()
        let viewModel = NafathVerificationViewModel(
            service: VerificationServiceMock(scenario: .identityAlreadyUsed),
            analytics: analytics,
            pollInterval: 0
        )
        viewModel.nationalID = nationalID

        await viewModel.submit()
        XCTAssertEqual(viewModel.phase, .identityUsed)

        let recorded = allRecordedText(analytics)
        XCTAssertFalse(recorded.contains(nationalID), "the national ID leaked into analytics: \(recorded)")
    }

    // MARK: - Service layer

    func testTheServiceSendsTheIDToExactlyOneEndpointAndTracksWithoutIt() async throws {
        let analytics = RecordingAnalyticsClient()
        let network = StubNetworkClient(responses: [
            """
            {"request_id": "req-1", "random_number": "07",
             "expires_at": "2030-01-01T00:00:00Z", "provider": "nafath"}
            """
        ])
        let service = VerificationService(
            network: network,
            tokens: StaticAccessTokenProvider(),
            analytics: analytics
        )

        let start = try await service.startNafath(nationalID: nationalID)

        // The one sanctioned copy: the request body of /start.
        let request = try XCTUnwrap(network.lastRequest)
        XCTAssertEqual(request.path, "/verification/nafath/start")
        let body = String(data: try XCTUnwrap(request.body), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains(nationalID), "the server does need the number")

        // And nowhere else: not in analytics —
        XCTAssertEqual(analytics.events, [.nafathStarted])
        XCTAssertFalse(allRecordedText(analytics).contains(nationalID))
        // — and the leading zero of the tap number survived decoding.
        XCTAssertEqual(start.randomNumber, "07")
    }

    func testARefusedStartTracksTheCodeOnly() async {
        let analytics = RecordingAnalyticsClient()
        let network = StubNetworkClient(
            error: .api(code: .identityAlreadyUsed, message: "used", status: 409)
        )
        let service = VerificationService(
            network: network,
            tokens: StaticAccessTokenProvider(),
            analytics: analytics
        )

        _ = try? await service.startNafath(nationalID: nationalID)

        XCTAssertEqual(analytics.events, [.nafathStartRefused])
        XCTAssertEqual(analytics.recorded.first?.properties, ["code": "identity_already_used"])
        XCTAssertFalse(allRecordedText(analytics).contains(nationalID))
    }
}
