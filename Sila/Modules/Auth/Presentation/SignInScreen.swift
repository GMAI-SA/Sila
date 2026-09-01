import SwiftUI

/// **Screen 5 — Sign in.**
///
/// Email + password, plus a biometric shortcut when a credential is already
/// stored on the device. Routing after success is not decided here — the
/// issued ``TokenPair`` is handed to ``AuthSession``, which maps
/// `verificationStatus` onto the feed, the wall, or the rejected screen.
///
/// > Note: The spec specifies phone + password. Sila Phase 1 is
/// > email-first.
@MainActor
public struct SignInScreen: View {

    @State private var viewModel: SignInViewModel
    private let onSignedIn: (TokenPair) -> Void
    private let onNeedsEmailVerification: (String) -> Void
    private let onForgotPassword: () -> Void

    @FocusState private var focus: Field?

    private enum Field: Hashable { case email, password }

    /// - Parameters:
    ///   - service: Auth backend.
    ///   - prefilledEmail: Last signed-in address.
    ///   - biometricsEnabled: ``FeatureFlags/biometricSignIn``.
    ///   - onSignedIn: Called with the issued session.
    ///   - onNeedsEmailVerification: Called when the server demands OTP first.
    ///   - onForgotPassword: Pushes the reset flow.
    public init(
        service: AuthServiceProtocol,
        prefilledEmail: String = "",
        biometricsEnabled: Bool = true,
        onSignedIn: @escaping (TokenPair) -> Void,
        onNeedsEmailVerification: @escaping (String) -> Void,
        onForgotPassword: @escaping () -> Void
    ) {
        _viewModel = State(initialValue: SignInViewModel(
            service: service,
            prefilledEmail: prefilledEmail,
            biometricsEnabled: biometricsEnabled
        ))
        self.onSignedIn = onSignedIn
        self.onNeedsEmailVerification = onNeedsEmailVerification
        self.onForgotPassword = onForgotPassword
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SLSpacing.lg) {
                header

                SLTextField(
                    L10n.t("auth.field.email.label"),
                    text: $viewModel.email,
                    placeholder: L10n.t("auth.field.email.placeholder"),
                    keyboard: .emailAddress,
                    contentType: .username,
                    error: viewModel.emailError,
                    accessibilityHint: L10n.t("auth.field.email.accountHint"),
                    submitLabel: .next,
                    onSubmit: { focus = .password }
                )
                .focused($focus, equals: .email)

                SLTextField(
                    L10n.t("auth.field.password.label"),
                    text: $viewModel.password,
                    placeholder: L10n.t("auth.signIn.password.placeholder"),
                    isSecure: true,
                    contentType: .password,
                    error: viewModel.passwordError,
                    accessibilityHint: L10n.t("auth.signIn.password.hint"),
                    submitLabel: .go,
                    onSubmit: { Task { await submit() } }
                )
                .focused($focus, equals: .password)

                SLButton(
                    L10n.t("auth.signIn.submit"),
                    variant: .primary,
                    isLoading: viewModel.isSubmitting,
                    isEnabled: viewModel.canSubmit,
                    accessibilityHint: L10n.t("auth.signIn.submit.hint")
                ) {
                    Task { await submit() }
                }
                .accessibilityIdentifier("signIn.submit")

                HStack {
                    Spacer()
                    SLButton(
                        L10n.t("auth.signIn.forgotPassword"),
                        variant: .ghost,
                        size: .compact,
                        accessibilityHint: L10n.t("auth.signIn.forgotPassword.hint"),
                        action: onForgotPassword
                    )
                    .frame(maxWidth: 200)
                    Spacer()
                }

                if viewModel.showsBiometricButton {
                    VStack(spacing: SLSpacing.md) {
                        SLDivider(text: L10n.t("auth.signIn.divider.or"))
                        SLButton(
                            viewModel.biometricButtonTitle,
                            variant: .secondary,
                            icon: viewModel.biometry.symbolName,
                            isLoading: viewModel.isAuthenticatingBiometrically,
                            accessibilityHint: L10n.t("auth.signIn.biometric.hint", viewModel.biometry.displayName)
                        ) {
                            Task { await biometricSignIn() }
                        }
                    }
                    .transition(.opacity)
                }

                Spacer(minLength: SLSpacing.xxl)
            }
            .padding(.horizontal, SLSpacing.lg)
            .padding(.top, SLSpacing.lg)
        }
        .scrollDismissesKeyboard(.interactively)
        .animation(.easeInOut(duration: 0.2), value: viewModel.showsBiometricButton)
        .tnScreenBackground()
        .tnNavigationBar(title: L10n.t("auth.signIn.navTitle"))
        .tnToast($viewModel.toast)
        .task { await viewModel.loadBiometricState() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: SLSpacing.sm) {
            Text(L10n.t("auth.signIn.title"))
                .font(SLFont.displayL)
                .foregroundStyle(SLColor.textPrimary)
            Text(L10n.t("auth.signIn.subtitle"))
                .font(SLFont.bodyLight)
                .foregroundStyle(SLColor.textSecondary)
        }
        .accessibilityElement(children: .combine)
        .padding(.bottom, SLSpacing.xs)
    }

    private func submit() async {
        focus = nil
        await viewModel.submit()
        route()
    }

    private func biometricSignIn() async {
        focus = nil
        await viewModel.signInWithBiometrics()
        route()
    }

    private func route() {
        if let pair = viewModel.consumeSignedInPair() {
            onSignedIn(pair)
            return
        }
        if let email = viewModel.consumeNeedsEmailVerification() {
            onNeedsEmailVerification(email)
        }
    }
}

/// The forgotten-password step: collect an address and send a reset code.
@MainActor
public struct ForgotPasswordScreen: View {

    @State private var viewModel: ForgotPasswordViewModel
    private let onCodeSent: (String) -> Void

    /// - Parameters:
    ///   - service: Auth backend.
    ///   - prefilledEmail: Whatever was typed on the sign-in screen.
    ///   - onCodeSent: Pushes the OTP screen with `purpose: .reset`.
    public init(
        service: AuthServiceProtocol,
        prefilledEmail: String = "",
        onCodeSent: @escaping (String) -> Void
    ) {
        _viewModel = State(initialValue: ForgotPasswordViewModel(
            service: service,
            prefilledEmail: prefilledEmail
        ))
        self.onCodeSent = onCodeSent
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: SLSpacing.lg) {
            VStack(alignment: .leading, spacing: SLSpacing.sm) {
                Text(L10n.t("auth.forgotPassword.title"))
                    .font(SLFont.displayL)
                    .foregroundStyle(SLColor.textPrimary)
                Text(L10n.t("auth.forgotPassword.subtitle"))
                    .font(SLFont.bodyLight)
                    .foregroundStyle(SLColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)

            SLTextField(
                L10n.t("auth.field.email.label"),
                text: $viewModel.email,
                placeholder: L10n.t("auth.field.email.placeholder"),
                keyboard: .emailAddress,
                contentType: .username,
                error: viewModel.emailError,
                accessibilityHint: L10n.t("auth.field.email.accountHint"),
                submitLabel: .go,
                onSubmit: { Task { await submit() } }
            )

            SLButton(
                L10n.t("auth.forgotPassword.submit"),
                variant: .primary,
                isLoading: viewModel.isSubmitting,
                isEnabled: viewModel.canSubmit,
                accessibilityHint: L10n.t("auth.forgotPassword.submit.hint")
            ) {
                Task { await submit() }
            }

            Spacer()
        }
        .padding(.horizontal, SLSpacing.lg)
        .padding(.top, SLSpacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .tnScreenBackground()
        .tnNavigationBar(title: L10n.t("auth.forgotPassword.navTitle"))
        .tnToast($viewModel.toast)
    }

    private func submit() async {
        await viewModel.submit()
        if let email = viewModel.consumeSentToEmail() {
            onCodeSent(email)
        }
    }
}

#Preview("SignInScreen") {
    let container = AppContainer.preview()
    return NavigationStack {
        SignInScreen(
            service: container.authService,
            onSignedIn: { _ in },
            onNeedsEmailVerification: { _ in },
            onForgotPassword: {}
        )
    }
}

#Preview("ForgotPasswordScreen") {
    let container = AppContainer.preview()
    return NavigationStack {
        ForgotPasswordScreen(service: container.authService, onCodeSent: { _ in })
    }
}
