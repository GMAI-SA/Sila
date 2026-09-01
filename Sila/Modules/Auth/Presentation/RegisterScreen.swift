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
                    L10n.t("auth.field.email.label"),
                    text: $viewModel.email,
                    placeholder: L10n.t("auth.field.email.placeholder"),
                    keyboard: .emailAddress,
                    contentType: .username,
                    error: viewModel.emailError,
                    accessibilityHint: L10n.t("auth.register.email.hint"),
                    submitLabel: .next,
                    onSubmit: { focus = .password }
                )
                .focused($focus, equals: .email)

                VStack(alignment: .leading, spacing: SLSpacing.xs) {
                    SLTextField(
                        L10n.t("auth.field.password.label"),
                        text: $viewModel.password,
                        placeholder: L10n.plural("auth.register.password.placeholder", PasswordStrength.minimumLength),
                        isSecure: true,
                        contentType: .newPassword,
                        error: viewModel.passwordError,
                        accessibilityHint: L10n.t("auth.register.password.hint"),
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
                    L10n.t("auth.register.confirmPassword.label"),
                    text: $viewModel.confirmPassword,
                    placeholder: L10n.t("auth.register.confirmPassword.placeholder"),
                    isSecure: true,
                    contentType: .newPassword,
                    error: viewModel.confirmError,
                    accessibilityHint: L10n.t("auth.register.confirmPassword.hint"),
                    submitLabel: .go,
                    onSubmit: { Task { await submit() } }
                )
                .focused($focus, equals: .confirm)

                SLButton(
                    L10n.t("auth.register.submit"),
                    variant: .primary,
                    isLoading: viewModel.isSubmitting,
                    isEnabled: viewModel.canSubmit,
                    accessibilityHint: L10n.t("auth.register.submit.hint")
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
        .tnNavigationBar(title: L10n.t("auth.register.navTitle"))
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
            Text(L10n.t("auth.register.title"))
                .font(SLFont.displayL)
                .foregroundStyle(SLColor.textPrimary)
            Text(L10n.t("auth.register.subtitle"))
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
            Text(L10n.t("auth.register.legalIntro"))
                .font(SLFont.caption)
                .foregroundStyle(SLColor.textMuted)
            HStack(spacing: SLSpacing.md) {
                SLButton(L10n.t("auth.register.terms"), variant: .ghost, size: .compact,
                         accessibilityHint: L10n.t("auth.register.terms.hint")) {
                    router.present(.terms)
                }
                SLButton(L10n.t("auth.register.privacy"), variant: .ghost, size: .compact,
                         accessibilityHint: L10n.t("auth.register.privacy.hint")) {
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
