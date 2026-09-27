import XCTest
@testable import Sila

/// What a session leaves on the phone outside the keychain: cached responses
/// and the account export. Neither may outlive the session, and the API's
/// answers are never cached to begin with.
final class SessionLeftoversTests: XCTestCase {

    // MARK: - No response cache

    /// `/auth/me` carries the email and the verified legal name; message and
    /// notification lists carry the rest. None of it goes into `Cache.db`.
    func testTheAPIClientWritesNothingToTheURLCache() {
        let client = URLSessionNetworkClient()
        let configuration = client.session.configuration

        XCTAssertNil(configuration.urlCache, "authenticated responses would be written to the shared on-disk cache")
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
        // The rest of the transport's behaviour is unchanged.
        XCTAssertTrue(configuration.waitsForConnectivity)
        XCTAssertEqual(configuration.timeoutIntervalForRequest, AppConfig.requestTimeout)
        XCTAssertEqual(configuration.timeoutIntervalForResource, AppConfig.connectivityWait)
    }

    // MARK: - Swept when the session ends

    private func seededCache(_ leftovers: SessionLeftovers) throws -> URLRequest {
        let request = URLRequest(url: URL(string: "https://sila.gmai.sa/api/v1/media/avatars/a.jpg")!)
        let response = try XCTUnwrap(HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "image/jpeg", "Cache-Control": "max-age=3600"]
        ))
        leftovers.responseCache.storeCachedResponse(CachedURLResponse(response: response, data: Data([1, 2, 3])), for: request)
        return request
    }

    func testClearingTheSessionSweepsTheCacheAndTheExport() async throws {
        let leftovers = SessionLeftovers.isolated()
        let store = AuthTokenStore(keychain: InMemoryKeychainClient(), storage: InMemoryStorageClient(), leftovers: leftovers)
        await store.store(AuthFixtures.pair())
        let request = try seededCache(leftovers)
        let export = try leftovers.writeAccountExport(Data(#"{"exported_at": "now"}"#.utf8))
        XCTAssertNotNil(leftovers.responseCache.cachedResponse(for: request), "precondition: something is cached")
        XCTAssertTrue(FileManager.default.fileExists(atPath: export.path), "precondition: the export exists")

        await store.clear()

        XCTAssertNil(leftovers.responseCache.cachedResponse(for: request))
        XCTAssertFalse(FileManager.default.fileExists(atPath: export.path))
    }

    /// Through the real service: signing out takes the export with it.
    func testSigningOutRemovesTheExport() async throws {
        let leftovers = SessionLeftovers.isolated()
        let store = AuthTokenStore(keychain: InMemoryKeychainClient(), storage: InMemoryStorageClient(), leftovers: leftovers)
        await store.store(AuthFixtures.pair())
        let service = AuthService(
            network: ScriptedNetwork { _ in "{}" },
            store: store,
            biometrics: StubBiometricAuthenticator(),
            analytics: RecordingAnalyticsClient()
        )
        let export = try leftovers.writeAccountExport(Data("{}".utf8))

        try await service.signOut()

        XCTAssertFalse(FileManager.default.fileExists(atPath: export.path))
    }

    /// Whichever service is plugged in — the mock included — the session's
    /// own sign-out sweeps.
    @MainActor
    func testTheSessionsSignOutSweepsWhateverTheService() async throws {
        let leftovers = SessionLeftovers.isolated()
        let store = AuthTokenStore(keychain: InMemoryKeychainClient(), storage: InMemoryStorageClient(), leftovers: leftovers)
        let session = AuthSession(service: AuthServiceMock(scenario: .verified), store: store, analytics: RecordingAnalyticsClient())
        await session.adopt(AuthFixtures.pair())
        let request = try seededCache(leftovers)
        let export = try leftovers.writeAccountExport(Data("{}".utf8))

        await session.signOut()

        XCTAssertFalse(FileManager.default.fileExists(atPath: export.path))
        XCTAssertNil(leftovers.responseCache.cachedResponse(for: request))
    }

    /// Signed out by the server, not by the person: the same sweep.
    func testASessionTheServerEndsIsSweptToo() async throws {
        let leftovers = SessionLeftovers.isolated()
        let store = AuthTokenStore(keychain: InMemoryKeychainClient(), storage: InMemoryStorageClient(), leftovers: leftovers)
        let pair = AuthFixtures.pair(expiresIn: 10)
        await store.store(pair)
        let service = AuthService(
            network: ScriptedNetwork { _ in throw AuthFixtures.refused },
            store: store,
            biometrics: StubBiometricAuthenticator(),
            analytics: RecordingAnalyticsClient()
        )
        let export = try leftovers.writeAccountExport(Data("{}".utf8))

        _ = try? await service.refreshToken(pair.token)

        XCTAssertFalse(FileManager.default.fileExists(atPath: export.path))
    }

    // MARK: - The export file

    func testTheExportIsOneFileOverwrittenInPlace() throws {
        let leftovers = SessionLeftovers.isolated()

        let first = try leftovers.writeAccountExport(Data("one".utf8))
        let second = try leftovers.writeAccountExport(Data("two".utf8))

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.lastPathComponent, SessionLeftovers.accountExportFileName)
        XCTAssertEqual(String(decoding: try Data(contentsOf: second), as: UTF8.self), "two")
        let files = try FileManager.default.contentsOfDirectory(atPath: leftovers.directory.path)
        XCTAssertEqual(files, [SessionLeftovers.accountExportFileName])
    }

    func testRemovingAMissingExportIsNotAnError() {
        let leftovers = SessionLeftovers.isolated()
        leftovers.removeAccountExport()
        leftovers.sweep()
        XCTAssertFalse(FileManager.default.fileExists(atPath: leftovers.accountExportURL.path))
    }
}
