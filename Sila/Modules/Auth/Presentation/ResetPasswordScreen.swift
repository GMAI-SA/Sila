import SwiftUI

/// Choosing a new password with the code that was just mailed.
///
/// This screen did not exist. The code went to `/auth/otp/verify`, which
/// refuses a reset code on purpose — that route mints a session, and a code
/// sent to an address somebody may have lost control of must not be a way in
/// by itself. So the flow ended on an error nobody could act on, and a
/// forgotten password could not be changed from the app at all.
///
/// The code buys exactly one thing: the right to choose a new password. Every
/// existing session is revoked when one is chosen, which is the point — if
/// somebody else was in the account, this is what puts them out.
@MainActor
public struct ResetPasswordScreen: View {

    @Bindable private var viewModel: ResetPasswordViewModel
    private let onDone: (String) -> Void
    @FocusState private var focus: Field?

    private enum Field { case code, password, confirm }

    /// - Parameters:
    ///   - email: The address the code went to.
    ///   - service: Auth backend.
    ///   - onDone: Called with the address once the password is changed, so
    ///     the caller can return to sign-in with it already filled in.
    public init(
        email: String,
        service: AuthServiceProtocol,
        onDone: @escaping (String) -> Void
    ) {
        self.viewModel = ResetPasswordViewModel(email: email, service: service)
        self.onDone = onDone
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SLSpacing.lg) {
                VStack(alignment: .leading, spacing: SLSpacing.sm) {
                    Text(L10n.t("auth.resetPassword.title"))
                        .font(SLFont.displayL)
                        .foregroundStyle(SLColor.textPrimary)
                    Text(L10n.t("auth.resetPassword.subtitle", viewModel.email))
                        .font(SLFont.bodyLight)
                        .foregroundStyle(SLColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)

                SLTextField(
                    L10n.t("auth.resetPassword.code.label"),
                    text: $viewModel.code,
                    placeholder: L10n.t("auth.resetPassword.code.placeholder"),
                    keyboard: .numberPad,
                    contentType: .oneTimeCode,
                    error: viewModel.codeError,
                    accessibilityHint: L10n.t("auth.resetPassword.code.hint")
                )
                .focused($focus, equals: .code)
                .accessibilityIdentifier("auth.reset.code")

                SLTextField(
                    L10n.t("auth.resetPassword.newPassword.label"),
                    text: $viewModel.password,
                    placeholder: L10n.t("auth.register.confirmPassword.placeholder"),
                    isSecure: true,
                    contentType: .newPassword,
                    error: viewModel.passwordError
                )
                .focused($focus, equals: .password)
                .accessibilityIdentifier("auth.reset.password")

                SLTextField(
                    L10n.t("auth.register.confirmPassword.label"),
                    text: $viewModel.confirmPassword,
                    placeholder: L10n.t("auth.register.confirmPassword.placeholder"),
                    isSecure: true,
                    contentType: .newPassword,
                    error: viewModel.confirmError
                )
                .focused($focus, equals: .confirm)
                .accessibilityIdentifier("auth.reset.confirm")

                // What happens to the sessions, said before it happens.
                Text(L10n.t("auth.resetPassword.signsOutEverywhere"))
                    .font(SLFont.caption)
                    .foregroundStyle(SLColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                SLButton(
                    L10n.t("auth.resetPassword.submit"),
                    isLoading: viewModel.isSubmitting,
                    isEnabled: viewModel.canSubmit,
                    accessibilityHint: L10n.t("auth.resetPassword.submit.a11yHint"),
                    asyncAction: {
                        if await viewModel.submit() { onDone(viewModel.email) }
                    }
                )
                .accessibilityIdentifier("auth.reset.submit")

                Button(L10n.t("auth.otp.resend")) {
                    Task { await viewModel.resend() }
                }
                .font(SLFont.caption)
                .foregroundStyle(SLColor.primary)
                .disabled(viewModel.isResending)
            }
            .padding(SLSpacing.lg)
        }
        .tnScreenBackground()
        .tnNavigationBar(title: L10n.t("auth.resetPassword.navTitle"))
        .tnToast($viewModel.toast)
        .onAppear { focus = .code }
    }
}

#Preview("Reset password") {
    NavigationStack {
        ResetPasswordScreen(
            email: "aziz@example.com",
            service: AuthServiceMock(),
            onDone: { _ in }
        )
    }
    .preferredColorScheme(.dark)
}
