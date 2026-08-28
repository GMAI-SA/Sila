import Foundation

/// Everything the Auth module can ask the backend to do.
///
/// This is the seam every Auth view model depends on; the real implementation
/// (``AuthService``) and the scripted one (``AuthServiceMock``) are
/// interchangeable, which is what makes the view-model tests honest.
///
/// > Note: The spec's Phase-1 signatures are phone-based. Sila ships
/// > email-first authentication, so every `phone:` parameter here is `email:`
/// > and OTP calls carry an explicit ``OTPPurpose``.
public protocol AuthServiceProtocol: Sendable {

    /// Creates an account and triggers the confirmation email.
    /// - Returns: The new user's id and whether the code was dispatched.
    func register(email: String, password: String) async throws -> RegistrationResult

    /// Sends (or re-sends) a 6-digit code to `email`.
    /// - Returns: Dispatch status and the resend cool-down in seconds.
    func sendOTP(email: String, purpose: OTPPurpose) async throws -> OTPSendResult

    /// Exchanges a code for a session.
    func verifyOTP(email: String, code: String, purpose: OTPPurpose) async throws -> TokenPair

    /// Exchanges credentials for a session.
    /// - Throws: ``APIError`` with ``APIErrorCode/emailUnverified`` when the
    ///   caller must be routed to the OTP screen instead.
    func signIn(email: String, password: String) async throws -> TokenPair

    /// Unlocks the keychain-held session behind a Face ID / Touch ID prompt.
    func signInBiometric() async throws -> TokenPair

    /// Rotates a token pair. The old refresh token is invalid afterwards.
    func refreshToken(_ token: AuthToken) async throws -> TokenPair

    /// Revokes the session server-side and clears every local secret.
    func signOut() async throws

    /// Fetches the signed-in account from `/auth/me`.
    func currentUser() async throws -> AuthUser

    /// Fetches the identity-verification state from `/verification/status`.
    func verificationStatus() async throws -> VerificationStatusReport

    /// The email a biometric credential is stored for, if any.
    ///
    /// Drives whether the sign-in screen offers the Face ID button.
    func biometricEmail() async -> String?

    /// The biometry this device offers, for labelling that button.
    var availableBiometry: BiometryKind { get }
}
