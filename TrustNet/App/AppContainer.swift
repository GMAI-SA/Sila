import Foundation
import SwiftUI

/// The dependency-injection root — the app's **only** singleton.
///
/// Everything else is constructed here and handed down; no type in
/// `Core/` or `Modules/` reaches for a shared instance of anything.
@MainActor
@Observable
public final class AppContainer {

    /// Resolved feature flags for this launch.
    public let flags: FeatureFlags
    /// HTTP transport.
    public let network: NetworkClient
    /// Non-sensitive local persistence.
    public let storage: StorageClient
    /// Secret storage.
    public let keychain: KeychainClient
    /// Product analytics.
    public let analytics: AnalyticsClient
    /// Biometry.
    public let biometrics: BiometricAuthenticating
    /// Phase 1's service.
    public let authService: AuthServiceProtocol
    /// The live session — the object every screen observes.
    public let session: AuthSession
    /// Navigation coordinator.
    public let router: AppRouter

    /// Builds the object graph.
    ///
    /// Pass explicit collaborators in tests; the defaults wire the production
    /// stack (or the mock stack when ``FeatureFlags/useMockAuth`` is set).
    public init(
        flags: FeatureFlags = .resolved(),
        network: NetworkClient? = nil,
        storage: StorageClient? = nil,
        keychain: KeychainClient? = nil,
        analytics: AnalyticsClient? = nil,
        biometrics: BiometricAuthenticating? = nil,
        authService: AuthServiceProtocol? = nil
    ) {
        self.flags = flags

        let network = network ?? URLSessionNetworkClient()
        let storage = storage ?? UserDefaultsStorageClient()
        let keychain = keychain ?? SystemKeychainClient()
        let analytics = analytics ?? ConsoleAnalyticsClient()
        let biometrics = biometrics ?? LocalAuthenticationBiometricAuthenticator()

        self.network = network
        self.storage = storage
        self.keychain = keychain
        self.analytics = analytics
        self.biometrics = biometrics

        let store = AuthTokenStore(keychain: keychain, storage: storage)

        let resolvedService: AuthServiceProtocol
        if let authService {
            resolvedService = authService
        } else if flags.useMockAuth {
            resolvedService = AuthServiceMock(
                scenario: flags.mockScenario,
                latency: 0.4,
                biometry: biometrics.availableBiometry,
                hasBiometricCredential: true
            )
        } else {
            resolvedService = AuthService(
                network: network,
                store: store,
                biometrics: biometrics,
                analytics: analytics
            )
        }

        self.authService = resolvedService
        self.session = AuthSession(service: resolvedService, store: store, analytics: analytics)
        self.router = AppRouter()
    }

    /// A container wired entirely to mocks, for previews.
    public static func preview(
        scenario: AuthServiceMock.MockScenario = .pendingReview
    ) -> AppContainer {
        var flags = FeatureFlags()
        flags.useMockAuth = true
        flags.mockScenario = scenario
        return AppContainer(
            flags: flags,
            network: URLSessionNetworkClient(),
            storage: InMemoryStorageClient(),
            keychain: InMemoryKeychainClient(),
            analytics: RecordingAnalyticsClient(),
            biometrics: StubBiometricAuthenticator(),
            authService: AuthServiceMock(scenario: scenario, hasBiometricCredential: true)
        )
    }
}
