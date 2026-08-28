import Foundation
import Observation

/// Drives ``SignInScreen``.
///
/// Three outcomes matter, and each is expressed as a distinct piece of state
/// rather than a navigation side effect:
/// * a ``TokenPair`` → the session is adopted and ``AuthSession`` routes;
/// * ``needsEmailVerification`` → the server said `email_unverified`, so the
///   OTP screen replaces this one;
/// * an inline error / toast → stay put.
@MainActor
@Observable
public final class SignInViewModel {

    // MARK: Inputs

    /// The email being signed in.
    public var email: String
    /// The entered password. Held only for the duration of the call.
    public var password = ""

    // MARK: Outputs

    /// `true` once Sign In has been pressed at least once.
    public private(set) var didAttemptSubmit = false
    /// `true` while `/auth/login` is in flight.
    public private(set) var isSubmitting = false
    /// `true` while the biometric prompt / refresh is in flight.
    public private(set) var isAuthenticatingBiometrically = false
    /// Banner message.
    public var toast: TNToastMessage?
    /// Set on success.
    public private(set) var signedInPair: TokenPair?
    /// Set when the server demands email confirmation first.
    public private(set) var needsEmailVerification: String?
    /// The email a saved biometric credential belongs to, once probed.
    public private(set) var biometricEmail: String?

    private let service: AuthServiceProtocol
    private let biometricsEnabled: Bool

    /// - Parameters:
    ///   - service: Auth backend.
    ///   - prefilledEmail: Last signed-in address, if any.
    ///   - biometricsEnabled: ``FeatureFlags/biometricSignIn``.
    public init(
        service: AuthServiceProtocol,
        prefilledEmail: String = "",
        biometricsEnabled: Bool = true
    ) {
        self.service = service
        self.email = prefilledEmail
        self.biometricsEnabled = biometricsEnabled
    }

    // MARK: Derived state

    /// Inline error under the email field.
    public var emailError: String? {
        guard didAttemptSubmit else { return nil }
        return EmailValidator.isValid(email) ? nil : "Enter a valid email address."
    }

    /// Inline error under the password field.
    public var passwordError: String? {
        guard didAttemptSubmit else { return nil }
        return password.isEmpty ? "Enter your password." : nil
    }

    /// Whether the Sign In button is tappable.
    public var canSubmit: Bool {
        EmailValidator.isValid(email) && !password.isEmpty && !isSubmitting
    }

    /// The biometry this device offers.
    public var biometry: BiometryKind { service.availableBiometry }

    /// Whether to show the Face ID / Touch ID button.
    public var showsBiometricButton: Bool {
        biometricsEnabled && biometry != .none && biometricEmail != nil
    }

    /// Label for that button, e.g. "Sign in with Face ID".
    public var biometricButtonTitle: String { "Sign in with \(biometry.displayName)" }

    // MARK: Actions

    /// Probes the keychain for a saved biometric credential. Call on appear.
    public func loadBiometricState() async {
        guard biometricsEnabled else { return }
        biometricEmail = await service.biometricEmail()
        if email.isEmpty, let biometricEmail {
            email = biometricEmail
        }
    }

    /// Signs in with email + password.
    public func submit() async {
        didAttemptSubmit = true
        guard EmailValidator.isValid(email), !password.isEmpty else { return }
        guard !isSubmitting else { return }

        isSubmitting = true
        defer { isSubmitting = false }

        let normalised = EmailValidator.normalise(email)

        do {
            let pair = try await service.signIn(email: normalised, password: password)
            password = ""
            signedInPair = pair
        } catch let error as APIError {
            password = ""
            if error.code == .emailUnverified {
                // Credentials were fine — the address just isn't confirmed.
                _ = try? await service.sendOTP(email: normalised, purpose: .login)
                needsEmailVerification = normalised
                return
            }
            toast = .error(error.userMessage)
        } catch {
            password = ""
            toast = .error("Something went wrong. Please try again.")
        }
    }

    /// Unlocks the stored session behind a biometric prompt.
    public func signInWithBiometrics() async {
        guard showsBiometricButton, !isAuthenticatingBiometrically else { return }
        isAuthenticatingBiometrically = true
        defer { isAuthenticatingBiometrically = false }

        do {
            signedInPair = try await service.signInBiometric()
        } catch let error as APIError {
            toast = .error(error.userMessage)
        } catch {
            toast = .error("\(biometry.displayName) sign-in didn't work. Use your password.")
        }
    }

    /// Consumes ``signedInPair`` so the screen only routes once.
    public func consumeSignedInPair() -> TokenPair? {
        defer { signedInPair = nil }
        return signedInPair
    }

    /// Consumes ``needsEmailVerification`` so the screen only routes once.
    public func consumeNeedsEmailVerification() -> String? {
        defer { needsEmailVerification = nil }
        return needsEmailVerification
    }
}

/// Drives the "forgot password" step: collect an address, send a reset OTP.
///
/// Phase 1 stops at the OTP; setting the new password belongs to the
/// account-settings work in Phase 7.
@MainActor
@Observable
public final class ForgotPasswordViewModel {

    /// The address to send the reset code to.
    public var email: String
    /// `true` once Send has been pressed.
    public private(set) var didAttemptSubmit = false
    /// `true` while the request is in flight.
    public private(set) var isSubmitting = false
    /// Banner message.
    public var toast: TNToastMessage?
    /// Set when the code has been sent.
    public private(set) var sentToEmail: String?

    private let service: AuthServiceProtocol

    public init(service: AuthServiceProtocol, prefilledEmail: String = "") {
        self.service = service
        self.email = prefilledEmail
    }

    /// Inline error under the email field.
    public var emailError: String? {
        guard didAttemptSubmit else { return nil }
        return EmailValidator.isValid(email) ? nil : "Enter a valid email address."
    }

    /// Whether Send is tappable.
    public var canSubmit: Bool { EmailValidator.isValid(email) && !isSubmitting }

    /// Requests a `reset`-purpose OTP.
    public func submit() async {
        didAttemptSubmit = true
        guard EmailValidator.isValid(email), !isSubmitting else { return }

        isSubmitting = true
        defer { isSubmitting = false }

        let normalised = EmailValidator.normalise(email)
        do {
            _ = try await service.sendOTP(email: normalised, purpose: .reset)
            sentToEmail = normalised
        } catch let error as APIError {
            toast = .error(error.userMessage)
        } catch {
            toast = .error("We couldn't send a reset code. Please try again.")
        }
    }

    /// Consumes ``sentToEmail`` so the screen only routes once.
    public func consumeSentToEmail() -> String? {
        defer { sentToEmail = nil }
        return sentToEmail
    }
}
