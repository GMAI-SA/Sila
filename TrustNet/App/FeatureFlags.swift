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
    /// P4 — Composer.
    public var composer = false
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
        // A mocked session has no real bearer token, so a live feed behind it
        // could only ever 401. Mocking auth implies mocking the feed unless the
        // caller asked for a specific feed world.
        if flags.useMockAuth && !arguments.contains("-mockFeedScenario") {
            flags.useMockFeed = true
        }
        return flags
    }
}
