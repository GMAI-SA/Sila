import SwiftUI

/// The two ways through the wall.
public enum VerificationRoute: String, Identifiable, Sendable, CaseIterable {
    /// Saudi National ID or Iqama, confirmed in the Nafath app.
    case nafath
    /// A passport or ID card from anywhere, photographed and reviewed.
    case document

    public var id: String { rawValue }
}

/// Lets the person pick a route. While Nafath is live, a Saudi claim goes
/// through Nafath — one person, one account — and everyone else may use
/// either. While it is not ("coming soon"), Nafath is shown but closed and
/// the document route is open to every nationality. Nothing about the choice
/// is recorded beyond which door was opened.
@MainActor
public struct VerificationMethodSheet: View {

    private let declaredNationality: String?
    private let nafathAvailable: Bool
    private let onChoose: (VerificationRoute) -> Void
    private let onChangeNationality: (() -> Void)?

    /// - Parameters:
    ///   - declaredNationality: The claim on the account. `SA` hides the
    ///     document route — Nafath is the only door for a Saudi, by policy.
    ///   - onChangeNationality: Reopens the country picker. A claim is
    ///     changeable until it has been proved, and somebody who taps the
    ///     wrong country needs a way back that is not "delete the account".
    ///     `nil` hides the affordance.
    ///   - onChoose: Called with the chosen route.
    public init(
        declaredNationality: String? = nil,
        nafathAvailable: Bool = false,
        onChangeNationality: (() -> Void)? = nil,
        onChoose: @escaping (VerificationRoute) -> Void
    ) {
        self.declaredNationality = declaredNationality
        self.nafathAvailable = nafathAvailable
        self.onChangeNationality = onChangeNationality
        self.onChoose = onChoose
    }

    /// Whether the document route is on offer for this claim.
    public var offersDocumentRoute: Bool {
        !nafathAvailable || !DocumentVerificationViewModel.nafathOnly.contains(declaredNationality ?? "")
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

            if let code = declaredNationality {
                chosenNationality(code)
                    .padding(.horizontal, SLSpacing.lg)
            }

            VStack(spacing: SLSpacing.md) {
                if nafathAvailable {
                    option(
                        .nafath,
                        icon: "person.badge.shield.checkmark",
                        title: L10n.t("verification.method.nafath.title"),
                        detail: L10n.t("verification.method.nafath.detail")
                    )
                } else {
                    comingSoon
                }
                if offersDocumentRoute {
                    option(
                        .document,
                        icon: "doc.text.viewfinder",
                        title: L10n.t("verification.method.document.title"),
                        detail: L10n.t("verification.method.document.detail")
                    )
                } else {
                    Text(L10n.t("verification.method.saudiOnly"))
                        .font(SLFont.caption)
                        .foregroundStyle(SLColor.textMuted)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, SLSpacing.xs)
                }
            }
            .padding(.horizontal, SLSpacing.lg)

            Spacer(minLength: SLSpacing.lg)
        }
        .frame(maxWidth: .infinity)
        .tnScreenBackground()
    }

    /// The claim, and the way back to the picker.
    private func chosenNationality(_ code: String) -> some View {
        HStack(spacing: SLSpacing.sm) {
            Text(CountryCode.flag(code) ?? "")
                .accessibilityHidden(true)
            Text(L10n.t("verification.method.nationality", CountryCode.name(code) ?? code))
                .font(SLFont.caption)
                .foregroundStyle(SLColor.textSecondary)
            Spacer(minLength: 0)
            if let onChangeNationality {
                Button(L10n.t("common.change"), action: onChangeNationality)
                    .font(SLFont.caption)
                    .foregroundStyle(SLColor.primary)
                    .accessibilityHint(Text(L10n.t("verification.method.change.hint")))
            }
        }
        .padding(.horizontal, SLSpacing.md)
        .padding(.vertical, SLSpacing.sm)
        .background(SLColor.surface1)
        .clipShape(RoundedRectangle(cornerRadius: SLRadius.md))
    }

    /// Nafath, shown but closed: people in Saudi Arabia look for it, and
    /// hiding it would read as "Sila does not use Nafath".
    private var comingSoon: some View {
        HStack(spacing: SLSpacing.md) {
            Image(systemName: "person.badge.shield.checkmark")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(SLColor.textMuted)
                .frame(width: 40)
            VStack(alignment: .leading, spacing: SLSpacing.xs) {
                HStack(spacing: SLSpacing.sm) {
                    Text(L10n.t("verification.method.nafath.title"))
                        .font(SLFont.bodyEmphasis)
                        .foregroundStyle(SLColor.textSecondary)
                    Text(L10n.t("verification.method.nafath.comingSoon"))
                        .font(SLFont.micro)
                        .foregroundStyle(SLColor.primary)
                        .padding(.horizontal, SLSpacing.sm)
                        .padding(.vertical, 2)
                        .background(SLColor.primary.opacity(0.12))
                        .clipShape(Capsule())
                }
                Text(L10n.t("verification.method.nafath.comingSoonDetail"))
                    .font(SLFont.caption)
                    .foregroundStyle(SLColor.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(SLSpacing.md)
        .background(SLColor.surface1.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: SLRadius.md))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("verification.method.nafath.comingSoon")
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
