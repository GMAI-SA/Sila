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
/// -mockVerification    run against VerificationServiceMock instead of the live API
/// -mockVerificationScenario X  pick a VerificationServiceMock.MockScenario
/// -mockFeed            run against FeedServiceMock instead of the live API
/// -mockFeedScenario X  pick a FeedServiceMock.MockScenario by raw value
/// -mockComposer        run against ComposerServiceMock instead of the live API
/// -mockComposerScenario X  pick a ComposerServiceMock.MockScenario
/// -mockSearch          run against SearchServiceMock instead of the live API
/// -mockSearchScenario X    pick a SearchServiceMock.MockScenario
/// -mockPreferences     run against PreferencesServiceMock instead of the live API
/// -mockPreferencesScenario X  pick a PreferencesServiceMock.MockScenario
/// -mockAccount         run against AccountServiceMock instead of the live API
/// -mockAccountScenario X   pick an AccountServiceMock.MockScenario
/// -mockProfile         run against ProfileServiceMock instead of the live API
/// -mockProfileScenario X   pick a ProfileServiceMock.MockScenario
/// -mockSafety          run against SafetyServiceMock instead of the live API
/// -mockSafetyScenario X    pick a SafetyServiceMock.MockScenario
/// -mockNotifications   run against NotificationsServiceMock instead of the live API
/// -mockNotificationsScenario X  pick a NotificationsServiceMock.MockScenario
/// -mockRooms           run against RoomsServiceMock instead of the live API
/// -mockRoomsScenario X pick a RoomsServiceMock.MockScenario
/// -mockVoiceEngine     run against VoiceEngineMock instead of LiveKit
/// ```
public struct FeatureFlags: Sendable {

    // MARK: Phase toggles

    /// P1 — Authentication. Always on; the app cannot function without it.
    public var auth = true
    /// P2 — Nafath identity verification. Turning this off puts the wall's
    /// "Start Verification" back to its honest stub toast; accounts already
    /// verified are untouched, because the client does not own the status.
    public var verification = true
    /// P3 — Social feed. Turning this off drops verified users back onto the
    /// Phase-1 placeholder instead of ``MainTabView``.
    public var feed = true
    /// P4 — Composer and Explore search. Turning this off puts the `[+]` tab
    /// and the reply bar back to their Phase-3 stubs and returns Explore to a
    /// read-only screen, without touching the feed.
    public var composer = true
    /// v4 — Feed preferences: topic interests, muted topics and muted
    /// countries, plus the disclosure of the automatic topic labelling those
    /// controls exist for. Turning this off hides the entry points; the stored
    /// preferences on the server keep applying, because the client does not
    /// own them.
    public var preferences = true
    /// v5 — Account management: profile, picture, credentials, export and
    /// deletion. Turning this off hides the entry point; the endpoints keep
    /// working, because the client does not own the account.
    public var account = true
    /// P5 — private messages: an inbox, a request folder, and one thread.
    ///
    /// **Not encrypted, and never described as such.** The blueprint asked for
    /// end-to-end encryption *and* server-side scam warnings; those are
    /// mutually exclusive, because a server that cannot read a message can
    /// neither warn about it nor act on a report about it. The body is stored
    /// opaquely so ciphertext can replace plaintext later, once reporting has
    /// an answer.
    public var messaging = true
    /// Drives the messages surface from ``MessagesServiceMock``.
    public var useMockMessages = false
    /// P5 sub-feature — audio/video calls.
    public var calls = false
    /// P6 — Voice rooms. Turning this off removes the Rooms tab and every
    /// route into a room; the rooms already open on the server keep running,
    /// because the client does not own them.
    public var rooms = true
    /// P6 — Spaces.
    public var spaces = false
    /// P7 — Profiles: another person's page, their top-level posts, and the
    /// follow button. Turning this off removes every route into a profile and
    /// puts the Profile tab back to account settings and sign-out only; the
    /// follows already stored on the server keep deciding the Following feed,
    /// because the client does not own them.
    public var profile = true
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

    // MARK: Phase 2 build switches

    /// Use ``VerificationServiceMock`` instead of the live backend.
    public var useMockVerification = false
    /// Which mock journey to play when ``useMockVerification`` is on.
    public var mockVerificationScenario: VerificationServiceMock.MockScenario = .approved

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

    // MARK: Contract v4 build switches

    /// Use ``PreferencesServiceMock`` instead of the live backend.
    public var useMockPreferences = false
    /// Which mock world to serve when ``useMockPreferences`` is on.
    public var mockPreferencesScenario: PreferencesServiceMock.MockScenario = .populated

    // MARK: Contract v5 build switches

    /// Use ``AccountServiceMock`` instead of the live backend.
    public var useMockAccount = false
    /// Which mock world to serve when ``useMockAccount`` is on.
    public var mockAccountScenario: AccountServiceMock.MockScenario = .populated

    // MARK: Phase 7 build switches

    /// Use ``ProfileServiceMock`` instead of the live backend.
    public var useMockProfile = false
    /// Which mock world to serve when ``useMockProfile`` is on.
    public var mockProfileScenario: ProfileServiceMock.MockScenario = .populated

    // MARK: Safety build switches

    /// Use ``SafetyServiceMock`` instead of the live backend.
    ///
    /// > Note: There is deliberately **no `safety` phase toggle** beside the
    /// > others above. Every flag in this type has a genuine off state that
    /// > hides an affordance; blocking and reporting are the two things App
    /// > Store Review Guideline 1.2 requires of any app carrying
    /// > user-generated content, so an off state for them would be a switch
    /// > whose only function is to make the app unshippable. A kill switch you
    /// > can never pull is not a kill switch — it is a way to ship the bug by
    /// > accident.
    public var useMockSafety = false
    /// Which mock world to serve when ``useMockSafety`` is on.
    public var mockSafetyScenario: SafetyServiceMock.MockScenario = .populated

    // MARK: Notifications build switches

    /// Use ``NotificationsServiceMock`` instead of the live backend.
    ///
    /// > Note: Like safety, notifications have **no phase toggle**. The tab
    /// > exists in the shell either way, and a flag whose off state is an empty
    /// > bell icon would only be a way to ship a screen that looks broken.
    public var useMockNotifications = false
    /// Which mock world to serve when ``useMockNotifications`` is on.
    public var mockNotificationsScenario: NotificationsServiceMock.MockScenario = .populated

    // MARK: Voice rooms build switches

    /// Use ``RoomsServiceMock`` instead of the live backend.
    public var useMockRooms = false
    /// Which mock world to serve when ``useMockRooms`` is on.
    public var mockRoomsScenario: RoomsServiceMock.MockScenario = .populated
    /// Use ``VoiceEngineMock`` instead of LiveKit.
    ///
    /// Implied by ``useMockRooms``: a mocked join hands back a token no real
    /// media server would accept, so a live engine behind it could only ever
    /// fail to connect. It is separately settable because the reverse is
    /// occasionally useful — real rooms, no audio, on a machine with no
    /// microphone.
    public var useMockVoiceEngine = false

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
        if arguments.contains("-mockVerification") {
            flags.useMockVerification = true
        }
        if let index = arguments.firstIndex(of: "-mockVerificationScenario"),
           arguments.indices.contains(index + 1),
           let scenario = VerificationServiceMock.MockScenario(rawValue: arguments[index + 1]) {
            flags.useMockVerification = true
            flags.mockVerificationScenario = scenario
        }
        // A mocked session's token would 401 against the real
        // `/verification/nafath/start`, and spending a real identity is not
        // something a demo should ever do.
        if flags.useMockAuth && !arguments.contains("-mockVerificationScenario") {
            flags.useMockVerification = true
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
        if arguments.contains("-mockPreferences") {
            flags.useMockPreferences = true
        }
        if let index = arguments.firstIndex(of: "-mockPreferencesScenario"),
           arguments.indices.contains(index + 1),
           let scenario = PreferencesServiceMock.MockScenario(rawValue: arguments[index + 1]) {
            flags.useMockPreferences = true
            flags.mockPreferencesScenario = scenario
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
        if arguments.contains("-mockAccount") {
            flags.useMockAccount = true
        }
        if let index = arguments.firstIndex(of: "-mockAccountScenario"),
           arguments.indices.contains(index + 1),
           let scenario = AccountServiceMock.MockScenario(rawValue: arguments[index + 1]) {
            flags.useMockAccount = true
            flags.mockAccountScenario = scenario
        }
        // Same reasoning again: a mocked session's token would 401 against the
        // real `/me/preferences`, and a preferences screen that cannot load is
        // not a demo of anything.
        if flags.useMockAuth && !arguments.contains("-mockPreferencesScenario") {
            flags.useMockPreferences = true
        }
        // And once more for the account surface. It matters a little more here:
        // the mock is the only safe way to walk through deletion and recovery,
        // because the live version of that demo costs a real account.
        if flags.useMockAuth && !arguments.contains("-mockAccountScenario") {
            flags.useMockAccount = true
        }
        if arguments.contains("-mockProfile") {
            flags.useMockProfile = true
        }
        if let index = arguments.firstIndex(of: "-mockProfileScenario"),
           arguments.indices.contains(index + 1),
           let scenario = ProfileServiceMock.MockScenario(rawValue: arguments[index + 1]) {
            flags.useMockProfile = true
            flags.mockProfileScenario = scenario
        }
        // And once more for profiles: a mocked session's token would 401 against
        // the real `/users/{handle}`, and the Profile tab is the route into
        // account settings — a tab that cannot load is not a demo of anything.
        if flags.useMockAuth && !arguments.contains("-mockProfileScenario") {
            flags.useMockProfile = true
        }
        if arguments.contains("-mockSafety") {
            flags.useMockSafety = true
        }
        if let index = arguments.firstIndex(of: "-mockSafetyScenario"),
           arguments.indices.contains(index + 1),
           let scenario = SafetyServiceMock.MockScenario(rawValue: arguments[index + 1]) {
            flags.useMockSafety = true
            flags.mockSafetyScenario = scenario
        }
        // And for safety, with one extra reason of its own: the suspension
        // screen and the self-harm support screen are only otherwise reachable
        // by getting a real account suspended or by filing a real report about
        // somebody in danger. Neither is a demo anybody should have to stage.
        if flags.useMockAuth && !arguments.contains("-mockSafetyScenario") {
            flags.useMockSafety = true
        }
        if arguments.contains("-mockNotifications") {
            flags.useMockNotifications = true
        }
        if let index = arguments.firstIndex(of: "-mockNotificationsScenario"),
           arguments.indices.contains(index + 1),
           let scenario = NotificationsServiceMock.MockScenario(rawValue: arguments[index + 1]) {
            flags.useMockNotifications = true
            flags.mockNotificationsScenario = scenario
        }
        // And for notifications, with the reason that applies to all of them: a
        // mocked session's token would 401 against the real `/notifications`,
        // and a tab that can only show an error is not a demo of anything.
        if flags.useMockAuth && !arguments.contains("-mockNotificationsScenario") {
            flags.useMockNotifications = true
        }
        if arguments.contains("-mockRooms") {
            flags.useMockRooms = true
        }
        if let index = arguments.firstIndex(of: "-mockRoomsScenario"),
           arguments.indices.contains(index + 1),
           let scenario = RoomsServiceMock.MockScenario(rawValue: arguments[index + 1]) {
            flags.useMockRooms = true
            flags.mockRoomsScenario = scenario
        }
        if flags.useMockAuth && !arguments.contains("-mockRoomsScenario") {
            flags.useMockRooms = true
        }
        // A mocked join hands back a token no media server would accept, so a
        // real engine behind a mocked room could only ever fail to connect.
        if flags.useMockRooms {
            flags.useMockVoiceEngine = true
        }
        if arguments.contains("-mockVoiceEngine") {
            flags.useMockVoiceEngine = true
        }
        return flags
    }
}
