import Foundation
import Observation

/// Drives ``ResetPasswordScreen``.
///
/// The password rules are the ones registration uses, from the same
/// ``PasswordStrength``: a password that would be refused when an account is
/// created must not be accepted when one is recovered.
@MainActor
@Observable
public final class ResetPasswordViewModel {

    /// The address the code was sent to. Not editable here — it is the
    /// address that was just proven reachable.
    public let email: String
    /// The six digits from the message.
    public var code = ""
    /// The new password.
    public var password = ""
    /// Typed again, because a password nobody can reproduce is worse than the
    /// one they forgot.
    public var confirmPassword = ""

    public private(set) var didAttemptSubmit = false
    public private(set) var isSubmitting = false
    public private(set) var isResending = false
    public var toast: SLToastMessage?

    private let service: AuthServiceProtocol

    public init(email: String, service: AuthServiceProtocol) {
        self.email = email
        self.service = service
    }

    /// How strong the typed password is, by registration's own measure.
    public var passwordStrength: PasswordStrength { PasswordStrength.evaluate(password) }

    public var codeError: String? {
        guard didAttemptSubmit else { return nil }
        return isCodeShaped ? nil : L10n.t("auth.resetPassword.code.error")
    }

    public var passwordError: String? {
        guard didAttemptSubmit else { return nil }
        if password.isEmpty { return L10n.t("auth.register.error.passwordEmpty") }
        return passwordStrength.isAcceptable ? nil : passwordStrength.advice
    }

    public var confirmError: String? {
        guard didAttemptSubmit else { return nil }
        if confirmPassword.isEmpty { return L10n.t("auth.register.error.confirmEmpty") }
        return confirmPassword == password ? nil : L10n.t("auth.register.error.passwordMismatch")
    }

    /// Whether the button is live.
    public var canSubmit: Bool {
        isCodeShaped
            && passwordStrength.isAcceptable
            && !confirmPassword.isEmpty
            && password == confirmPassword
            && !isSubmitting
    }

    private var isCodeShaped: Bool {
        let digits = code.trimmingCharacters(in: .whitespaces)
        return digits.count >= 4 && digits.allSatisfy(\.isNumber)
    }

    /// Sets the new password.
    /// - Returns: `true` when the server accepted it.
    @discardableResult
    public func submit() async -> Bool {
        didAttemptSubmit = true
        guard canSubmit else { return false }

        isSubmitting = true
        defer { isSubmitting = false }

        do {
            try await service.resetPassword(
                email: email,
                code: code.trimmingCharacters(in: .whitespaces),
                newPassword: password
            )
            return true
        } catch {
            let wrapped = APIError.wrapping(error)
            // A cancelled request changed nothing; saying it failed would be
            // a lie that sends somebody back to a mailbox for a second code.
            guard !wrapped.isCancellation else { return false }
            toast = .error(wrapped.userMessage)
            return false
        }
    }

    /// Asks for another code, for a message that never arrived.
    public func resend() async {
        guard !isResending else { return }
        isResending = true
        defer { isResending = false }
        do {
            _ = try await service.sendOTP(email: email, purpose: .reset)
            toast = .success(L10n.t("auth.otp.resent", email))
        } catch {
            let wrapped = APIError.wrapping(error)
            guard !wrapped.isCancellation else { return }
            toast = .error(wrapped.userMessage)
        }
    }
}
