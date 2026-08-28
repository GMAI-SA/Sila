import Foundation

/// Runtime kill-switches — one per phase.
///
/// A phase can be turned off without breaking any other phase. Phase 1 is the
/// only one implemented so far; the rest are declared here so later phases add
/// code, not new flags.
///
/// Launch arguments override the compiled defaults, which is how UI tests and
/// TestFlight builds select a configuration:
///
/// ```
/// -mockAuth            run against AuthServiceMock instead of the live API
/// -mockScenario X      pick an AuthServiceMock.MockScenario by raw value
/// -mockFeed            run against FeedServiceMock instead of the live API
/// -mockFeedScenario X  pick a FeedServiceMock.MockScenario by raw value
/// -mockComposer        run against ComposerServiceMock instead of the live API
/// -mockComposerScenario X  pick a ComposerServiceMock.MockScenario
/// -mockSearch          run against SearchServiceMock instead of the live API
/// -mockSearchScenario X    pick a SearchServiceMock.MockScenario
/// ```
public struct FeatureFlags: Sendable {

    // MARK: Phase toggles

    /// P1 — Authentication. Always on; the app cannot function without it.
    public var auth = true
    /// P2 — Identity verification wizard. Not implemented yet.
    public var verification = false
    /// P3 — Social feed. Turning this off drops verified users back onto the
    /// Phase-1 placeholder instead of ``MainTabView``.
    public var feed = true
    /// P4 — Composer and Explore search. Turning this off puts the `[+]` tab
    /// and the reply bar back to their Phase-3 stubs and returns Explore to a
    /// read-only screen, without touching the feed.
    public var composer = true
    /// P5 — Encrypted messaging.
    public var messaging = false
    /// P5 sub-feature — audio/video calls.
    public var calls = false
    /// P6 — Spaces.
    public var spaces = false
    /// P7 — Profiles.
    public var profile = false
    /// P7 sub-feature — the Deep Dive transparency panel.
    public var deepDive = false
    /// P8 — Monetization.
    public var monetization = false
    /// P8 sub-feature — long-form articles.
    public var articles = false
    /// P10 — Trust engine.
    public var trustEngine = false
    /// P10 sub-feature — community notes.
    public var communityNotes = false
    /// P10 sub-feature — on-device scam detection.
    public var scamDetection = false

    // MARK: Phase 1 build switches

    /// Use ``AuthServiceMock`` instead of the live backend.
    public var useMockAuth = false
    /// Which mock journey to play when ``useMockAuth`` is on.
    public var mockScenario: AuthServiceMock.MockScenario = .pendingReview
    /// Offer the Face ID / Touch ID button on the sign-in screen.
    public var biometricSignIn = true

    // MARK: Phase 3 build switches

    /// Use ``FeedServiceMock`` instead of the live backend.
    public var useMockFeed = false
    /// Which mock world to serve when ``useMockFeed`` is on.
    public var mockFeedScenario: FeedServiceMock.MockScenario = .populated

    // MARK: Phase 4 build switches

    /// Use ``ComposerServiceMock`` instead of the live backend.
    public var useMockComposer = false
    /// Which mock world to serve when ``useMockComposer`` is on.
    public var mockComposerScenario: ComposerServiceMock.MockScenario = .success
    /// Use ``SearchServiceMock`` instead of the live backend.
    public var useMockSearch = false
    /// Which mock world to serve when ``useMockSearch`` is on.
    public var mockSearchScenario: SearchServiceMock.MockScenario = .populated

    public init() {}

    /// Builds the flag set for a launch, applying launch-argument overrides.
    /// - Parameter arguments: Defaults to `ProcessInfo.processInfo.arguments`.
    public static func resolved(
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> FeatureFlags {
        var flags = FeatureFlags()

        if arguments.contains("-mockAuth") {
            flags.useMockAuth = true
        }
        if let index = arguments.firstIndex(of: "-mockScenario"),
           arguments.indices.contains(index + 1),
           let scenario = AuthServiceMock.MockScenario(rawValue: arguments[index + 1]) {
            flags.useMockAuth = true
            flags.mockScenario = scenario
        }
        if arguments.contains("-noBiometrics") {
            flags.biometricSignIn = false
        }
        if arguments.contains("-mockFeed") {
            flags.useMockFeed = true
        }
        if let index = arguments.firstIndex(of: "-mockFeedScenario"),
           arguments.indices.contains(index + 1),
           let scenario = FeedServiceMock.MockScenario(rawValue: arguments[index + 1]) {
            flags.useMockFeed = true
            flags.mockFeedScenario = scenario
        }
        if arguments.contains("-mockComposer") {
            flags.useMockComposer = true
        }
        if let index = arguments.firstIndex(of: "-mockComposerScenario"),
           arguments.indices.contains(index + 1),
           let scenario = ComposerServiceMock.MockScenario(rawValue: arguments[index + 1]) {
            flags.useMockComposer = true
            flags.mockComposerScenario = scenario
        }
        if arguments.contains("-mockSearch") {
            flags.useMockSearch = true
        }
        if let index = arguments.firstIndex(of: "-mockSearchScenario"),
           arguments.indices.contains(index + 1),
           let scenario = SearchServiceMock.MockScenario(rawValue: arguments[index + 1]) {
            flags.useMockSearch = true
            flags.mockSearchScenario = scenario
        }
        // A mocked session has no real bearer token, so a live feed behind it
        // could only ever 401. Mocking auth implies mocking the feed unless the
        // caller asked for a specific feed world.
        if flags.useMockAuth && !arguments.contains("-mockFeedScenario") {
            flags.useMockFeed = true
        }
        // Same reasoning for the Phase-4 services, plus one of its own: a
        // composer demo whose mention list cannot resolve anybody is not a demo.
        if flags.useMockAuth && !arguments.contains("-mockComposerScenario") {
            flags.useMockComposer = true
        }
        if (flags.useMockAuth || flags.useMockComposer) && !arguments.contains("-mockSearchScenario") {
            flags.useMockSearch = true
        }
        return flags
    }
}
