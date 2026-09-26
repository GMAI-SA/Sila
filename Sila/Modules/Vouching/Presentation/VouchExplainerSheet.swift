import SwiftUI

/// What a tap on a tag opens (contract v24 §3.6).
///
/// Somebody else's tag: the explainer — who vouches, that the person has not
/// verified their own identity, and why there is no seal and no flag — with
/// **See @aziz**. Your own: "Make it your own", and the way into the
/// verification flow. Everything here comes from the card's own public data,
/// so a guest reads the same explainer.
@MainActor
public struct VouchExplainerSheet: View {

    private let person: UserSummary
    private let vouchedBy: VouchedBy
    private let isOwn: Bool
    private let onSeeVoucher: (() -> Void)?
    private let onVerify: (() -> Void)?
    private let onClose: () -> Void

    /// - Parameters:
    ///   - person: Whose tag was tapped.
    ///   - isOwn: The viewer tapped their own tag.
    ///   - onSeeVoucher: Opens the voucher's profile. `nil` hides the button.
    ///   - onVerify: Opens the verification flow, for the own-tag sheet.
    public init(
        person: UserSummary,
        vouchedBy: VouchedBy,
        isOwn: Bool,
        onSeeVoucher: (() -> Void)?,
        onVerify: (() -> Void)?,
        onClose: @escaping () -> Void
    ) {
        self.person = person
        self.vouchedBy = vouchedBy
        self.isOwn = isOwn
        self.onSeeVoucher = onSeeVoucher
        self.onVerify = onVerify
        self.onClose = onClose
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: SLSpacing.lg) {
            HStack(spacing: SLSpacing.sm) {
                Image(systemName: SLVouchTag.glyph)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(SLColor.textSecondary)
                    .accessibilityHidden(true)
                Text(isOwn ? L10n.t("vouch.own.title") : L10n.t("vouch.explainer.title"))
                    .font(SLFont.displayM)
                    .foregroundStyle(SLColor.textPrimary)
                    .accessibilityAddTraits(.isHeader)
            }

            SLVouchTag(text: VouchCopy.tag(vouchedBy), accessibilityLabel: VouchCopy.tagAccessibility(vouchedBy))

            Text(isOwn
                 ? VouchCopy.makeItYourOwn(voucher: vouchedBy.handle)
                 : VouchCopy.explainer(voucher: vouchedBy.handle, person: person.displayName))
                .font(SLFont.body)
                .foregroundStyle(SLColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("vouching.explainer.body")

            VStack(alignment: .leading, spacing: SLSpacing.xs) {
                if let country = vouchedBy.countryName {
                    // Text, never a flag: the country was given and matched,
                    // not proved, and it opens nothing.
                    Text(L10n.t("vouch.explainer.country", country))
                        .font(SLFont.caption)
                        .foregroundStyle(SLColor.textMuted)
                }
                if let since = vouchedBy.since {
                    Text(L10n.t("vouch.explainer.since", SLFormat.date(since)))
                        .font(SLFont.caption)
                        .foregroundStyle(SLColor.textMuted)
                }
            }

            VStack(spacing: SLSpacing.sm) {
                if isOwn, let onVerify {
                    SLButton(
                        L10n.t("vouch.own.action"),
                        variant: .primary,
                        icon: "checkmark.seal",
                        accessibilityHint: L10n.t("vouch.own.action.hint"),
                        action: onVerify
                    )
                    .accessibilityIdentifier("vouching.own.verify")
                }
                if !isOwn, let onSeeVoucher {
                    SLButton(
                        L10n.t("vouch.explainer.see", vouchedBy.handle),
                        variant: .secondary,
                        icon: "person.crop.circle",
                        action: onSeeVoucher
                    )
                    .accessibilityIdentifier("vouching.explainer.see")
                }
                SLButton(isOwn ? L10n.t("vouch.own.later") : L10n.t("common.done"), variant: .ghost, size: .compact, action: onClose)
            }
        }
        .padding(SLSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tnScreenBackground()
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

/// A tag tapped somewhere below the shell — the person, and whose tag it is.
public struct VouchTagSelection: Identifiable, Equatable {
    public let person: UserSummary
    public let vouchedBy: VouchedBy
    public let isOwn: Bool

    public var id: UUID { person.id }

    /// `nil` when the person carries no tag to explain.
    public init?(person: UserSummary, viewerId: UUID?) {
        guard !person.isVerified, let vouchedBy = person.vouchedBy else { return nil }
        self.person = person
        self.vouchedBy = vouchedBy
        self.isOwn = viewerId != nil && person.id == viewerId
    }
}
