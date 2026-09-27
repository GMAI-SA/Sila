import Security
import XCTest
@testable import Sila

/// iOS deletes an app's UserDefaults with the app, and keeps its Keychain
/// items. Somebody who deletes Sila to sign out of a shared or handed-down
/// phone must not be signed straight back in by reinstalling it.
final class ReinstallTests: XCTestCase {

    /// A keychain left behind by an earlier install: a session and the
    /// cached account, verified name and all.
    private func keychainFromAnEarlierInstall() throws -> InMemoryKeychainClient {
        let keychain = InMemoryKeychainClient()
        let pair = AuthFixtures.pair()
        try keychain.save(pair.token, for: .authToken)
        try keychain.save(pair.user, for: .cachedUser)
        try keychain.saveString("aziz@example.com", for: .biometricEmail)
        return keychain
    }

    func testAReinstallWipesTheSessionTheKeychainKept() async throws {
        let keychain = try keychainFromAnEarlierInstall()
        let storage = InMemoryStorageClient()
        let store = AuthTokenStore(keychain: keychain, storage: storage, leftovers: .isolated())

        let token = await store.token()
        let user = await store.user()

        XCTAssertNil(token, "the previous install's session came back")
        XCTAssertNil(user, "the previous install's account, verified name included, came back")
        XCTAssertNil(try keychain.load(.authToken))
        XCTAssertNil(try keychain.load(.cachedUser))
        XCTAssertNil(try keychain.load(.biometricEmail))
        XCTAssertTrue(storage.flag(.installed), "the install is marked, so the next launch keeps its session")
    }

    /// An update from a build before the marker existed: UserDefaults
    /// survived, and with it the email every sign-in writes. The session is
    /// the person's own and stays.
    func testAnUpdateFromABuildBeforeTheMarkerKeepsTheSession() async throws {
        let keychain = try keychainFromAnEarlierInstall()
        let storage = InMemoryStorageClient()
        storage.set("aziz@example.com", for: .lastSignedInEmail)
        let store = AuthTokenStore(keychain: keychain, storage: storage, leftovers: .isolated())

        let token = await store.token()

        XCTAssertEqual(token?.refreshToken, "refresh-0")
        XCTAssertTrue(storage.flag(.installed))
    }

    /// The same install, launched again: the marker is there, the session is
    /// kept.
    func testTheNextLaunchOfTheSameInstallKeepsTheSession() async throws {
        let keychain = InMemoryKeychainClient()
        let storage = InMemoryStorageClient()
        let first = AuthTokenStore(keychain: keychain, storage: storage, leftovers: .isolated())
        _ = await first.token()
        await first.store(AuthFixtures.pair())

        let relaunched = AuthTokenStore(keychain: keychain, storage: storage, leftovers: .isolated())
        let token = await relaunched.token()

        XCTAssertEqual(token?.refreshToken, "refresh-0")
    }

    /// A keychain that cannot be read — the phone is locked, and before the
    /// first unlock UserDefaults reads back empty too — decides nothing.
    func testALockedPhoneDecidesNothing() async {
        let keychain = LockedKeychain()
        let storage = InMemoryStorageClient()
        let store = AuthTokenStore(keychain: keychain, storage: storage, leftovers: .isolated())

        _ = await store.token()

        XCTAssertEqual(keychain.deleteAllCalls, 0, "wiped a keychain it could not even read")
        XCTAssertFalse(storage.flag(.installed), "the next launch must ask again")
    }

    /// The whole launch: a reinstalled app opens signed out, without even
    /// asking the server about the old session.
    @MainActor
    func testAReinstalledAppOpensSignedOut() async throws {
        let keychain = try keychainFromAnEarlierInstall()
        let network = ScriptedNetwork { request in
            // Would have restored the session, had it been asked.
            request.path == "/auth/me" ? AuthFixtures.userJSON() : "{}"
        }
        let container = AppContainer(
            flags: FeatureFlags(),
            network: network,
            storage: InMemoryStorageClient(),
            keychain: keychain,
            analytics: RecordingAnalyticsClient(),
            biometrics: StubBiometricAuthenticator()
        )

        await container.session.restore()

        XCTAssertEqual(container.session.route, .unauthenticated)
        XCTAssertNil(try keychain.load(.authToken))
        XCTAssertEqual(network.count("/auth/me"), 0)
    }
}

/// A keychain as it is while the phone is locked: every read refused.
private final class LockedKeychain: KeychainClient, @unchecked Sendable {

    private let lock = NSLock()
    private var deletes = 0

    var deleteAllCalls: Int { lock.withLock { deletes } }

    func save(_ data: Data, for key: KeychainKey) throws {
        throw KeychainError.status(errSecInteractionNotAllowed)
    }

    func load(_ key: KeychainKey) throws -> Data? {
        throw KeychainError.status(errSecInteractionNotAllowed)
    }

    func delete(_ key: KeychainKey) throws {}

    func deleteAll() throws {
        lock.withLock { deletes += 1 }
    }
}
