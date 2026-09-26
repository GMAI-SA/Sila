import SwiftUI

/// A vouching action and the step that asks first, drawn in place.
///
/// The same shape as ``WithdrawSubmissionControl``, for the same reason:
/// nothing is dismissed on the way to the request, so the tap that confirms
/// is the tap that acts — a dialog clearing its state before its action ran
/// is how deletes here once did nothing.
@MainActor
struct VouchConfirmControl: View {

    /// What the button and the question say.
    struct Copy {
        let action: String
        var actionIcon: String? = nil
        var actionVariant: SLButton.Variant = .secondary
        let title: String
        let message: String
        let confirm: String
        var confirmVariant: SLButton.Variant = .destructive
        let keep: String
    }

    @Binding var isConfirming: Bool
    let isBusy: Bool
    let copy: Copy
    /// Prefix for the three accessibility identifiers.
    let identifier: String
    let onConfirm: () async -> Void

    var body: some View {
        if isConfirming {
            VStack(alignment: .leading, spacing: SLSpacing.sm) {
                Text(copy.title)
                    .font(SLFont.bodyEmphasis)
                    .foregroundStyle(SLColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(copy.message)
                    .font(SLFont.caption)
                    .foregroundStyle(SLColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                SLButton(copy.confirm, variant: copy.confirmVariant, size: .compact, isLoading: isBusy, asyncAction: onConfirm)
                    .accessibilityIdentifier("\(identifier).confirm")
                SLButton(copy.keep, variant: .ghost, size: .compact, isEnabled: !isBusy) {
                    withAnimation { isConfirming = false }
                }
                .accessibilityIdentifier("\(identifier).keep")
            }
            .padding(SLSpacing.md)
            .background(RoundedRectangle(cornerRadius: SLRadius.md).fill(SLColor.surface2))
            .transition(.opacity)
        } else {
            SLButton(copy.action, variant: copy.actionVariant, size: .compact, icon: copy.actionIcon, isEnabled: !isBusy) {
                withAnimation { isConfirming = true }
            }
            .accessibilityIdentifier(identifier)
        }
    }
}
