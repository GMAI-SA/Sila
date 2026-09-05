import XCTest
@testable import Sila

/// Contract v9's gate, from the transport up to the route.
///
/// Verification stopped being a permission granted on top of an account and
/// became a condition of holding one, so `403 unverified` can now come back
/// from any screen at any moment. The property under test throughout is that it
/// produces a **route**, never an error alert with a Retry button.
@MainActor
final class VerificationGateTests: XCTestCase {

    // MARK: - The gate itself

    func testARefusalReconcilesExactlyOnce() async {
        let gate = VerificationGate()
        let counter = CallCounter()
        gate.reconcile = { await counter.increment() }

        // Four in-flight requests on one screen, all refused: one `/auth/me`.
        gate.noticeRefusal()
        gate.noticeRefusal()
        gate.noticeRefusal()
        gate.noticeRefusal()
        await settle()

        let count = await counter.count
        XCTAssertEqual(count, 1)
        XCTAssertTrue(gate.wasRefused)
    }

    func testASecondBurstReconcilesAgainOnceTheFirstHasFinished() async {
        let gate = VerificationGate()
        let counter = CallCounter()
        gate.reconcile = { await counter.increment() }

        gate.noticeRefusal()
        await settle()
        gate.noticeRefusal()
        await settle()

        let count = await counter.count
        XCTAssertEqual(count, 2, "Deduplication is per burst, not for the life of the session.")
    }

    func testOnlyUnverifiedTripsTheGate() async {
        let gate = VerificationGate()
        let counter = CallCounter()
        gate.reconcile = { await counter.increment() }

        XCTAssertFalse(gate.notice(APIError.api(code: .postNotFound, message: "", status: 404)))
        XCTAssertFalse(gate.notice(APIError.api(code: .accountSuspended, message: "", status: 403)))
        XCTAssertFalse(gate.notice(APIError.transport("offline")))
        XCTAssertTrue(gate.notice(APIError.api(code: .unverified, message: "", status: 403)))
        await settle()

        let count = await counter.count
        XCTAssertEqual(count, 1)
    }

    func testAHoldIsNotTheGate() async {
        // A hold pauses posting; it does not un-verify anybody. Routing it to
        // the wall would tell somebody to verify an identity they have already
        // proved — and hide the feed they are still perfectly entitled to read.
        let gate = VerificationGate()
        let counter = CallCounter()
        gate.reconcile = { await counter.increment() }

        XCTAssertFalse(gate.notice(APIError.api(code: .identityHold, message: "", status: 403)))
        await settle()

        let count = await counter.count
        XCTAssertEqual(count, 0)
        XCTAssertFalse(gate.wasRefused)
    }

    func testClearingForgetsTheRefusal() {
        let gate = VerificationGate()
        gate.noticeRefusal()
        gate.clear()
        XCTAssertFalse(gate.wasRefused)
    }

    // MARK: - The transport reports it

    func testTheTransportReportsAnyRefusedCall() async throws {
        let gate = VerificationGate()
        let counter = CallCounter()
        gate.reconcile = { await counter.increment() }

        StubURLProtocol.stub = (
            status: 403,
            body: #"{"detail":{"code":"unverified","message":"Verify your identity to use Sila."}}"#
        )
        let client = URLSessionNetworkClient(
            baseURL: URL(string: "https://sila.invalid/api/v1")!,
            session: StubURLProtocol.session(),
            verification: gate.signal
        )

        // A feed call — nothing to do with verification, which is the point.
        do {
            try await client.send(APIRequest(path: "/feed/for-you", accessToken: "token"))
            XCTFail("Expected the call to fail.")
        } catch {
            // Reported *and* thrown: the caller still has to stop its spinner.
            XCTAssertEqual(APIError.wrapping(error).code, .unverified)
        }
        await settle()

        let count = await counter.count
        XCTAssertEqual(count, 1)
        XCTAssertTrue(gate.wasRefused)
    }

    func testTheTransportLeavesOrdinaryFailuresAlone() async throws {
        let gate = VerificationGate()

        StubURLProtocol.stub = (
            status: 404,
            body: #"{"detail":{"code":"post_not_found","message":"No such post."}}"#
        )
        let client = URLSessionNetworkClient(
            baseURL: URL(string: "https://sila.invalid/api/v1")!,
            session: StubURLProtocol.session(),
            verification: gate.signal
        )

        do {
            try await client.send(APIRequest(path: "/posts/1", accessToken: "token"))
            XCTFail("Expected the call to fail.")
        } catch {
            XCTAssertEqual(APIError.wrapping(error).code, .postNotFound)
        }
        await settle()

        XCTAssertFalse(gate.wasRefused)
    }

    // MARK: - The session decides where to go

    func testARevokedVerificationRoutesBackToTheWall() async {
        let analytics = RecordingAnalyticsClient()
        let session = makeSession(status: .unstarted, analytics: analytics)
        // Signed in and on the feed, as the app would have been a moment ago.
        await session.adopt(makePair(status: .verified))
        XCTAssertEqual(session.route, .feed)

        await session.reconcileVerification()

        XCTAssertEqual(session.route, .verificationWall(.unstarted))
        XCTAssertFalse(
            analytics.recorded.contains { $0.properties["source"] == "disagreement" },
            "The server agreed it was unverified — there is no disagreement to report."
        )
    }

    func testARefusalIsBelievedOverAnAuthMeThatStillSaysVerified() async {
        // The two answers cannot both be acted on. The refusal is the more
        // recent and the more restrictive, and the wall is the only screen that
        // offers a way forward; the feed would just re-error forever.
        let analytics = RecordingAnalyticsClient()
        let session = makeSession(status: .verified, analytics: analytics)
        await session.adopt(makePair(status: .verified))

        await session.reconcileVerification()

        XCTAssertEqual(session.route, .verificationWall(.unstarted))
        XCTAssertTrue(
            analytics.recorded.contains {
                $0.event == .verificationGateTripped && $0.properties["source"] == "disagreement"
            }
        )
    }

    func testReconcilingWithoutASessionDoesNothing() async {
        let session = makeSession(status: .verified, analytics: RecordingAnalyticsClient())
        await session.reconcileVerification()
        XCTAssertEqual(session.route, .splash, "No user, nothing to reconcile, nowhere to go.")
    }

    // MARK: - The hold's own copy

    func testTheHoldSaysWhatIsPausedAndWhatIsNot() {
        let message = APIError.api(code: .identityHold, message: "", status: 403).userMessage
        XCTAssertEqual(message, L10n.t("error.identityHold"))
        XCTAssertFalse(message.isEmpty)
        // Never repeats the claim back to the person it was made about: nothing
        // has been decided, and naming the accusation would decide it.
        for word in ["impersonat", "fake", "pretend", "fraud"] {
            XCTAssertFalse(
                message.lowercased().contains(word),
                "The hold's copy must not repeat the accusation (found \"\(word)\")."
            )
        }
    }

    func testAHoldIsNotAnAccountState() {
        // `identity_hold` shares its status code with three refusals that *are*
        // states. Routing on the status rather than the code would put a person
        // who can still read the whole app behind a wall.
        let hold = APIError.api(code: .identityHold, message: "", status: 403)
        XCTAssertNil(SafetyRouting.route(forError: hold))
    }

    // MARK: - Helpers

    private func makeSession(
        status: VerificationStatus,
        analytics: AnalyticsClient
    ) -> AuthSession {
        let store = AuthTokenStore(
            keychain: InMemoryKeychainClient(),
            storage: InMemoryStorageClient()
        )
        return AuthSession(
            service: StubAuthService(status: status),
            store: store,
            analytics: analytics
        )
    }

    private func makePair(status: VerificationStatus) -> TokenPair {
        TokenPair(
            token: AuthToken(
                accessToken: "access",
                refreshToken: "refresh",
                expiresAt: Date().addingTimeInterval(3600)
            ),
            user: AuthUser(
                id: UUID(),
                email: "aziz@example.com",
                displayName: nil,
                emailVerified: true,
                verificationStatus: status,
                createdAt: Date()
            )
        )
    }

    /// Lets the gate's detached reconciliation task run to completion.
    private func settle() async {
        for _ in 0..<10 { await Task.yield() }
    }
}

/// Counts calls from any isolation domain.
private actor CallCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

/// The smallest possible fake server: one canned response for every request.
///
/// Here rather than in a mock ``NetworkClient`` because the line under test —
/// the interception of `403 unverified` — lives *inside*
/// ``URLSessionNetworkClient``, and a mock client would replace the very code
/// being checked.
private final class StubURLProtocol: URLProtocol, @unchecked Sendable {

    static var stub: (status: Int, body: String) = (200, "{}")

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (status, body) = Self.stub
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://sila.invalid")!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// An `/auth/me` that answers exactly one verification status.
///
/// A purpose-built stub rather than ``AuthServiceMock`` because the question
/// under test is what the client does with the server's answer, and the mock's
/// saved credential carries an unconfirmed email — which routes to the OTP
/// screen long before verification is considered.
private actor StubAuthService: AuthServiceProtocol {

    private let status: VerificationStatus

    init(status: VerificationStatus) {
        self.status = status
    }

    nonisolated var availableBiometry: BiometryKind { .none }

    func currentUser() async throws -> AuthUser {
        AuthUser(
            id: UUID(),
            email: "aziz@example.com",
            displayName: nil,
            emailVerified: true,
            verificationStatus: status,
            createdAt: Date(),
            handle: "aziz",
            countryCode: status == .verified ? "SA" : nil
        )
    }

    func verificationStatus() async throws -> VerificationStatusReport {
        VerificationStatusReport(
            status: status,
            rejectionReason: nil,
            submittedAt: nil,
            reviewedAt: nil
        )
    }

    func register(email: String, password: String) async throws -> RegistrationResult {
        throw APIError.unauthenticated
    }
    func sendOTP(email: String, purpose: OTPPurpose) async throws -> OTPSendResult {
        throw APIError.unauthenticated
    }
    func verifyOTP(email: String, code: String, purpose: OTPPurpose) async throws -> TokenPair {
        throw APIError.unauthenticated
    }
    func signIn(email: String, password: String) async throws -> TokenPair {
        throw APIError.unauthenticated
    }
    func signInBiometric() async throws -> TokenPair { throw APIError.unauthenticated }
    func refreshToken(_ token: AuthToken) async throws -> TokenPair { throw APIError.unauthenticated }
    func signOut() async throws {}
    func biometricEmail() async -> String? { nil }
}
