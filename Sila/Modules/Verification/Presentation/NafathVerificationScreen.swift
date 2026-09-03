import SwiftUI

/// **The Nafath verification flow.**
///
/// The person enters their 10-digit National ID (starts with 1) or Iqama
/// (starts with 2); the backend opens a Nafath request; the response carries a
/// two-digit number they must find and **tap in the Nafath app** — they never
/// type it back here. This screen's whole job while waiting is to show that
/// number large enough to match against the Nafath app at arm's length,
/// because that match *is* the security.
///
/// Presented full-screen from the verification wall. Dismissing it cancels the
/// poll loop; the request simply lapses server-side.
@MainActor
public struct NafathVerificationScreen: View {

    @State private var viewModel: NafathVerificationViewModel
    private let onApproved: () -> Void
    private let onSignInInstead: (() -> Void)?
    private let onClose: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    /// - Parameters:
    ///   - viewModel: Owns the flow's state and the poll loop.
    ///   - onApproved: Called from the approved screen's Continue — the caller
    ///     refreshes the session (verification status *and* country changed)
    ///     and takes the wall down.
    ///   - onSignInInstead: Ends this session so the person can sign in to the
    ///     account their identity already belongs to. `nil` hides the button.
    ///   - onClose: Dismisses the flow without finishing it.
    public init(
        viewModel: NafathVerificationViewModel,
        onApproved: @escaping () -> Void,
        onSignInInstead: (() -> Void)? = nil,
        onClose: @escaping () -> Void
    ) {
        _viewModel = State(initialValue: viewModel)
        self.onApproved = onApproved
        self.onSignInInstead = onSignInInstead
        self.onClose = onClose
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                content
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, SLSpacing.lg)
                    .padding(.vertical, SLSpacing.xl)
            }
            .tnScreenBackground()
            .tnToast($viewModel.toast)
            .navigationTitle(L10n.t("verification.nav.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // No cancel once verified: the only sensible exit is Continue,
                // and offering two doors out of a success screen invites
                // closing the flow without the session refresh it exists for.
                if viewModel.phase != .approved {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(L10n.t("common.cancel"), action: onClose)
                            .foregroundStyle(SLColor.textSecondary)
                            .accessibilityHint(Text(L10n.t("verification.cancel.hint")))
                    }
                }
            }
            // Starts when the phase becomes `waiting`; cancelled by dismissal.
            .task(id: viewModel.phase) {
                if viewModel.phase == .waiting {
                    await viewModel.pollUntilDone()
                }
            }
        }
        .tint(SLColor.primary)
        .interactiveDismissDisabled(viewModel.phase == .approved)
    }

    // MARK: - Phases

    @ViewBuilder
    private var content: some View {
        switch viewModel.phase {
        case .enterID: enterID
        case .waiting: waiting
        case .approved: approved
        case .rejected: rejected
        case .expired: expired
        case .identityUsed: identityUsed
        case .underAge: underAge
        }
    }

    // MARK: Enter ID

    private var enterID: some View {
        VStack(spacing: SLSpacing.xl) {
            hero(icon: "person.badge.shield.checkmark", tint: SLColor.primary)

            VStack(spacing: SLSpacing.sm) {
                Text(L10n.t("verification.enter.title"))
                    .font(SLFont.displayL)
                    .foregroundStyle(SLColor.textPrimary)
                    .multilineTextAlignment(.center)

                Text(L10n.t("verification.enter.message"))
                    .font(SLFont.bodyLight)
                    .foregroundStyle(SLColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SLTextField(
                L10n.t("verification.field.nationalId.label"),
                text: $viewModel.nationalID,
                placeholder: L10n.t("verification.field.nationalId.placeholder"),
                keyboard: .numberPad,
                error: viewModel.idError,
                accessibilityHint: L10n.t("verification.field.nationalId.hint")
            )
            // A number is a number in both languages: the field stays
            // left-to-right even when the interface is Arabic.
            .environment(\.layoutDirection, .leftToRight)

            SLButton(
                L10n.t("verification.start.button"),
                variant: .primary,
                isLoading: viewModel.isSubmitting,
                isEnabled: viewModel.canSubmit || !viewModel.didAttemptSubmit,
                accessibilityHint: L10n.t("verification.start.hint")
            ) {
                Task { await viewModel.submit() }
            }

            Text(L10n.t("verification.enter.privacy"))
                .font(SLFont.caption)
                .foregroundStyle(SLColor.textMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Waiting

    private var waiting: some View {
        VStack(spacing: SLSpacing.xl) {
            VStack(spacing: SLSpacing.sm) {
                Text(L10n.t("verification.waiting.title"))
                    .font(SLFont.displayL)
                    .foregroundStyle(SLColor.textPrimary)
                    .multilineTextAlignment(.center)

                // The load-bearing sentence: the person is matching this
                // number against the Nafath app, and that match is the
                // security.
                Text(L10n.t("verification.waiting.instruction"))
                    .font(SLFont.bodyLight)
                    .foregroundStyle(SLColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // LARGE. Legible from across a desk, next to a phone showing the
            // Nafath app. Digits stay left-to-right in both languages.
            Text(viewModel.randomNumber)
                .font(.system(size: 96, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(SLColor.primary)
                .environment(\.layoutDirection, .leftToRight)
                .padding(.vertical, SLSpacing.lg)
                .padding(.horizontal, SLSpacing.xxl)
                .background(
                    RoundedRectangle(cornerRadius: SLRadius.lg)
                        .fill(SLColor.primary.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: SLRadius.lg)
                        .strokeBorder(SLColor.primary.opacity(pulse ? 0.5 : 0.2), lineWidth: 2)
                )
                .accessibilityLabel(Text(L10n.t("verification.waiting.number.accessibility", viewModel.randomNumber)))
                .onAppear { startPulse() }

            VStack(spacing: SLSpacing.sm) {
                HStack(spacing: SLSpacing.sm) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(SLColor.primary)
                        .accessibilityHidden(true)
                    Text(L10n.t("verification.waiting.status"))
                        .font(SLFont.caption)
                        .foregroundStyle(SLColor.textSecondary)
                }

                if let expiresAt = viewModel.expiresAt {
                    Text(L10n.t("verification.waiting.expires", SLFormat.relative(expiresAt)))
                        .font(SLFont.micro)
                        .foregroundStyle(SLColor.textMuted)
                }
            }
        }
        .padding(.top, SLSpacing.xl)
    }

    // MARK: Terminal states

    private var approved: some View {
        VStack(spacing: SLSpacing.xl) {
            hero(icon: "checkmark.seal.fill", tint: SLColor.secondary)

            VStack(spacing: SLSpacing.sm) {
                Text(L10n.t("verification.approved.title"))
                    .font(SLFont.displayL)
                    .foregroundStyle(SLColor.textPrimary)
                    .multilineTextAlignment(.center)

                Text(L10n.t("verification.approved.message"))
                    .font(SLFont.bodyLight)
                    .foregroundStyle(SLColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SLButton(
                L10n.t("verification.approved.continue"),
                variant: .primary,
                accessibilityHint: L10n.t("verification.approved.continue.hint"),
                action: onApproved
            )
        }
        .padding(.top, SLSpacing.xl)
    }

    private var rejected: some View {
        VStack(spacing: SLSpacing.xl) {
            hero(icon: "xmark.octagon.fill", tint: SLColor.danger)

            VStack(spacing: SLSpacing.sm) {
                Text(L10n.t("verification.rejected.title"))
                    .font(SLFont.displayL)
                    .foregroundStyle(SLColor.textPrimary)
                    .multilineTextAlignment(.center)

                Text(L10n.t("verification.rejected.message"))
                    .font(SLFont.bodyLight)
                    .foregroundStyle(SLColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                if let reason = viewModel.rejectionReason {
                    // The server wrote this; it can arrive in either language
                    // and has to read in its own.
                    Text(reason)
                        .font(SLFont.caption)
                        .foregroundStyle(SLColor.danger)
                        .multilineTextAlignment(.center)
                        .padding(.top, SLSpacing.xs)
                        .environment(
                            \.layoutDirection,
                            TextDirection.resolve(languageCode: nil, text: reason).layoutDirection
                        )
                }
            }

            SLButton(
                L10n.t("verification.tryAgain"),
                variant: .primary,
                accessibilityHint: L10n.t("verification.tryAgain.hint")
            ) {
                viewModel.startAgain()
            }
        }
        .padding(.top, SLSpacing.xl)
    }

    private var expired: some View {
        VStack(spacing: SLSpacing.xl) {
            hero(icon: "clock.badge.xmark", tint: SLColor.warning)

            VStack(spacing: SLSpacing.sm) {
                Text(L10n.t("verification.expired.title"))
                    .font(SLFont.displayL)
                    .foregroundStyle(SLColor.textPrimary)
                    .multilineTextAlignment(.center)

                Text(L10n.t("verification.expired.message"))
                    .font(SLFont.bodyLight)
                    .foregroundStyle(SLColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SLButton(
                L10n.t("verification.tryAgain"),
                variant: .primary,
                accessibilityHint: L10n.t("verification.tryAgain.hint")
            ) {
                viewModel.startAgain()
            }
        }
        .padding(.top, SLSpacing.xl)
    }

    /// Not a failure screen. This identity already *has* an account, and the
    /// door forward is the sign-in form, not another attempt here.
    private var identityUsed: some View {
        VStack(spacing: SLSpacing.xl) {
            hero(icon: "person.crop.circle.badge.checkmark", tint: SLColor.primary)

            VStack(spacing: SLSpacing.sm) {
                Text(L10n.t("verification.identityUsed.title"))
                    .font(SLFont.displayL)
                    .foregroundStyle(SLColor.textPrimary)
                    .multilineTextAlignment(.center)

                Text(L10n.t("verification.identityUsed.message"))
                    .font(SLFont.bodyLight)
                    .foregroundStyle(SLColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let onSignInInstead {
                SLButton(
                    L10n.t("verification.identityUsed.signIn"),
                    variant: .primary,
                    accessibilityHint: L10n.t("verification.identityUsed.signIn.hint"),
                    action: onSignInInstead
                )
            }
        }
        .padding(.top, SLSpacing.xl)
    }

    private var underAge: some View {
        VStack(spacing: SLSpacing.xl) {
            hero(icon: "hand.raised.fill", tint: SLColor.warning)

            VStack(spacing: SLSpacing.sm) {
                Text(L10n.t("verification.underAge.title"))
                    .font(SLFont.displayL)
                    .foregroundStyle(SLColor.textPrimary)
                    .multilineTextAlignment(.center)

                // The server's sentence, verbatim: the age rule is policy, and
                // policy copy comes from the server. There is nothing to retry.
                Text(viewModel.underAgeMessage)
                    .font(SLFont.bodyLight)
                    .foregroundStyle(SLColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .environment(
                        \.layoutDirection,
                        TextDirection.resolve(languageCode: nil, text: viewModel.underAgeMessage).layoutDirection
                    )
            }
        }
        .padding(.top, SLSpacing.xl)
    }

    // MARK: - Pieces

    private func hero(icon: String, tint: Color) -> some View {
        ZStack {
            Circle()
                .fill(tint.opacity(0.12))
                .frame(width: 132, height: 132)

            Image(systemName: icon)
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(tint)
        }
        .accessibilityHidden(true)
    }

    private func startPulse() {
        guard !reduceMotion else { return }
        withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
            pulse = true
        }
    }
}

#Preview("Nafath — approved run") {
    NafathVerificationScreen(
        viewModel: NafathVerificationViewModel(
            service: VerificationServiceMock(scenario: .approved, latency: 0.4),
            analytics: RecordingAnalyticsClient()
        ),
        onApproved: {},
        onSignInInstead: {},
        onClose: {}
    )
    .preferredColorScheme(.dark)
}

#Preview("Nafath — identity already used") {
    NafathVerificationScreen(
        viewModel: NafathVerificationViewModel(
            service: VerificationServiceMock(scenario: .identityAlreadyUsed, latency: 0.4),
            analytics: RecordingAnalyticsClient()
        ),
        onApproved: {},
        onSignInInstead: {},
        onClose: {}
    )
    .preferredColorScheme(.dark)
}
