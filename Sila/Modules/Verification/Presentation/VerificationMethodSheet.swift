import SwiftUI

/// The two ways through the wall.
public enum VerificationRoute: String, Identifiable, Sendable, CaseIterable {
    /// Saudi National ID or Iqama, confirmed in the Nafath app.
    case nafath
    /// A passport or ID card from anywhere, photographed and reviewed.
    case document

    public var id: String { rawValue }
}

/// Lets the person pick a route. Both are offered to everybody — a Saudi
/// citizen may prefer the document route, and nothing about the choice is
/// recorded beyond which door was opened.
@MainActor
public struct VerificationMethodSheet: View {

    private let onChoose: (VerificationRoute) -> Void

    public init(onChoose: @escaping (VerificationRoute) -> Void) {
        self.onChoose = onChoose
    }

    public var body: some View {
        VStack(spacing: SLSpacing.lg) {
            Capsule()
                .fill(SLColor.stroke)
                .frame(width: 36, height: 4)
                .padding(.top, SLSpacing.sm)
                .accessibilityHidden(true)

            VStack(spacing: SLSpacing.xs) {
                Text(L10n.t("verification.method.title"))
                    .font(SLFont.displayM)
                    .foregroundStyle(SLColor.textPrimary)
                    .multilineTextAlignment(.center)
                Text(L10n.t("verification.method.subtitle"))
                    .font(SLFont.bodyLight)
                    .foregroundStyle(SLColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, SLSpacing.lg)

            VStack(spacing: SLSpacing.md) {
                option(
                    .nafath,
                    icon: "person.badge.shield.checkmark",
                    title: L10n.t("verification.method.nafath.title"),
                    detail: L10n.t("verification.method.nafath.detail")
                )
                option(
                    .document,
                    icon: "doc.text.viewfinder",
                    title: L10n.t("verification.method.document.title"),
                    detail: L10n.t("verification.method.document.detail")
                )
            }
            .padding(.horizontal, SLSpacing.lg)

            Spacer(minLength: SLSpacing.lg)
        }
        .frame(maxWidth: .infinity)
        .tnScreenBackground()
    }

    private func option(_ route: VerificationRoute, icon: String, title: String, detail: String) -> some View {
        SLCard(
            padding: SLSpacing.md,
            accessibilityLabel: "\(title). \(detail)",
            accessibilityHint: L10n.t("verification.method.hint"),
            onTap: { onChoose(route) }
        ) {
            HStack(spacing: SLSpacing.md) {
                Image(systemName: icon)
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(SLColor.primary)
                    .frame(width: 40)
                VStack(alignment: .leading, spacing: SLSpacing.xs) {
                    Text(title)
                        .font(SLFont.bodyEmphasis)
                        .foregroundStyle(SLColor.textPrimary)
                    Text(detail)
                        .font(SLFont.caption)
                        .foregroundStyle(SLColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.forward")
                    .font(SLFont.caption)
                    .foregroundStyle(SLColor.textMuted)
            }
        }
    }
}

#Preview("Method sheet") {
    VerificationMethodSheet { _ in }
        .preferredColorScheme(.dark)
}
