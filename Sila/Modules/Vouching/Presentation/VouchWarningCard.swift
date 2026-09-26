import SwiftUI

/// Two plain warnings before a side of a vouch commits (contract v24 §12).
///
/// The owner's words, in simple language, shown every time: to the voucher
/// before the details form, and to the person before theirs. A card drawn in
/// place rather than a system dialog — nothing is dismissed on the way to
/// the next step, so "I understand" is the tap that moves on — and small
/// enough that both warnings are on screen together on a phone.
@MainActor
struct VouchWarningCard: View {

    let title: String
    /// Two sentences, each one a thing that happens.
    let warnings: [String]
    /// Prefix for the accessibility identifiers.
    let identifier: String
    let onContinue: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: SLSpacing.md) {
            HStack(spacing: SLSpacing.sm) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(SLColor.warning)
                    .accessibilityHidden(true)
                Text(title)
                    .font(SLFont.bodyEmphasis)
                    .foregroundStyle(SLColor.textPrimary)
                    .accessibilityAddTraits(.isHeader)
            }

            ForEach(Array(warnings.enumerated()), id: \.offset) { index, warning in
                HStack(alignment: .top, spacing: SLSpacing.sm) {
                    Text(SLFormat.number(index + 1))
                        .font(SLFont.caption.weight(.semibold))
                        .foregroundStyle(SLColor.warning)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(SLColor.warning.opacity(0.15)))
                        .accessibilityHidden(true)
                    Text(warning)
                        .font(SLFont.body)
                        .foregroundStyle(SLColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("\(identifier).\(index + 1)")
            }

            SLButton(L10n.t("vouch.warning.continue"), variant: .primary, action: onContinue)
                .accessibilityIdentifier("\(identifier).continue")
            SLButton(L10n.t("common.cancel"), variant: .ghost, size: .compact, action: onCancel)
                .accessibilityIdentifier("\(identifier).cancel")
        }
        .padding(SLSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: SLRadius.lg).fill(SLColor.warning.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: SLRadius.lg).strokeBorder(SLColor.warning.opacity(0.35), lineWidth: 1))
    }
}
