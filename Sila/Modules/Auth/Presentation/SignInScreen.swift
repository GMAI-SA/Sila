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
                    "Email",
                    text: $viewModel.email,
                    placeholder: "you@example.com",
                    keyboard: .emailAddress,
                    contentType: .username,
                    error: viewModel.emailError,
                    accessibilityHint: "The email address on your Sila account",
                    submitLabel: .next,
                    onSubmit: { focus = .password }
                )
                .focused($focus, equals: .email)

                SLTextField(
                    "Password",
                    text: $viewModel.password,
                    placeholder: "Your password",
                    isSecure: true,
                    contentType: .password,
                    error: viewModel.passwordError,
                    accessibilityHint: "The password for your Sila account",
                    submitLabel: .go,
                    onSubmit: { Task { await submit() } }
                )
                .focused($focus, equals: .password)

                SLButton(
                    "Sign In",
                    variant: .primary,
                    isLoading: viewModel.isSubmitting,
                    isEnabled: viewModel.canSubmit,
                    accessibilityHint: "Signs you in with your email and password"
                ) {
                    Task { await submit() }
                }

                HStack {
                    Spacer()
                    SLButton(
                        "Forgot password?",
                        variant: .ghost,
                        size: .compact,
                        accessibilityHint: "Sends a six digit code so you can reset your password",
                        action: onForgotPassword
                    )
                    .frame(maxWidth: 200)
                    Spacer()
                }

                if viewModel.showsBiometricButton {
                    VStack(spacing: SLSpacing.md) {
                        SLDivider(text: "or")
                        SLButton(
                            viewModel.biometricButtonTitle,
                            variant: .secondary,
                            icon: viewModel.biometry.symbolName,
                            isLoading: viewModel.isAuthenticatingBiometrically,
                            accessibilityHint: "Unlocks your saved Sila session using \(viewModel.biometry.displayName)"
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
        .tnNavigationBar(title: "Sign In")
        .tnToast($viewModel.toast)
        .task { await viewModel.loadBiometricState() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: SLSpacing.sm) {
            Text("Welcome back")
                .font(SLFont.displayL)
                .foregroundStyle(SLColor.textPrimary)
            Text("Sign in to your verified Sila account.")
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
                Text("Reset your password")
                    .font(SLFont.displayL)
                    .foregroundStyle(SLColor.textPrimary)
                Text("We'll email a six-digit code to the address on your account.")
                    .font(SLFont.bodyLight)
                    .foregroundStyle(SLColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)

            SLTextField(
                "Email",
                text: $viewModel.email,
                placeholder: "you@example.com",
                keyboard: .emailAddress,
                contentType: .username,
                error: viewModel.emailError,
                accessibilityHint: "The email address on your Sila account",
                submitLabel: .go,
                onSubmit: { Task { await submit() } }
            )

            SLButton(
                "Send Code",
                variant: .primary,
                isLoading: viewModel.isSubmitting,
                isEnabled: viewModel.canSubmit,
                accessibilityHint: "Emails you a six digit password reset code"
            ) {
                Task { await submit() }
            }

            Spacer()
        }
        .padding(.horizontal, SLSpacing.lg)
        .padding(.top, SLSpacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .tnScreenBackground()
        .tnNavigationBar(title: "Forgot Password")
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
