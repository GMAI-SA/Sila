import SwiftUI

/// "Withdraw and start again", and the step that asks first (contract v25).
///
/// On the wall and on the under-review screen alike. The confirmation is
/// drawn in place rather than as a dialog: nothing is dismissed on the way to
/// the request, so the tap that confirms is the tap that withdraws — a
/// dialog's dismissal clearing state before its action ran is how four
/// deletes here once did nothing.
@MainActor
struct WithdrawSubmissionControl: View {

    @Binding var isConfirming: Bool
    let isWithdrawing: Bool
    let onConfirm: () async -> Void

    var body: some View {
        if isConfirming {
            SLCard(padding: SLSpacing.lg) {
                VStack(alignment: .leading, spacing: SLSpacing.md) {
                    Text(L10n.t("verification.withdraw.confirm.title"))
                        .font(SLFont.bodyEmphasis)
                        .foregroundStyle(SLColor.textPrimary)
                    Text(L10n.t("verification.withdraw.confirm.message"))
                        .font(SLFont.caption)
                        .foregroundStyle(SLColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    SLButton(
                        L10n.t("verification.withdraw.confirm.button"),
                        variant: .destructive,
                        isLoading: isWithdrawing,
                        accessibilityHint: L10n.t("verification.withdraw.confirm.button.hint"),
                        asyncAction: onConfirm
                    )
                    .accessibilityIdentifier("verification.withdraw.confirm")
                    SLButton(
                        L10n.t("verification.withdraw.keep"),
                        variant: .ghost,
                        size: .compact,
                        isEnabled: !isWithdrawing
                    ) {
                        withAnimation { isConfirming = false }
                    }
                    .accessibilityIdentifier("verification.withdraw.keep")
                }
            }
            .transition(.opacity)
        } else {
            SLButton(
                L10n.t("verification.withdraw.action"),
                variant: .secondary,
                icon: "arrow.uturn.backward",
                accessibilityHint: L10n.t("verification.withdraw.action.hint")
            ) {
                withAnimation { isConfirming = true }
            }
            .accessibilityIdentifier("verification.withdraw")
        }
    }
}
