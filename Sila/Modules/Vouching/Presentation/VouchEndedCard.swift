import SwiftUI

/// Why the last vouch ended (contract v24 §15), said calmly in the wall's own
/// look: the vouch from @aziz ended, one plain sentence why, and what is left
/// — somebody else may vouch, or only verification. The way to verify is the
/// screen's own button, beside it.
///
/// Only the interface's language, never two side by side; the handle is one
/// left-to-right piece inside the Arabic sentences (their isolates), and
/// nothing the voucher wrote about the person is ever on it.
@MainActor
struct VouchEndedCard: View {

    let ended: LastEndedVouch
    /// The card's accessibility identifier; VoiceOver reads it as one
    /// element, title, reason and next step in that order.
    var identifier = "vouching.ended"

    var body: some View {
        let copy = VouchCopy.lastEnded(ended)
        SLCard(padding: SLSpacing.md) {
            VStack(alignment: .leading, spacing: SLSpacing.xs) {
                HStack(spacing: SLSpacing.sm) {
                    Image(systemName: SLVouchTag.glyph)
                        .foregroundStyle(SLColor.textSecondary)
                        .accessibilityHidden(true)
                    SLBadge(L10n.t("vouch.ended.badge"), style: .neutral)
                }
                Text(copy.title)
                    .font(SLFont.bodyEmphasis)
                    .foregroundStyle(SLColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(copy.reason)
                    .font(SLFont.bodyLight)
                    .foregroundStyle(SLColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(copy.next)
                    .font(SLFont.caption)
                    .foregroundStyle(SLColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text([copy.title, copy.reason, copy.next].joined(separator: ". ")))
        .accessibilityIdentifier(identifier)
    }
}

#Preview("Vouch ended — declined") {
    VouchEndedCard(ended: AuthServiceMock.mockLastEnded())
        .padding()
        .tnScreenBackground()
}

#Preview("Vouch ended — a finding") {
    VouchEndedCard(ended: AuthServiceMock.mockLastEnded(reason: "impostor", vouchAgain: "vouch_not_eligible"))
        .padding()
        .tnScreenBackground()
}
