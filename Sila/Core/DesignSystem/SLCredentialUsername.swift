import SwiftUI

/// The account a password belongs to, for Password AutoFill — invisible.
///
/// iOS saves (or updates) a password in Keychain against a *username*, and it
/// finds that username by looking for a `.username` field on the same screen
/// as the password. Screens that set a password without asking for the
/// address again — reset password, change password — had none, so iOS either
/// saved a password with no account attached or saved nothing, and the
/// "Strong Password" it had just generated was lost. This is Apple's
/// documented remedy: a username field on the password screen, carrying the
/// address, that nobody needs to see or touch.
///
/// It is a real `TextField` (a disabled or hidden one is skipped by AutoFill),
/// one point square and fully transparent, and absent from accessibility.
struct SLCredentialUsername: View {

    let value: String

    var body: some View {
        TextField("", text: .constant(value))
            .textContentType(.username)
            .keyboardType(.emailAddress)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .frame(width: 1, height: 1)
            .opacity(0.01)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
