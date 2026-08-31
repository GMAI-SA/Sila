import XCTest
@testable import Sila

/// Drives the deployed safety API through the app's own decoders.
///
/// The fixture tests agree with the contract by construction; these are the
/// only ones that would notice the server disagreeing — and here that matters
/// more than anywhere else, because a block the client believes it made and
/// the server did not is a safety failure that looks like success.
///
/// **Deliberately non-destructive.** It blocks and mutes a seeded demo account
/// and puts both back. It does *not* file reports — a report creates a row in
/// the moderation queue that no API can remove, so the report paths that write
/// something are covered by the backend suite where the accounts are
/// disposable. What is exercised here are the refusals, which are safe to
/// provoke precisely because they create nothing.
///
/// Suspension is untestable from here for the same reason: the only account
/// available is a real one, and suspending it to watch the screen appear would
/// require a moderator to undo.
///
/// ```
/// TEST_RUNNER_SILA_LIVE_API=1 TEST_RUNNER_SILA_LIVE_EMAIL=… \
/// TEST_RUNNER_SILA_LIVE_PASSWORD=… xcodebuild … test
/// ```
final class LiveSafetyTests: XCTestCase {

    /// A seeded demo account, not a real person's.
    private let subject = "yuki"
    private var token: String?
    /// The signed-in account's own handle, for the self-action refusals.
    private var myHandle = ""

    override func setUp() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["SILA_LIVE_API"] == "1" else {
            throw XCTSkip("Live API tests are opt-in — set SILA_LIVE_API=1")
        }
        guard let email = env["SILA_LIVE_EMAIL"], let password = env["SILA_LIVE_PASSWORD"] else {
            throw XCTSkip("Set SILA_LIVE_EMAIL and SILA_LIVE_PASSWORD")
        }
        let auth = AuthService(
            network: URLSessionNetworkClient(),
            store: AuthTokenStore(keychain: InMemoryKeychainClient(), storage: InMemoryStorageClient()),
            biometrics: StubBiometricAuthenticator(),
            analytics: RecordingAnalyticsClient()
        )
        token = try await auth.signIn(email: email, password: password).token.accessToken
        let me = try await auth.currentUser()
        myHandle = try XCTUnwrap(
            me.handle,
            "the live account has no handle, so the self-action tests cannot run"
        )
    }

    override func tearDown() async throws {
        // Never leave a real account blocking or muting somebody because a
        // test ran.
        guard let token, !token.isEmpty else { return }
        let service = SafetyService(
            network: URLSessionNetworkClient(),
            tokens: StaticAccessTokenProvider(token: token),
            analytics: RecordingAnalyticsClient()
        )
        _ = try? await service.setBlocked(false, handle: subject)
        _ = try? await service.setMuted(false, handle: subject)
    }

    private func service() throws -> SafetyService {
        SafetyService(
            network: URLSessionNetworkClient(),
            tokens: StaticAccessTokenProvider(token: try XCTUnwrap(token)),
            analytics: RecordingAnalyticsClient()
        )
    }

    private func profiles() throws -> ProfileService {
        ProfileService(
            network: URLSessionNetworkClient(),
            tokens: StaticAccessTokenProvider(token: try XCTUnwrap(token)),
            analytics: RecordingAnalyticsClient()
        )
    }

    // MARK: - Blocking

    /// The whole point: after a block the account must actually be gone, not
    /// merely marked blocked in a local list.
    func testBlockingRemovesTheAccountAndUnblockingRestoresIt() async throws {
        let service = try service()
        let profiles = try profiles()

        _ = try await profiles.fetchProfile(handle: subject)  // reachable to begin with

        let blocked = try await service.setBlocked(true, handle: subject)
        XCTAssertTrue(blocked)

        let blockedList = try await service.fetchBlocked()
        XCTAssertTrue(
            blockedList.contains { $0.user.handle == subject },
            "the block did not appear on the account's own list"
        )

        do {
            _ = try await profiles.fetchProfile(handle: subject)
            XCTFail("a blocked account's profile is still readable")
        } catch let error as APIError {
            // 404, not 403, on purpose: a block is indistinguishable from an
            // account that never existed, so it cannot be detected by probing.
            XCTAssertEqual(error.code, .userNotFound)
        }

        let unblocked = try await service.setBlocked(false, handle: subject)
        XCTAssertFalse(unblocked)
        _ = try await profiles.fetchProfile(handle: subject)
        let afterUnblock = try await service.fetchBlocked()
        XCTAssertFalse(afterUnblock.contains { $0.user.handle == subject })
    }

    func testBlockingTwiceIsHarmless() async throws {
        let service = try service()
        _ = try await service.setBlocked(true, handle: subject)
        _ = try await service.setBlocked(true, handle: subject)
        let list = try await service.fetchBlocked().filter { $0.user.handle == subject }
        XCTAssertEqual(list.count, 1, "a repeated block duplicated the row")
    }

    // MARK: - Muting

    /// A mute must leave everything the other person can do untouched — which
    /// is exactly what makes it the humane option.
    func testMutingIsReversibleAndLeavesTheProfileReadable() async throws {
        let service = try service()

        _ = try await service.setMuted(true, handle: subject)
        let muted = try await service.fetchMuted()
        XCTAssertTrue(muted.contains { $0.user.handle == subject })

        // Unlike a block, the account is still there.
        _ = try await profiles().fetchProfile(handle: subject)

        _ = try await service.setMuted(false, handle: subject)
        let afterUnmute = try await service.fetchMuted()
        XCTAssertFalse(afterUnmute.contains { $0.user.handle == subject })
    }

    // MARK: - Refusals (safe: they create nothing)

    func testReportingYourselfIsRefused() async throws {
        do {
            _ = try await service().submitReport(
                ReportRequest(userHandle: myHandle, reason: .spam)
            )
            XCTFail("the server accepted a self-report")
        } catch let error as APIError {
            XCTAssertEqual(error.code, .selfReport)
        }
    }

    func testBlockingYourselfIsRefused() async throws {
        do {
            _ = try await service().setBlocked(true, handle: myHandle)
            XCTFail("the server accepted a self-block")
        } catch let error as APIError {
            XCTAssertEqual(error.code, .selfBlock)
        }
    }

    // MARK: - Reading

    /// `GET /me/suspension` must answer for an account in good standing too —
    /// it is polled to decide whether to show the suspension screen at all.
    func testSuspensionReadsAsNotSuspended() async throws {
        let state = try await service().fetchSuspension()
        XCTAssertFalse(state.suspended, "the live account should not be suspended")
        XCTAssertNil(state.reason)
    }

    func testMyReportsDecodes() async throws {
        _ = try await service().fetchReports()
    }
}
