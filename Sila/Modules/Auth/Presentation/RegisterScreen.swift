import SwiftUI

/// **Screen 3 — Register.**
///
/// Email, password (with a live ``SLProgressBar`` strength meter) and
/// confirmation. Submitting creates the account and sends the first six-digit
/// code, then hands off to ``OTPVerificationScreen``.
///
/// > Note: The spec specifies a phone number with a country picker and
/// > `PhoneNumberKit`. Sila Phase 1 is **email-first**, so there is no
/// > phone field and no third-party dependency.
@MainActor
public struct RegisterScreen: View {

    @State private var viewModel: RegisterViewModel
    private let router: AppRouter
    private let onRegistered: (String) -> Void

    @FocusState private var focus: Field?

    private enum Field: Hashable { case email, password, confirm }

    /// - Parameters:
    ///   - service: Auth backend.
    ///   - router: Used to present the legal sheets.
    ///   - onRegistered: Called with the normalised email once the code is sent.
    public init(
        service: AuthServiceProtocol,
        router: AppRouter,
        onRegistered: @escaping (String) -> Void
    ) {
        _viewModel = State(initialValue: RegisterViewModel(service: service))
        self.router = router
        self.onRegistered = onRegistered
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
                    accessibilityHint: "The address we will send your six digit confirmation code to",
                    submitLabel: .next,
                    onSubmit: { focus = .password }
                )
                .focused($focus, equals: .email)

                VStack(alignment: .leading, spacing: SLSpacing.xs) {
                    SLTextField(
                        "Password",
                        text: $viewModel.password,
                        placeholder: "At least \(PasswordStrength.minimumLength) characters",
                        isSecure: true,
                        contentType: .newPassword,
                        error: viewModel.passwordError,
                        accessibilityHint: "Choose a password with at least eight characters",
                        submitLabel: .next,
                        onSubmit: { focus = .confirm }
                    )
                    .focused($focus, equals: .password)

                    if viewModel.showsStrengthMeter {
                        SLProgressBar(
                            value: viewModel.passwordStrength.fraction,
                            tint: viewModel.passwordStrength.color,
                            label: viewModel.passwordStrength.title
                        )
                        .padding(.bottom, SLSpacing.xs)
                        .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: viewModel.showsStrengthMeter)

                SLTextField(
                    "Confirm password",
                    text: $viewModel.confirmPassword,
                    placeholder: "Type it again",
                    isSecure: true,
                    contentType: .newPassword,
                    error: viewModel.confirmError,
                    accessibilityHint: "Re-enter the same password to confirm it",
                    submitLabel: .go,
                    onSubmit: { Task { await submit() } }
                )
                .focused($focus, equals: .confirm)

                SLButton(
                    "Send Code",
                    variant: .primary,
                    isLoading: viewModel.isSubmitting,
                    isEnabled: viewModel.canSubmit,
                    accessibilityHint: "Creates your account and emails you a six digit code"
                ) {
                    Task { await submit() }
                }
                .padding(.top, SLSpacing.xs)

                legalFinePrint

                Spacer(minLength: SLSpacing.xxl)
            }
            .padding(.horizontal, SLSpacing.lg)
            .padding(.top, SLSpacing.lg)
        }
        .scrollDismissesKeyboard(.interactively)
        .tnScreenBackground()
        .tnNavigationBar(title: "Create Account")
        .tnToast($viewModel.toast)
        .sheet(item: Binding(
            get: { router.presentedLegalDocument },
            set: { router.presentedLegalDocument = $0 }
        )) { document in
            LegalDocumentSheet(document: document) {
                router.presentedLegalDocument = nil
            }
        }
        .onAppear { focus = .email }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: SLSpacing.sm) {
            Text("Create your account")
                .font(SLFont.displayL)
                .foregroundStyle(SLColor.textPrimary)
            Text("We'll email you a six-digit code to confirm the address. Identity verification comes next.")
                .font(SLFont.bodyLight)
                .foregroundStyle(SLColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .padding(.bottom, SLSpacing.xs)
    }

    private var legalFinePrint: some View {
        VStack(alignment: .leading, spacing: SLSpacing.sm) {
            SLDivider()
            Text("By continuing you agree to our")
                .font(SLFont.caption)
                .foregroundStyle(SLColor.textMuted)
            HStack(spacing: SLSpacing.md) {
                SLButton("Terms of Service", variant: .ghost, size: .compact,
                         accessibilityHint: "Opens the Terms of Service") {
                    router.present(.terms)
                }
                SLButton("Privacy Policy", variant: .ghost, size: .compact,
                         accessibilityHint: "Opens the Privacy Policy") {
                    router.present(.privacy)
                }
            }
        }
    }

    private func submit() async {
        focus = nil
        await viewModel.submit()
        if let email = viewModel.consumeRegisteredEmail() {
            onRegistered(email)
        }
    }
}

#Preview("RegisterScreen") {
    let container = AppContainer.preview()
    return NavigationStack {
        RegisterScreen(
            service: container.authService,
            router: container.router,
            onRegistered: { _ in }
        )
    }
}
