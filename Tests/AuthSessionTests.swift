import XCTest
@testable import Sila

/// Session routing: the single place that decides feed vs. wall vs. rejected.
@MainActor
final class AuthSessionTests: XCTestCase {

    private func makeSession(
        scenario: AuthServiceMock.MockScenario
    ) -> (AuthSession, AuthTokenStore, InMemoryKeychainClient) {
        let keychain = InMemoryKeychainClient()
        let storage = InMemoryStorageClient()
        let store = AuthTokenStore(keychain: keychain, storage: storage)
        let session = AuthSession(
            service: AuthServiceMock(scenario: scenario),
            store: store,
            analytics: RecordingAnalyticsClient()
        )
        return (session, store, keychain)
    }

    private func makePair(
        status: VerificationStatus,
        emailVerified: Bool = true,
        expiresIn: TimeInterval = 3600
    ) -> TokenPair {
        TokenPair(
            token: AuthToken(
                accessToken: "access",
                refreshToken: "refresh",
                expiresAt: Date().addingTimeInterval(expiresIn)
            ),
            user: AuthUser(
                id: UUID(),
                email: "aziz@example.com",
                displayName: nil,
                emailVerified: emailVerified,
                verificationStatus: status,
                createdAt: Date()
            )
        )
    }

    // MARK: Routing on adopt

    func testVerifiedUserReachesTheFeed() async {
        let (session, _, _) = makeSession(scenario: .verified)
        await session.adopt(makePair(status: .verified))
        XCTAssertEqual(session.route, .feed)
    }

    func testUnstartedUserIsHeldOnTheWall() async {
        let (session, _, _) = makeSession(scenario: .unstarted)
        await session.adopt(makePair(status: .unstarted))
        XCTAssertEqual(session.route, .verificationWall(.unstarted))
    }

    func testInProgressUserIsHeldOnTheWall() async {
        let (session, _, _) = makeSession(scenario: .inProgress)
        await session.adopt(makePair(status: .inProgress))
        XCTAssertEqual(session.route, .verificationWall(.inProgress))
    }

    func testPendingReviewUserIsHeldOnTheWall() async {
        let (session, _, _) = makeSession(scenario: .pendingReview)
        await session.adopt(makePair(status: .pendingReview))
        XCTAssertEqual(session.route, .verificationWall(.pendingReview))
    }

    func testRejectedUserGetsTheRejectedScreenWithTheServerReason() async {
        let (session, _, _) = makeSession(scenario: .rejected)
        await session.adopt(makePair(status: .rejected))

        guard case let .rejected(reason) = session.route else {
            return XCTFail("Expected the rejected route, got \(session.route)")
        }
        XCTAssertNotNil(reason, "The rejection reason must be fetched for display")
    }

    func testUnconfirmedEmailOutranksVerificationStatus() async {
        let (session, _, _) = makeSession(scenario: .verified)
        await session.adopt(makePair(status: .verified, emailVerified: false))
        XCTAssertEqual(session.route, .awaitingEmailVerification(email: "aziz@example.com"))
    }

    // MARK: Cold launch

    func testRestoreWithoutAStoredTokenLandsOnWelcome() async {
        let (session, _, _) = makeSession(scenario: .verified)
        await session.restore()
        XCTAssertEqual(session.route, .unauthenticated)
    }

    func testRestoreWithAnUnusableStoredTokenClearsItAndLandsOnWelcome() async {
        let (session, store, keychain) = makeSession(scenario: .verified)
        // The mock has no session of its own, so `/auth/me` will fail.
        await store.store(makePair(status: .verified))

        await session.restore()

        XCTAssertEqual(session.route, .unauthenticated)
        XCTAssertNil(session.user)
        let leftovers = try? keychain.load(.authToken)
        XCTAssertNil(leftovers, "An unusable session must not leave a token behind")
    }

    // MARK: Sign out

    func testSignOutClearsTheSessionAndReturnsToWelcome() async {
        let (session, _, _) = makeSession(scenario: .verified)
        await session.adopt(makePair(status: .verified))

        await session.signOut()

        XCTAssertNil(session.user)
        XCTAssertEqual(session.route, .unauthenticated)
    }

    // MARK: Public export surface

    func testRequireVerifiedThrowsWhenSignedOut() async {
        let (session, _, _) = makeSession(scenario: .verified)
        do {
            try await session.requireVerified()
            XCTFail("Expected requireVerified to throw")
        } catch let error as AuthGateError {
            XCTAssertEqual(error, .notAuthenticated)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRequireVerifiedThrowsWithTheStatusWhenUnverified() async {
        let (session, _, _) = makeSession(scenario: .pendingReview)
        await session.adopt(makePair(status: .pendingReview))

        do {
            try await session.requireVerified()
            XCTFail("Expected requireVerified to throw")
        } catch let error as AuthGateError {
            XCTAssertEqual(error, .notVerified(.pendingReview))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRequireVerifiedPassesForAVerifiedUser() async throws {
        let (session, _, _) = makeSession(scenario: .verified)
        await session.adopt(makePair(status: .verified))

        try await session.requireVerified()

        let isVerified = await session.isVerified
        XCTAssertTrue(isVerified)
        let user = await session.currentUser
        XCTAssertEqual(user?.email, "aziz@example.com")
    }
}

/// Token expiry arithmetic that drives proactive refresh.
final class AuthTokenTests: XCTestCase {

    func testAFreshTokenIsNeitherExpiredNorExpiringSoon() {
        let token = AuthToken(
            accessToken: "a",
            refreshToken: "r",
            expiresAt: Date().addingTimeInterval(3600)
        )
        XCTAssertFalse(token.isExpired)
        XCTAssertFalse(token.expiresSoon())
    }

    func testAPastExpiryIsExpired() {
        let token = AuthToken(
            accessToken: "a",
            refreshToken: "r",
            expiresAt: Date().addingTimeInterval(-1)
        )
        XCTAssertTrue(token.isExpired)
        XCTAssertTrue(token.expiresSoon())
    }

    func testATokenInsideTheLeewayWindowCountsAsExpiringSoon() {
        let token = AuthToken(
            accessToken: "a",
            refreshToken: "r",
            expiresAt: Date().addingTimeInterval(30)
        )
        XCTAssertFalse(token.isExpired)
        XCTAssertTrue(token.expiresSoon(leeway: 60))
        XCTAssertFalse(token.expiresSoon(leeway: 10))
    }
}

/// The keychain-backed token store.
final class AuthTokenStoreTests: XCTestCase {

    private func makeStore() -> (AuthTokenStore, InMemoryKeychainClient, InMemoryStorageClient) {
        let keychain = InMemoryKeychainClient()
        let storage = InMemoryStorageClient()
        return (AuthTokenStore(keychain: keychain, storage: storage), keychain, storage)
    }

    private var samplePair: TokenPair {
        TokenPair(
            token: AuthToken(
                accessToken: "access",
                refreshToken: "refresh",
                expiresAt: Date().addingTimeInterval(3600)
            ),
            user: AuthUser(
                id: UUID(),
                email: "aziz@example.com",
                emailVerified: true,
                verificationStatus: .verified,
                createdAt: Date()
            )
        )
    }

    func testStoringPersistsTheTokenTheUserAndTheLastEmail() async {
        let (store, _, storage) = makeStore()

        await store.store(samplePair)

        let token = await store.token()
        XCTAssertEqual(token?.accessToken, "access")
        let user = await store.user()
        XCTAssertEqual(user?.email, "aziz@example.com")
        XCTAssertEqual(storage.value(for: .lastSignedInEmail, as: String.self), "aziz@example.com")
    }

    func testBiometricEmailIsOnlyReturnedWhenTheFlagIsSet() async {
        let (store, _, _) = makeStore()

        var email = await store.biometricEmail()
        XCTAssertNil(email)

        await store.enableBiometrics(for: "aziz@example.com")
        email = await store.biometricEmail()
        XCTAssertEqual(email, "aziz@example.com")
    }

    func testClearWipesEverySecret() async {
        let (store, keychain, storage) = makeStore()
        await store.store(samplePair)
        await store.enableBiometrics(for: "aziz@example.com")

        await store.clear()

        let token = await store.token()
        XCTAssertNil(token)
        let user = await store.user()
        XCTAssertNil(user)
        let email = await store.biometricEmail()
        XCTAssertNil(email)
        XCTAssertNil(try? keychain.load(.authToken))
        XCTAssertFalse(storage.flag(.biometricEnabled))
    }
}
