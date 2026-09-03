import XCTest
@testable import Sila

/// The wire contract with `https://sila.gmai.sa/api/v1`.
///
/// These decode the exact payload shapes the backend documents, so a change on
/// the server surfaces here rather than as a blank screen on device.
final class APIContractTests: XCTestCase {

    private func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        let data = Data(json.utf8)
        return try JSONCoding.decoder.decode(T.self, from: data)
    }

    // MARK: TokenPair

    func testTokenPairDecodesSnakeCaseAndFlattensIntoTokenPlusUser() throws {
        let json = """
        {
          "access_token": "eyJhbGciOi",
          "refresh_token": "rt_9f3c",
          "expires_at": "2026-08-28T12:30:00Z",
          "user": {
            "id": "6c1b1f7e-5a3d-4b2a-9d21-0c1f2a3b4c5d",
            "email": "aziz@example.com",
            "display_name": "Aziz",
            "email_verified": true,
            "verification_status": "pending_review",
            "created_at": "2026-08-01T09:00:00Z"
          }
        }
        """

        let pair = try decode(TokenPair.self, from: json)

        XCTAssertEqual(pair.token.accessToken, "eyJhbGciOi")
        XCTAssertEqual(pair.token.refreshToken, "rt_9f3c")
        XCTAssertEqual(pair.user.email, "aziz@example.com")
        XCTAssertEqual(pair.user.displayName, "Aziz")
        XCTAssertTrue(pair.user.emailVerified)
        XCTAssertEqual(pair.user.verificationStatus, .pendingReview)
        XCTAssertEqual(
            pair.token.expiresAt.timeIntervalSince1970,
            ISO8601DateFormatter().date(from: "2026-08-28T12:30:00Z")?.timeIntervalSince1970
        )
    }

    func testTokenPairAcceptsFractionalSecondTimestamps() throws {
        let json = """
        {
          "access_token": "a", "refresh_token": "r",
          "expires_at": "2026-08-28T12:30:00.512Z",
          "user": {
            "id": "6c1b1f7e-5a3d-4b2a-9d21-0c1f2a3b4c5d",
            "email": "aziz@example.com",
            "email_verified": false,
            "verification_status": "unstarted",
            "created_at": "2026-08-01T09:00:00.000Z"
          }
        }
        """

        let pair = try decode(TokenPair.self, from: json)
        XCTAssertNil(pair.user.displayName)
        XCTAssertEqual(pair.user.verificationStatus, .unstarted)
    }

    // MARK: VerificationStatus

    func testEveryDocumentedStatusValueDecodes() throws {
        let expected: [String: VerificationStatus] = [
            "unstarted": .unstarted,
            "in_progress": .inProgress,
            "pending_review": .pendingReview,
            "verified": .verified,
            "rejected": .rejected
        ]
        for (raw, status) in expected {
            let decoded = try decode(VerificationStatus.self, from: "\"\(raw)\"")
            XCTAssertEqual(decoded, status, "\(raw) decoded incorrectly")
        }
    }

    func testAnUnknownStatusFallsBackToUnstartedRatherThanFailing() throws {
        let decoded = try decode(VerificationStatus.self, from: "\"appeal_pending\"")
        XCTAssertEqual(decoded, .unstarted, "A new server value must not break the whole response")
    }

    // MARK: Other endpoints

    func testRegistrationResultDecodes() throws {
        let json = """
        {"user_id": "6c1b1f7e-5a3d-4b2a-9d21-0c1f2a3b4c5d", "otp_sent": true}
        """
        let result = try decode(RegistrationResult.self, from: json)
        XCTAssertTrue(result.otpSent)
        XCTAssertEqual(result.userId.uuidString.lowercased(), "6c1b1f7e-5a3d-4b2a-9d21-0c1f2a3b4c5d")
    }

    func testOTPSendResultDecodesTheResendWindow() throws {
        let result = try decode(OTPSendResult.self, from: #"{"sent": true, "resend_after_seconds": 45}"#)
        XCTAssertTrue(result.sent)
        XCTAssertEqual(result.resendAfterSeconds, 45)
    }

    func testOTPSendResultFallsBackToTheDefaultWindow() throws {
        let result = try decode(OTPSendResult.self, from: #"{"sent": true}"#)
        XCTAssertEqual(result.resendAfterSeconds, AppConfig.defaultOTPResendSeconds)
    }

    func testVerificationStatusReportDecodesNullTimestamps() throws {
        let json = """
        {
          "status": "rejected",
          "rejection_reason": "Document unreadable",
          "submitted_at": "2026-08-27T10:00:00Z",
          "reviewed_at": null
        }
        """
        let report = try decode(VerificationStatusReport.self, from: json)
        XCTAssertEqual(report.status, .rejected)
        XCTAssertEqual(report.rejectionReason, "Document unreadable")
        XCTAssertNotNil(report.submittedAt)
        XCTAssertNil(report.reviewedAt)
    }

    // MARK: Request encoding

    func testRequestBodiesEncodeToSnakeCase() throws {
        let request = try APIRequest.json(
            "/auth/otp/verify",
            body: OTPVerifyBody(email: "aziz@example.com", code: "482913", purpose: "register")
        )
        let body = try XCTUnwrap(request.body)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        XCTAssertEqual(object["email"] as? String, "aziz@example.com")
        XCTAssertEqual(object["code"] as? String, "482913")
        XCTAssertEqual(object["purpose"] as? String, "register")
    }

    func testRefreshBodyUsesTheSnakeCaseKeyTheServerExpects() throws {
        let request = try APIRequest.json("/auth/refresh", body: RefreshRequestBody(refreshToken: "rt_1"))
        let body = try XCTUnwrap(request.body)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["refresh_token"] as? String, "rt_1")
        XCTAssertNil(object["refreshToken"])
    }

    // MARK: Errors

    func testStructuredDetailBecomesATypedAPIError() {
        let data = Data(#"{"detail": {"code": "otp_expired", "message": "Code expired"}}"#.utf8)
        let error = URLSessionNetworkClient.makeError(status: 400, data: data)

        XCTAssertEqual(error.code, .otpExpired)
        XCTAssertEqual(error.userMessage, "That code has expired. Request a new one.")
    }

    func testEmailUnverifiedIsRecognisedSoSignInCanRouteToOTP() {
        let data = Data(#"{"detail": {"code": "email_unverified", "message": "..."}}"#.utf8)
        let error = URLSessionNetworkClient.makeError(status: 403, data: data)

        XCTAssertEqual(error.code, .emailUnverified)
    }

    func testAnUnknownCodeFallsBackToTheServerMessage() {
        let data = Data(#"{"detail": {"code": "teapot", "message": "I'm a teapot"}}"#.utf8)
        let error = URLSessionNetworkClient.makeError(status: 418, data: data)

        XCTAssertEqual(error.code, .unknown)
        XCTAssertEqual(error.userMessage, "I'm a teapot")
    }

    func testAPlainStringDetailIsStillUsable() {
        let data = Data(#"{"detail": "Not Found"}"#.utf8)
        let error = URLSessionNetworkClient.makeError(status: 404, data: data)

        XCTAssertEqual(error, .http(status: 404, message: "Not Found"))
    }

    func testAnUnparseable401BecomesUnauthenticated() {
        let error = URLSessionNetworkClient.makeError(status: 401, data: Data())
        XCTAssertEqual(error, .unauthenticated)
    }

    func testTheDeployedBackends401ReadsAsAnEndedSession() {
        // Neither contract documents this code, but it is what
        // `GET /feed/for-you` without a token actually returns. Without the
        // mapping the user would be shown the raw "Missing bearer token".
        let data = Data(#"{"detail": {"code": "unauthorized", "message": "Missing bearer token"}}"#.utf8)
        let error = URLSessionNetworkClient.makeError(status: 401, data: data)

        XCTAssertEqual(error.code, .unauthorized)
        XCTAssertEqual(error.userMessage, "Your session has ended. Please sign in again.")
    }

    // MARK: Configuration

    func testTheAPIBaseURLIsWellFormedAndPointsAtTheDeployedBackend() {
        XCTAssertEqual(AppConfig.apiBaseURL.absoluteString, "https://sila.gmai.sa/api/v1")
        XCTAssertEqual(AppConfig.apiBaseURL.scheme, "https", "No ATS exception is declared, so HTTPS is mandatory")
    }
}

/// The launch-argument overrides that select the mock stack.
final class FeatureFlagsTests: XCTestCase {

    func testDefaultsUseTheLiveBackendAndEnableTheShippedPhases() {
        let flags = FeatureFlags.resolved(arguments: ["Sila"])
        XCTAssertFalse(flags.useMockAuth)
        XCTAssertFalse(flags.useMockFeed)
        XCTAssertFalse(flags.useMockComposer)
        XCTAssertFalse(flags.useMockSearch)
        XCTAssertFalse(flags.useMockProfile)
        XCTAssertTrue(flags.auth, "Phase 1 ships")
        XCTAssertTrue(flags.feed, "Phase 3 ships")
        XCTAssertTrue(flags.verification, "Phase 2 ships — the Nafath flow is wired to the wall")
        XCTAssertTrue(flags.composer, "Phase 4 ships")
        XCTAssertTrue(flags.preferences, "contract v4 ships")
        XCTAssertTrue(flags.account, "contract v5 ships")
        XCTAssertTrue(flags.profile, "Phase 7 ships")
        XCTAssertFalse(flags.deepDive, "the Deep Dive panel has no endpoint behind it")
        XCTAssertFalse(flags.messaging, "Phase 5 does not exist yet")
        XCTAssertTrue(flags.biometricSignIn)
    }

    func testMockAuthArgumentSwitchesToTheMockService() {
        let flags = FeatureFlags.resolved(arguments: ["Sila", "-mockAuth"])
        XCTAssertTrue(flags.useMockAuth)
        XCTAssertEqual(flags.mockScenario, .pendingReview)
    }

    func testMockScenarioArgumentSelectsAJourneyAndImpliesMockAuth() {
        let flags = FeatureFlags.resolved(arguments: ["Sila", "-mockScenario", "rejected"])
        XCTAssertTrue(flags.useMockAuth)
        XCTAssertEqual(flags.mockScenario, .rejected)
    }

    func testAnUnknownScenarioNameIsIgnored() {
        let flags = FeatureFlags.resolved(arguments: ["Sila", "-mockScenario", "banana"])
        XCTAssertFalse(flags.useMockAuth)
    }

    func testMockProfileArgumentSelectsAWorldAndImpliesTheMockService() {
        let flags = FeatureFlags.resolved(arguments: ["Sila", "-mockProfileScenario", "notFound"])
        XCTAssertTrue(flags.useMockProfile)
        XCTAssertEqual(flags.mockProfileScenario, .notFound)
    }

    /// A mocked session's token would only ever 401 against the real
    /// `/users/{handle}`, and the Profile tab is the route into account
    /// settings — so mocking auth has to imply mocking profiles too.
    func testAMockedSessionImpliesAMockedProfileService() {
        let flags = FeatureFlags.resolved(arguments: ["Sila", "-mockAuth"])
        XCTAssertTrue(flags.useMockProfile)
    }

    func testBiometricsCanBeDisabledForUITests() {
        let flags = FeatureFlags.resolved(arguments: ["Sila", "-noBiometrics"])
        XCTAssertFalse(flags.biometricSignIn)
    }

    func testMockFeedScenarioArgumentSelectsAWorldAndImpliesMockFeed() {
        let flags = FeatureFlags.resolved(
            arguments: ["Sila", "-mockFeedScenario", "unverifiedNoCountry"]
        )
        XCTAssertTrue(flags.useMockFeed)
        XCTAssertEqual(flags.mockFeedScenario, .unverifiedNoCountry)
    }

    func testAnUnknownFeedScenarioNameIsIgnored() {
        let flags = FeatureFlags.resolved(arguments: ["Sila", "-mockFeedScenario", "banana"])
        XCTAssertFalse(flags.useMockFeed)
    }

    func testMockingAuthAlsoMocksTheFeedBecauseThereIsNoRealToken() {
        let flags = FeatureFlags.resolved(arguments: ["Sila", "-mockAuth"])
        XCTAssertTrue(flags.useMockFeed)
        XCTAssertEqual(flags.mockFeedScenario, .populated)
    }

    func testAnExplicitFeedScenarioWinsOverTheMockAuthDefault() {
        let flags = FeatureFlags.resolved(
            arguments: ["Sila", "-mockAuth", "-mockFeedScenario", "empty"]
        )
        XCTAssertTrue(flags.useMockFeed)
        XCTAssertEqual(flags.mockFeedScenario, .empty)
    }

    // MARK: Phase 4

    func testMockComposerArgumentSwitchesToTheMockService() {
        let flags = FeatureFlags.resolved(arguments: ["Sila", "-mockComposer"])
        XCTAssertTrue(flags.useMockComposer)
        XCTAssertEqual(flags.mockComposerScenario, .success)
        XCTAssertTrue(flags.useMockSearch, "A composer demo needs a mention list that resolves")
    }

    func testMockComposerScenarioArgumentSelectsAWorldAndImpliesMockComposer() {
        let flags = FeatureFlags.resolved(
            arguments: ["Sila", "-mockComposerScenario", "threadFailsMidway"]
        )
        XCTAssertTrue(flags.useMockComposer)
        XCTAssertEqual(flags.mockComposerScenario, .threadFailsMidway)
    }

    func testAnUnknownComposerScenarioNameIsIgnored() {
        let flags = FeatureFlags.resolved(arguments: ["Sila", "-mockComposerScenario", "banana"])
        XCTAssertFalse(flags.useMockComposer)
    }

    func testMockSearchScenarioArgumentSelectsAWorldAndImpliesMockSearch() {
        let flags = FeatureFlags.resolved(arguments: ["Sila", "-mockSearchScenario", "offline"])
        XCTAssertTrue(flags.useMockSearch)
        XCTAssertEqual(flags.mockSearchScenario, .offline)
    }

    func testMockingAuthAlsoMocksTheComposerAndSearch() {
        let flags = FeatureFlags.resolved(arguments: ["Sila", "-mockAuth"])
        XCTAssertTrue(flags.useMockComposer)
        XCTAssertTrue(flags.useMockSearch)
    }

    func testAnExplicitComposerScenarioWinsOverTheMockAuthDefault() {
        let flags = FeatureFlags.resolved(
            arguments: ["Sila", "-mockAuth", "-mockComposerScenario", "unverified"]
        )
        XCTAssertEqual(flags.mockComposerScenario, .unverified)
    }
}
