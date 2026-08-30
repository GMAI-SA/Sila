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
    /// On-device session secrets.
    public let tokenStore: AuthTokenStore
    /// The live session — the object every screen observes.
    public let session: AuthSession
    /// Phase 3's service.
    public let feedService: FeedServiceProtocol
    /// Phase 4's post-creation service.
    public let composerService: ComposerServiceProtocol
    /// Phase 4's search service — Explore and `@mention` autocomplete.
    public let searchService: SearchServiceProtocol
    /// Contract v4's interests service — topics and feed preferences.
    public let preferencesService: PreferencesServiceProtocol
    /// Contract v5's account service — profile, credentials, export, deletion.
    public let accountService: AccountServiceProtocol
    /// Phase 7's profile service — other people's pages, timelines and follows.
    public let profileService: ProfileServiceProtocol
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
        authService: AuthServiceProtocol? = nil,
        feedService: FeedServiceProtocol? = nil,
        composerService: ComposerServiceProtocol? = nil,
        searchService: SearchServiceProtocol? = nil,
        preferencesService: PreferencesServiceProtocol? = nil,
        accountService: AccountServiceProtocol? = nil,
        profileService: ProfileServiceProtocol? = nil
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
        self.tokenStore = store
        self.session = AuthSession(service: resolvedService, store: store, analytics: analytics)

        // One provider for every authenticated service, so a token refreshed by
        // any of them is picked up by all of them.
        let tokens = SessionAccessTokenProvider(store: store, service: resolvedService)

        if let feedService {
            self.feedService = feedService
        } else if flags.useMockFeed {
            self.feedService = FeedServiceMock(scenario: flags.mockFeedScenario, latency: 0.35)
        } else {
            self.feedService = FeedService(network: network, tokens: tokens, analytics: analytics)
        }

        if let composerService {
            self.composerService = composerService
        } else if flags.useMockComposer {
            self.composerService = ComposerServiceMock(
                scenario: flags.mockComposerScenario,
                latency: 0.35
            )
        } else {
            self.composerService = ComposerService(network: network, tokens: tokens, analytics: analytics)
        }

        if let searchService {
            self.searchService = searchService
        } else if flags.useMockSearch {
            self.searchService = SearchServiceMock(scenario: flags.mockSearchScenario, latency: 0.25)
        } else {
            self.searchService = SearchService(network: network, tokens: tokens, analytics: analytics)
        }

        if let preferencesService {
            self.preferencesService = preferencesService
        } else if flags.useMockPreferences {
            self.preferencesService = PreferencesServiceMock(
                scenario: flags.mockPreferencesScenario,
                latency: 0.3
            )
        } else {
            self.preferencesService = PreferencesService(
                network: network,
                tokens: tokens,
                analytics: analytics
            )
        }

        if let accountService {
            self.accountService = accountService
        } else if flags.useMockAccount {
            self.accountService = AccountServiceMock(
                scenario: flags.mockAccountScenario,
                latency: 0.3
            )
        } else {
            self.accountService = AccountService(
                network: network,
                tokens: tokens,
                analytics: analytics
            )
        }

        if let profileService {
            self.profileService = profileService
        } else if flags.useMockProfile {
            self.profileService = ProfileServiceMock(
                scenario: flags.mockProfileScenario,
                latency: 0.3
            )
        } else {
            self.profileService = ProfileService(
                network: network,
                tokens: tokens,
                analytics: analytics
            )
        }

        self.router = AppRouter()
    }

    /// A container wired entirely to mocks, for previews.
    public static func preview(
        scenario: AuthServiceMock.MockScenario = .pendingReview,
        feedScenario: FeedServiceMock.MockScenario = .populated,
        composerScenario: ComposerServiceMock.MockScenario = .success,
        searchScenario: SearchServiceMock.MockScenario = .populated,
        preferencesScenario: PreferencesServiceMock.MockScenario = .populated,
        accountScenario: AccountServiceMock.MockScenario = .populated,
        profileScenario: ProfileServiceMock.MockScenario = .populated
    ) -> AppContainer {
        var flags = FeatureFlags()
        flags.useMockAuth = true
        flags.mockScenario = scenario
        flags.useMockFeed = true
        flags.mockFeedScenario = feedScenario
        flags.useMockComposer = true
        flags.mockComposerScenario = composerScenario
        flags.useMockSearch = true
        flags.mockSearchScenario = searchScenario
        flags.useMockPreferences = true
        flags.mockPreferencesScenario = preferencesScenario
        flags.useMockAccount = true
        flags.mockAccountScenario = accountScenario
        flags.useMockProfile = true
        flags.mockProfileScenario = profileScenario
        return AppContainer(
            flags: flags,
            network: URLSessionNetworkClient(),
            storage: InMemoryStorageClient(),
            keychain: InMemoryKeychainClient(),
            analytics: RecordingAnalyticsClient(),
            biometrics: StubBiometricAuthenticator(),
            authService: AuthServiceMock(scenario: scenario, hasBiometricCredential: true),
            feedService: FeedServiceMock(scenario: feedScenario),
            composerService: ComposerServiceMock(scenario: composerScenario),
            searchService: SearchServiceMock(scenario: searchScenario),
            preferencesService: PreferencesServiceMock(scenario: preferencesScenario),
            accountService: AccountServiceMock(scenario: accountScenario),
            profileService: ProfileServiceMock(scenario: profileScenario)
        )
    }
}
