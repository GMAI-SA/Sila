import Foundation
import Observation

/// Drives ``RegisterScreen``.
///
/// Owns field state, inline validation and the `POST /auth/register` call.
/// Nothing about presentation lives here beyond a toast message, which keeps
/// the whole type testable without a view.
///
/// Inline errors stay silent until the first submit attempt, then become live
/// on every keystroke — the standard "don't shout at someone who is still
/// typing" rule.
@MainActor
@Observable
public final class RegisterViewModel {

    // MARK: Inputs

    /// The email being registered.
    public var email = ""
    /// The chosen password.
    public var password = ""
    /// Confirmation of ``password``.
    public var confirmPassword = ""

    // MARK: Outputs

    /// `true` once the user has pressed Send Code at least once.
    public private(set) var didAttemptSubmit = false
    /// `true` while `/auth/register` is in flight.
    public private(set) var isSubmitting = false
    /// Banner message for API-level failures.
    public var toast: TNToastMessage?
    /// Set when registration succeeds; the screen navigates to OTP entry.
    public private(set) var registeredEmail: String?
    /// Field-level error handed back by the server (e.g. `email_taken`).
    public private(set) var serverEmailError: String?

    private let service: AuthServiceProtocol

    public init(service: AuthServiceProtocol) {
        self.service = service
    }

    // MARK: Derived state

    /// Live strength of ``password``.
    public var passwordStrength: PasswordStrength {
        PasswordStrength.evaluate(password)
    }

    /// Whether the strength meter should be visible at all.
    public var showsStrengthMeter: Bool { !password.isEmpty }

    /// Inline error under the email field.
    public var emailError: String? {
        if let serverEmailError { return serverEmailError }
        guard didAttemptSubmit else { return nil }
        return EmailValidator.isValid(email) ? nil : "Enter a valid email address."
    }

    /// Inline error under the password field.
    public var passwordError: String? {
        guard didAttemptSubmit else { return nil }
        if password.isEmpty { return "Choose a password." }
        return passwordStrength.isAcceptable ? nil : passwordStrength.advice
    }

    /// Inline error under the confirmation field.
    public var confirmError: String? {
        guard didAttemptSubmit else { return nil }
        if confirmPassword.isEmpty { return "Re-enter your password." }
        return confirmPassword == password ? nil : "Passwords don't match."
    }

    /// Whether every field currently passes validation.
    public var canSubmit: Bool {
        EmailValidator.isValid(email)
            && passwordStrength.isAcceptable
            && !confirmPassword.isEmpty
            && password == confirmPassword
            && !isSubmitting
    }

    /// `true` when nothing is blocking a submit attempt.
    var isValid: Bool {
        EmailValidator.isValid(email)
            && passwordStrength.isAcceptable
            && !confirmPassword.isEmpty
            && password == confirmPassword
    }

    // MARK: Actions

    /// Validates, then registers the account and requests the first OTP.
    ///
    /// On success ``registeredEmail`` is set and the screen pushes the OTP
    /// route; the password is cleared immediately and never persisted.
    public func submit() async {
        didAttemptSubmit = true
        serverEmailError = nil
        guard isValid else { return }
        guard !isSubmitting else { return }

        isSubmitting = true
        defer { isSubmitting = false }

        let normalised = EmailValidator.normalise(email)

        do {
            let result = try await service.register(email: normalised, password: password)
            if !result.otpSent {
                // The account exists but the email never went out — ask again
                // rather than stranding the user on an empty OTP screen.
                _ = try await service.sendOTP(email: normalised, purpose: .register)
            }
            password = ""
            confirmPassword = ""
            registeredEmail = normalised
        } catch let error as APIError {
            handle(error)
        } catch {
            toast = .error("Something went wrong. Please try again.")
        }
    }

    /// Consumes ``registeredEmail`` so the screen only navigates once.
    public func consumeRegisteredEmail() -> String? {
        defer { registeredEmail = nil }
        return registeredEmail
    }

    private func handle(_ error: APIError) {
        if error.code == .emailTaken {
            serverEmailError = "That email already has a TrustNet account."
        }
        toast = .error(error.userMessage)
    }
}
