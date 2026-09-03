import XCTest
@testable import Sila

/// The Nafath flow: input validation, the poll loop's terminal states, the
/// refusals that are not failures — and the privacy contract that the national
/// ID never outlives the request it was typed for.
@MainActor
final class NafathVerificationTests: XCTestCase {

    // MARK: - Helpers

    /// A test clock the injected sleeper advances, so "the request expired
    /// while we were polling" is a deterministic fact rather than a race.
    final class FakeClock: @unchecked Sendable {
        private let lock = NSLock()
        private var date = Date()
        var now: Date {
            lock.lock(); defer { lock.unlock() }
            return date
        }
        func advance(_ seconds: TimeInterval) {
            lock.lock(); date.addTimeInterval(seconds); lock.unlock()
        }
    }

    private func makeViewModel(
        service: VerificationServiceProtocol,
        analytics: AnalyticsClient = RecordingAnalyticsClient(),
        clock: FakeClock = FakeClock()
    ) -> NafathVerificationViewModel {
        NafathVerificationViewModel(
            service: service,
            analytics: analytics,
            pollInterval: 3,
            now: { clock.now },
            sleeper: { seconds in clock.advance(seconds) }
        )
    }

    /// A National ID nobody holds: 10 digits, starts with 1.
    private let validID = "1000000000"

    // MARK: - Input validation

    func testNationalIDValidation() {
        XCTAssertTrue(NationalID.isValid("1023456789"))
        XCTAssertTrue(NationalID.isValid("2023456789"), "Iqama numbers start with 2")
        XCTAssertTrue(NationalID.isValid(" 1023456789 "), "whitespace is not a wrong answer")
        XCTAssertTrue(NationalID.isValid("١٠٢٣٤٥٦٧٨٩"), "Arabic-Indic digits are the same number")

        XCTAssertFalse(NationalID.isValid("3023456789"), "must start with 1 or 2")
        XCTAssertFalse(NationalID.isValid("102345678"), "nine digits")
        XCTAssertFalse(NationalID.isValid("10234567890"), "eleven digits")
        XCTAssertFalse(NationalID.isValid(""))
        XCTAssertFalse(NationalID.isValid("abcdefghij"))
    }

    func testInvalidInputIsRefusedLocallyWithoutTouchingTheService() async {
        let service = VerificationServiceMock(scenario: .approved)
        let viewModel = makeViewModel(service: service)
        viewModel.nationalID = "12345"

        await viewModel.submit()

        XCTAssertEqual(viewModel.phase, .enterID)
        XCTAssertNotNil(viewModel.idError)
        let calls = await service.recordedCalls
        XCTAssertTrue(calls.isEmpty, "an invalid number must never go over the wire")
    }

    // MARK: - The happy path and the ID's lifetime

    func testSubmitMovesToWaitingAndClearsTheNationalID() async {
        let service = VerificationServiceMock(scenario: .approved)
        let viewModel = makeViewModel(service: service)
        viewModel.nationalID = validID

        await viewModel.submit()

        XCTAssertEqual(viewModel.phase, .waiting)
        XCTAssertEqual(viewModel.nationalID, "", "the ID is sent once and never echoed back")
        XCTAssertEqual(viewModel.randomNumber, VerificationServiceMock.mockRandomNumber)
        XCTAssertNotNil(viewModel.expiresAt)
    }

    // MARK: - The poll loop's terminal states

    func testPollLoopReachesApproved() async {
        let analytics = RecordingAnalyticsClient()
        let service = VerificationServiceMock(scenario: .approved, pendingPolls: 2)
        let viewModel = makeViewModel(service: service, analytics: analytics)
        viewModel.nationalID = validID

        await viewModel.submit()
        await viewModel.pollUntilDone()

        XCTAssertEqual(viewModel.phase, .approved)
        XCTAssertTrue(analytics.events.contains(.nafathApproved))
        let calls = await service.recordedCalls
        XCTAssertEqual(calls.filter { $0 == "pollNafath" }.count, 3, "two pending polls, then the answer")
    }

    func testPollLoopReachesRejectedWithTheServersReason() async {
        let analytics = RecordingAnalyticsClient()
        let service = VerificationServiceMock(scenario: .rejected, pendingPolls: 1)
        let viewModel = makeViewModel(service: service, analytics: analytics)
        viewModel.nationalID = validID

        await viewModel.submit()
        await viewModel.pollUntilDone()

        XCTAssertEqual(viewModel.phase, .rejected)
        XCTAssertNotNil(viewModel.rejectionReason, "the server's reason is shown, not discarded")
        XCTAssertTrue(analytics.events.contains(.nafathRejected))
    }

    func testPollLoopReachesExpiredWhenTheClockRunsOut() async {
        let analytics = RecordingAnalyticsClient()
        let clock = FakeClock()
        // Pending forever; only the expiry clock can end this wait.
        let service = VerificationServiceMock(scenario: .expires, requestLifetime: 30)
        let viewModel = makeViewModel(service: service, analytics: analytics, clock: clock)
        viewModel.nationalID = validID

        await viewModel.submit()
        await viewModel.pollUntilDone()

        XCTAssertEqual(viewModel.phase, .expired)
        XCTAssertTrue(analytics.events.contains(.nafathExpired))
    }

    func testStartAgainAfterExpiryReturnsToACleanForm() async {
        let clock = FakeClock()
        let service = VerificationServiceMock(scenario: .expires, requestLifetime: 30)
        let viewModel = makeViewModel(service: service, clock: clock)
        viewModel.nationalID = validID

        await viewModel.submit()
        await viewModel.pollUntilDone()
        XCTAssertEqual(viewModel.phase, .expired)

        viewModel.startAgain()

        XCTAssertEqual(viewModel.phase, .enterID)
        XCTAssertEqual(viewModel.randomNumber, "")
        XCTAssertNil(viewModel.expiresAt)
        XCTAssertNil(viewModel.idError, "a fresh form carries no stale complaint")
    }

    func testDroppedPollsAreRetriedUntilTheClockEndsTheWait() async {
        let clock = FakeClock()
        let service = VerificationServiceMock(scenario: .approved, requestLifetime: 30)
        let viewModel = makeViewModel(service: service, clock: clock)
        viewModel.nationalID = validID

        await viewModel.submit()
        XCTAssertEqual(viewModel.phase, .waiting)

        // The connection dies while we wait. Every poll now throws; the loop
        // must keep retrying — no error screen for a dropped packet — until
        // the expiry clock ends the wait honestly.
        await service.setScenario(.offline)
        await viewModel.pollUntilDone()

        XCTAssertEqual(viewModel.phase, .expired)
        XCTAssertNil(viewModel.toast, "a transient poll failure is not user-facing news")
        let polls = await service.recordedCalls.filter { $0 == "pollNafath" }.count
        XCTAssertGreaterThan(polls, 1, "the loop retried rather than giving up on the first drop")
    }

    func testSubmitWhileOfflineExplainsAndStaysPut() async {
        let service = VerificationServiceMock(scenario: .offline)
        let viewModel = makeViewModel(service: service)
        viewModel.nationalID = validID

        await viewModel.submit()

        XCTAssertEqual(viewModel.phase, .enterID)
        XCTAssertEqual(viewModel.toast?.kind, .error)
    }

    // MARK: - Refusals that are not failures

    func testIdentityAlreadyUsedGetsItsOwnOutcomeNotAnError() async {
        let service = VerificationServiceMock(scenario: .identityAlreadyUsed)
        let viewModel = makeViewModel(service: service)
        viewModel.nationalID = validID

        await viewModel.submit()

        XCTAssertEqual(viewModel.phase, .identityUsed, "already-has-an-account is a fact, not a failure")
        XCTAssertNil(viewModel.toast, "no error banner for a state the screen explains properly")
        XCTAssertEqual(viewModel.nationalID, "", "the ID is discarded on this path too")
    }

    func testIdentityAlreadyUsedMessageIsDistinctAndPointsAtSigningIn() {
        let identityUsed = L10n.t("verification.identityUsed.message")
        let rejected = L10n.t("verification.rejected.message")
        let generic = L10n.t("common.somethingWentWrong")

        XCTAssertNotEqual(identityUsed, rejected)
        XCTAssertNotEqual(identityUsed, generic)
        XCTAssertTrue(
            identityUsed.localizedCaseInsensitiveContains("sign in"),
            "the way forward is the sign-in form, and the copy has to say so"
        )
    }

    func testAlreadyVerifiedIsTreatedAsApproved() async {
        let service = VerificationServiceMock(scenario: .alreadyVerified)
        let viewModel = makeViewModel(service: service)
        viewModel.nationalID = validID

        await viewModel.submit()

        XCTAssertEqual(viewModel.phase, .approved, "already verified means: through the wall")
    }

    func testServerRefusedNationalIdShowsInline() async {
        let service = VerificationServiceMock(scenario: .invalidNationalId)
        let viewModel = makeViewModel(service: service)
        viewModel.nationalID = validID

        await viewModel.submit()

        XCTAssertEqual(viewModel.phase, .enterID)
        XCTAssertNotNil(viewModel.idError, "the server's refusal lands under the field, not in a toast")
    }

    func testUnavailableShowsAnErrorAndStaysOnTheForm() async {
        let service = VerificationServiceMock(scenario: .unavailable)
        let viewModel = makeViewModel(service: service)
        viewModel.nationalID = validID

        await viewModel.submit()

        XCTAssertEqual(viewModel.phase, .enterID)
        XCTAssertEqual(viewModel.toast?.kind, .error)
    }

    func testUnderMinimumAgeRendersTheServersMessage() async {
        let service = VerificationServiceMock(scenario: .underMinimumAge)
        let viewModel = makeViewModel(service: service)
        viewModel.nationalID = validID

        await viewModel.submit()
        await viewModel.pollUntilDone()

        XCTAssertEqual(viewModel.phase, .underAge)
        XCTAssertEqual(
            viewModel.underAgeMessage,
            "Sila is available to people aged 13 and over.",
            "the server's sentence, verbatim — the age rule is policy, not client copy"
        )
    }
}
