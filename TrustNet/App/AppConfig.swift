import Foundation

/// Environment configuration for the whole app.
///
/// The backend host lives here and **only** here. Point the app at a different
/// environment by editing ``AppConfig/apiBaseURLString`` — one line, one place.
public enum AppConfig {

    /// The single source of truth for the backend origin + version prefix.
    public static let apiBaseURLString = "https://portal.gmai.sa/socialsa/api/v1"

    /// ``apiBaseURLString`` parsed as a `URL`.
    ///
    /// The literal above is a compile-time constant we control, but this
    /// deliberately avoids a force-unwrap: if someone mistypes the string the
    /// app falls back to a well-formed placeholder and every request fails
    /// loudly with a transport error instead of trapping at launch.
    public static var apiBaseURL: URL {
        URL(string: apiBaseURLString) ?? URL(fileURLWithPath: "/invalid-api-base-url")
    }

    /// Address used by the "Appeal" mail link on the rejected screen.
    public static let appealEmail = "appeals@socialsa.com"

    /// Terms of Service, opened in a web sheet from registration.
    public static let termsURLString = "https://portal.gmai.sa/socialsa/legal/terms"

    /// Privacy Policy, opened in a web sheet from registration.
    public static let privacyURLString = "https://portal.gmai.sa/socialsa/legal/privacy"

    /// How long the OTP resend button stays disabled when the server does not
    /// tell us otherwise.
    public static let defaultOTPResendSeconds = 60

    /// Number of digits in an OTP code.
    public static let otpLength = 6

    /// Request timeout in seconds.
    public static let requestTimeout: TimeInterval = 30

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
