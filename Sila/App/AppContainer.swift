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
    /// Blocking, muting, reporting, and the two endpoints a suspended account
    /// may still call.
    public let safetyService: SafetyServiceProtocol
    /// Follows, likes, reposts, replies and mentions.
    public let notificationsService: NotificationsServiceProtocol
    /// Live voice rooms — listing, joining, hosting.
    public let roomsService: RoomsServiceProtocol
    /// Whether the app should be showing nothing but the suspension screen.
    ///
    /// Constructed **before** the network client and handed to it, so every
    /// request in the app reports `403 account_suspended` through one place. A
    /// suspended account cannot find a screen whose author forgot to catch it.
    public let suspension: SuspensionMonitor
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
        profileService: ProfileServiceProtocol? = nil,
        safetyService: SafetyServiceProtocol? = nil,
        notificationsService: NotificationsServiceProtocol? = nil,
        roomsService: RoomsServiceProtocol? = nil
    ) {
        self.flags = flags

        // First, because the transport takes it: the suspension interception is
        // one line in one place rather than a `catch` on every view model.
        let suspension = SuspensionMonitor(analytics: analytics ?? ConsoleAnalyticsClient())
        self.suspension = suspension

        let network = network ?? URLSessionNetworkClient(suspension: suspension.signal)
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

        if let safetyService {
            self.safetyService = safetyService
        } else if flags.useMockSafety {
            self.safetyService = SafetyServiceMock(
                scenario: flags.mockSafetyScenario,
                latency: 0.25
            )
        } else {
            self.safetyService = SafetyService(
                network: network,
                tokens: tokens,
                analytics: analytics
            )
        }

        if let notificationsService {
            self.notificationsService = notificationsService
        } else if flags.useMockNotifications {
            self.notificationsService = NotificationsServiceMock(
                scenario: flags.mockNotificationsScenario,
                latency: 0.25
            )
        } else {
            self.notificationsService = NotificationsService(
                network: network,
                tokens: tokens,
                analytics: analytics
            )
        }

        if let roomsService {
            self.roomsService = roomsService
        } else if flags.useMockRooms {
            self.roomsService = RoomsServiceMock(
                scenario: flags.mockRoomsScenario,
                latency: 0.25,
                // The demo cast's own handle. The mock only uses it for the
                // host-only refusals, and a mocked session is not signed into
                // anything the store would know about anyway.
                viewerHandle: "aziz"
            )
        } else {
            self.roomsService = RoomsService(
                network: network,
                tokens: tokens,
                analytics: analytics
            )
        }

        self.router = AppRouter()
    }

    /// A fresh media transport for one room.
    ///
    /// Built per room rather than held here, because a ``VoiceEngineProtocol``
    /// owns exactly one connection and a shared one would mean the second room
    /// somebody opened silently stole the first one's socket. The mocked engine
    /// is used whenever the rooms service is mocked: a mocked join hands back a
    /// token no real media server would accept.
    @MainActor
    public func makeVoiceEngine() -> VoiceEngineProtocol {
        flags.useMockVoiceEngine ? VoiceEngineMock() : LiveKitVoiceEngine()
    }

    /// A container wired entirely to mocks, for previews.
    public static func preview(
        scenario: AuthServiceMock.MockScenario = .pendingReview,
        feedScenario: FeedServiceMock.MockScenario = .populated,
        composerScenario: ComposerServiceMock.MockScenario = .success,
        searchScenario: SearchServiceMock.MockScenario = .populated,
        preferencesScenario: PreferencesServiceMock.MockScenario = .populated,
        accountScenario: AccountServiceMock.MockScenario = .populated,
        profileScenario: ProfileServiceMock.MockScenario = .populated,
        safetyScenario: SafetyServiceMock.MockScenario = .populated,
        notificationsScenario: NotificationsServiceMock.MockScenario = .populated,
        roomsScenario: RoomsServiceMock.MockScenario = .populated
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
        flags.useMockSafety = true
        flags.mockSafetyScenario = safetyScenario
        flags.useMockNotifications = true
        flags.mockNotificationsScenario = notificationsScenario
        flags.useMockRooms = true
        flags.mockRoomsScenario = roomsScenario
        flags.useMockVoiceEngine = true
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
            profileService: ProfileServiceMock(scenario: profileScenario),
            safetyService: SafetyServiceMock(scenario: safetyScenario),
            notificationsService: NotificationsServiceMock(scenario: notificationsScenario),
            roomsService: RoomsServiceMock(scenario: roomsScenario)
        )
    }
}
