import Foundation

/// Environment configuration for the whole app.
///
/// The backend host lives here and **only** here. Point the app at a different
/// environment by editing ``AppConfig/apiBaseURLString`` — one line, one place.
public enum AppConfig {

    /// The single source of truth for the backend origin + version prefix.
    public static let apiBaseURLString = "https://sila.gmai.sa/api/v1"
    /// The web client. Permalinks a share carries point here, and links here
    /// open the app when it is installed (universal links).
    public static let webBaseURLString = "https://sila.gmai.sa"

    /// ``apiBaseURLString`` parsed as a `URL`.
    ///
    /// The literal above is a compile-time constant we control, but this
    /// deliberately avoids a force-unwrap: if someone mistypes the string the
    /// app falls back to a well-formed placeholder and every request fails
    /// loudly with a transport error instead of trapping at launch.
    ///
    /// A **debug** build launched with `-apiOrigin <origin>` talks to the API
    /// at that origin instead — the staging API through an SSH tunnel, which
    /// is where the live UI journey signs in. See ``apiBaseURL(arguments:)``.
    public static var apiBaseURL: URL { resolvedAPIBaseURL }

    private static let resolvedAPIBaseURL = apiBaseURL(arguments: ProcessInfo.processInfo.arguments)

    /// The API base for a launch with these arguments.
    ///
    /// `-apiOrigin` is read by debug builds only; a release build — TestFlight
    /// and the store — always talks to ``apiBaseURLString``. An origin that
    /// ``apiBaseURL(origin:)`` refuses does not fall back to production: every
    /// request fails instead, so a mistyped tunnel address can never quietly
    /// send a test to real accounts.
    static func apiBaseURL(arguments: [String]) -> URL {
        #if DEBUG
        if let index = arguments.firstIndex(of: "-apiOrigin") {
            guard arguments.indices.contains(index + 1),
                  let url = apiBaseURL(origin: arguments[index + 1]) else {
                return invalidAPIBaseURL
            }
            return url
        }
        #endif
        return URL(string: apiBaseURLString) ?? invalidAPIBaseURL
    }

    /// `http://127.0.0.1:8101` → `http://127.0.0.1:8101/api/v1`.
    ///
    /// HTTPS to any host, or plain HTTP to this machine's own loopback only —
    /// where an SSH tunnel ends — and a bare origin, with no path or query.
    /// Anything else is `nil`.
    static func apiBaseURL(origin raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/" else {
            return nil
        }
        let loopback = host == "127.0.0.1" || host == "localhost" || host == "::1"
        guard scheme == "https" || (scheme == "http" && loopback) else { return nil }
        components.scheme = scheme
        components.path = "/api/v1"
        return components.url
    }

    private static let invalidAPIBaseURL = URL(fileURLWithPath: "/invalid-api-base-url")

    /// The API's origin — scheme and host, with no path.
    ///
    /// Media paths come back **root-relative** (`/api/v1/media/avatars/…`), so
    /// they must be resolved against this rather than against
    /// ``apiBaseURL``, whose `/api/v1` suffix the path already carries.
    public static var originURL: URL {
        guard var components = URLComponents(url: apiBaseURL, resolvingAgainstBaseURL: false) else {
            return apiBaseURL
        }
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url ?? apiBaseURL
    }

    /// Turns a path the API handed back into something loadable.
    ///
    /// - Parameter path: A value such as `/api/v1/media/avatars/x.jpg`, an
    ///   absolute URL, or `nil`.
    /// - Returns: An absolute `URL`, or `nil` when there is nothing to load.
    ///   Absolute inputs are passed through untouched, so the day the backend
    ///   moves avatars to a CDN nothing here has to change.
    public static func mediaURL(_ path: String?) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        if let absolute = URL(string: path), absolute.scheme != nil { return absolute }
        return URL(string: path, relativeTo: originURL)?.absoluteURL
    }


    /// Terms of Service, opened in a web sheet from registration.
    public static let termsURLString = "https://sila.gmai.sa/legal/terms"

    /// Privacy Policy, opened in a web sheet from registration.
    public static let privacyURLString = "https://sila.gmai.sa/legal/privacy"

    /// How long the OTP resend button stays disabled when the server does not
    /// tell us otherwise.
    public static let defaultOTPResendSeconds = 60

    /// Number of digits in an OTP code.
    public static let otpLength = 6

    /// Request timeout in seconds.
    public static let requestTimeout: TimeInterval = 30
    /// How long a request may wait for the network to come back before it is
    /// given up as offline. Long enough to cover a lift or a network handoff,
    /// short enough that a genuinely offline phone is told so.
    public static let connectivityWait: TimeInterval = 45
    /// How long a cold launch with a stored session waits for the server
    /// before opening on the account cached on this device. The check goes
    /// on in the background; see ``AuthSession/restore()``.
    public static let launchDeadline: TimeInterval = 3
    /// How long each of sign-out's calls to the server — withdrawing this
    /// phone's push registration, then `/auth/logout` — waits for an answer
    /// before it is abandoned. The phone signs out whatever the server says;
    /// see ``AuthService/signOut()``.
    public static let signOutDeadline: TimeInterval = 3

    /// `true` when the process was launched by the unit-test runner.
    ///
    /// Unit tests are hosted *inside* the app, so without this check the real
    /// UI — including the welcome screen's display-link-driven dot grid — keeps
    /// rendering for the whole test run and starves the main actor that the
    /// `@MainActor` tests need. The host renders nothing instead.
    public static var isRunningUnitTests: Bool {
        NSClassFromString("XCTestCase") != nil
    }
}
