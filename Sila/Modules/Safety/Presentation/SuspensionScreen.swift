import SwiftUI

/// The screen a suspended account lands on, and the only one it can use.
///
/// Presented as a **root**, like the verification wall and the deletion recovery
/// screen — not pushed, not a sheet. There is no navigation stack to swipe back
/// through, because there is nothing behind it that works.
///
/// It exists because `403 account_suspended` is a *state*, not a failure. The
/// credentials are good and the server is fine. Rendering that as an alert with
/// a Retry button would loop somebody through the same 403 for as long as the
/// suspension lasted, while the one action that can change anything — the appeal
/// — stayed off screen entirely.
///
/// Three things it is careful about:
///
/// * **It does not invent a reason.** When the server attached none it says so,
///   rather than filling the space with a plausible sentence. This is the only
///   account somebody gets of what they are alleged to have done.
/// * **It does not leave a missing date blank.** `until == nil` means indefinite,
///   and it says the word — otherwise somebody waits for an expiry that is never
///   coming.
/// * **It replaces the appeal form with its receipt.** One appeal per
///   suspension, so a form that cannot be sent is not left on screen disabled.
@MainActor
public struct SuspensionScreen: View {

    @Bindable private var viewModel: SuspensionViewModel

    /// - Parameter viewModel: Owns the record and the appeal.
    public init(viewModel: SuspensionViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SLSpacing.xl) {
                header
                reasonCard
                whatIsHappening
                appealSection
                signOut
            }
            .padding(SLSpacing.lg)
            .padding(.top, SLSpacing.lg)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .tnScreenBackground()
        .scrollDismissesKeyboard(.immediately)
        .task { await viewModel.load() }
        .tnToast($viewModel.toast)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: SLSpacing.sm) {
            SLBadge(L10n.t("safety.suspended.badge"), style: .danger, icon: "exclamationmark.octagon.fill")

            Text(SafetyCopy.suspendedTitle)
                .font(SLFont.displayL)
                .foregroundStyle(SLColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Text(viewModel.expiryText)
                .font(SLFont.body)
                .foregroundStyle(
                    viewModel.isIndefinite ? SLColor.warning : SLColor.textPrimary
                )
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Reason

    /// The server's words, rendered verbatim.
    private var reasonCard: some View {
        SLCard {
            VStack(alignment: .leading, spacing: SLSpacing.xs) {
                Text(L10n.t(viewModel.hasServerReason ? "safety.suspended.whyHeader" : "safety.suspended.noReasonHeader"))
                    .font(SLFont.micro)
                    .tracking(0.8)
                    .foregroundStyle(SLColor.textSecondary)

                Text(viewModel.reasonText)
                    .font(SLFont.body)
                    .foregroundStyle(SLColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                if let error = viewModel.loadError {
                    // A transport failure, not a state: this endpoint answers
                    // *because* the account is suspended. Offering to look again
                    // is not a retry loop — it is the one call that works.
                    VStack(alignment: .leading, spacing: SLSpacing.sm) {
                        Text(error)
                            .font(SLFont.caption)
                            .foregroundStyle(SLColor.textMuted)
                            .fixedSize(horizontal: false, vertical: true)

                        SLButton(
                            L10n.t("safety.suspended.checkAgain"),
                            variant: .ghost,
                            size: .compact,
                            isLoading: viewModel.isLoading,
                            accessibilityHint: L10n.t("safety.suspended.checkAgain.hint"),
                            asyncAction: { await viewModel.reload() }
                        )
                        .frame(width: 140)
                    }
                    .padding(.top, SLSpacing.xs)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Scope

    private var whatIsHappening: some View {
        VStack(alignment: .leading, spacing: SLSpacing.sm) {
            Text(L10n.t("safety.suspended.rightNowHeader"))
                .font(SLFont.micro)
                .tracking(0.8)
                .foregroundStyle(SLColor.textSecondary)
                .accessibilityAddTraits(.isHeader)

            Text(SafetyCopy.suspendedScope)
                .font(SLFont.caption)
                .foregroundStyle(SLColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(SLSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SLColor.surface1)
        .clipShape(RoundedRectangle(cornerRadius: SLRadius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: SLRadius.lg)
                .strokeBorder(SLColor.stroke, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }

    // MARK: - Appeal

    @ViewBuilder
    private var appealSection: some View {
        if viewModel.showsAppealForm {
            appealForm
        } else {
            appealReceipt
        }
    }

    private var appealForm: some View {
        VStack(alignment: .leading, spacing: SLSpacing.md) {
            Text(L10n.t("safety.appeal.header"))
                .font(SLFont.micro)
                .tracking(0.8)
                .foregroundStyle(SLColor.textSecondary)
                .accessibilityAddTraits(.isHeader)

            Text(SafetyCopy.appealPrompt)
                .font(SLFont.caption)
                .foregroundStyle(SLColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            SLTextField(
                L10n.t("safety.appeal.field.label"),
                text: $viewModel.appealMessage,
                placeholder: L10n.t("safety.appeal.field.placeholder"),
                autocapitalization: .sentences,
                accessibilityHint: L10n.plural(
                    "safety.appeal.field.hint",
                    SafetyLimits.maximumAppealLength
                )
            )
            // The appeal is the suspended person's own account of what
            // happened, written in whichever language they think in.
            .slContentDirection(
                TextDirection.resolve(languageCode: nil, text: viewModel.appealMessage)
            )

            Text(L10n.plural("safety.appeal.charactersLeft", viewModel.appealRemaining))
                .font(SLFont.micro)
                .foregroundStyle(viewModel.appealRemaining < 0 ? SLColor.danger : SLColor.textMuted)
                .accessibilityLabel(Text(L10n.plural("safety.appeal.charactersLeft", viewModel.appealRemaining)))

            if let error = viewModel.appealError {
                errorBox(error)
            }

            if let blocking = viewModel.appealValidationError, !viewModel.appealMessage.isEmpty {
                Text(blocking)
                    .font(SLFont.caption)
                    .foregroundStyle(SLColor.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SLButton(
                L10n.t("safety.appeal.send"),
                variant: .primary,
                isLoading: viewModel.isSubmittingAppeal,
                isEnabled: viewModel.canSubmitAppeal,
                accessibilityHint: L10n.t("safety.appeal.send.hint"),
                asyncAction: { await viewModel.submitAppeal() }
            )
        }
    }

    private var appealReceipt: some View {
        VStack(alignment: .leading, spacing: SLSpacing.md) {
            SLEmptyState(
                icon: "envelope.badge.shield.half.filled",
                title: L10n.t("safety.appeal.sent.title"),
                subtitle: viewModel.appealReceipt(),
                tint: SLColor.secondary
            )
        }
    }

    // MARK: - Leaving

    private var signOut: some View {
        VStack(alignment: .leading, spacing: SLSpacing.sm) {
            Text(L10n.t("safety.suspended.signOut.note"))
                .font(SLFont.caption)
                .foregroundStyle(SLColor.textMuted)
                .fixedSize(horizontal: false, vertical: true)

            SLButton(
                L10n.t("common.signOut"),
                variant: .ghost,
                size: .compact,
                accessibilityHint: L10n.t("auth.signOut.hint"),
                action: { viewModel.signOut() }
            )
        }
    }
}

#Preview("Suspension — fixed term") {
    SuspensionScreen(
        viewModel: SuspensionViewModel(
            service: SafetyServiceMock(scenario: .suspended),
            analytics: RecordingAnalyticsClient()
        )
    )
    .preferredColorScheme(.dark)
}

#Preview("Suspension — indefinite") {
    SuspensionScreen(
        viewModel: SuspensionViewModel(
            service: SafetyServiceMock(scenario: .suspendedIndefinite),
            analytics: RecordingAnalyticsClient()
        )
    )
    .preferredColorScheme(.dark)
}

#Preview("Suspension — already appealed") {
    SuspensionScreen(
        viewModel: SuspensionViewModel(
            service: SafetyServiceMock(scenario: .suspendedAppealed),
            analytics: RecordingAnalyticsClient()
        )
    )
    .preferredColorScheme(.dark)
}
