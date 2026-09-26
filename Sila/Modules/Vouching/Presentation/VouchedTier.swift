import SwiftUI

/// The limited tier a vouched account lives in (contract v24 §4), said where
/// it bites rather than discovered as errors: the countdown on Home, a
/// Messages tab that explains itself, and the offer that answers any
/// `self_verification_required`.

/// "@noura vouches for you · 23 days left — verify to keep posting", above
/// Home. The 30 days are the whole point of the tier: a bridge to
/// verification, not a place to live.
@MainActor
struct VouchCountdownBanner: View {
    let vouch: VouchState
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: SLSpacing.sm) {
                Image(systemName: SLVouchTag.glyph)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(SLColor.textSecondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.t("vouch.banner.title", vouch.voucher?.handle ?? vouch.voucherHandle))
                        .font(SLFont.caption)
                        .foregroundStyle(SLColor.textPrimary)
                    if let expires = vouch.expiresAt {
                        Text(L10n.t("vouch.banner.detail", VouchCopy.daysLeftText(until: expires)))
                            .font(SLFont.micro)
                            .foregroundStyle(SLColor.warning)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.forward")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(SLColor.textMuted)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, SLSpacing.lg)
            .padding(.vertical, SLSpacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SLColor.surface1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text(L10n.t("vouch.banner.hint")))
        .accessibilityIdentifier("vouching.banner")
    }
}

/// A place a vouched account cannot use yet, explained in place — the
/// Messages tab, for one: nobody can message a vouched account, and it
/// cannot message anybody (contract v24 §4).
@MainActor
struct VouchedNotice: View {
    let icon: String
    let title: String
    let message: String
    let onVerify: (() -> Void)?

    var body: some View {
        VStack(spacing: SLSpacing.lg) {
            SLEmptyState(icon: icon, title: title, subtitle: message, tint: SLColor.textSecondary)
            if let onVerify {
                SLButton(L10n.t("vouch.own.action"), variant: .primary, icon: "checkmark.seal", action: onVerify)
                    .accessibilityIdentifier("vouching.notice.verify")
            }
        }
        .padding(SLSpacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .tnScreenBackground()
    }
}

/// "Verify your identity to do this" — the answer to `403
/// self_verification_required`, never the wall (contract v24 §4, §9).
@MainActor
struct SelfVerificationPromptSheet: View {
    let prompt: SelfVerificationPrompt
    let onVerify: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: SLSpacing.lg) {
            HStack(spacing: SLSpacing.sm) {
                Image(systemName: "checkmark.seal")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(SLColor.primary)
                    .accessibilityHidden(true)
                Text(L10n.t("vouch.error.selfVerificationRequired"))
                    .font(SLFont.displayM)
                    .foregroundStyle(SLColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
            }
            Text(prompt.reason ?? L10n.t("vouch.selfVerify.message"))
                .font(SLFont.body)
                .foregroundStyle(SLColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            SLButton(L10n.t("vouch.own.action"), variant: .primary, icon: "checkmark.seal", action: onVerify)
                .accessibilityIdentifier("vouching.selfVerify.verify")
            SLButton(L10n.t("vouch.own.later"), variant: .ghost, size: .compact, action: onClose)
        }
        .padding(SLSpacing.lg)
        .padding(.top, SLSpacing.md)
        // From the top of the sheet, under its grabber, rather than floating
        // in the middle of it: UIKit presents this (see
        // ``SelfVerificationPresenter``), and sizes the sheet itself.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .tnScreenBackground()
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}
