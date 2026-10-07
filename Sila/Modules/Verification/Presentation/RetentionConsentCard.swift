import SwiftUI

/// **"Keep your photos? (optional)"** — the consent card of contract v34 §7.2.
///
/// Drawn on the step that sends, beside Send, every time the server
/// announces a consent version. One language only, the one the app is
/// showing (never English and Arabic side by side), right to left in
/// Arabic. The box starts unticked and nothing here nudges towards ticking:
/// no pre-tick, no "recommended", no second prompt.
@MainActor
struct RetentionConsentCard: View {

    @Binding var isTicked: Bool
    let onOpenPolicy: () -> Void

    /// The card's lines, in order. Line 3 is the wording for where the
    /// automatic check runs today (contract v34 §7.2, gate G3): swap it for
    /// the in-Kingdom one if the model moves.
    static let lineKeys = [
        "document.consent.line1",
        "document.consent.line2",
        "document.consent.line3",
        "document.consent.line4",
        "document.consent.line5"
    ]

    /// Where the person withdraws, as this app labels it: the Profile tab,
    /// its Account entry (the sheet titled Account), the Privacy section and
    /// the Verification photos row (contract v34 §7.8). Built from the very
    /// labels those screens show, so line 5 cannot name a screen the app
    /// does not have.
    static let withdrawalRouteKeys = [
        "feed.tab.profile.label",
        "feed.profileOff.account.title",
        "account.section.privacy",
        "settings.privacy.verificationPhotos.row"
    ]

    /// "Profile › Account › Privacy › Verification photos", in the app's
    /// language.
    static var withdrawalRoute: String {
        withdrawalRouteKeys.map { L10n.t($0) }.joined(separator: " › ")
    }

    /// The words of one line, line 5 with the route filled in.
    static func text(_ key: String) -> String {
        key == "document.consent.line5" ? L10n.t(key, withdrawalRoute) : L10n.t(key)
    }

    var body: some View {
        VStack(spacing: SLSpacing.sm) {
        SLCard(padding: SLSpacing.md) {
            VStack(alignment: .leading, spacing: SLSpacing.sm) {
                Text(L10n.t("document.consent.title"))
                    .font(SLFont.bodyEmphasis)
                    .foregroundStyle(SLColor.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("document.consent.title")
                ForEach(Self.lineKeys, id: \.self) { key in
                    Text(Self.text(key))
                        .font(SLFont.caption)
                        .foregroundStyle(SLColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier(key)
                }
                Button {
                    isTicked.toggle()
                } label: {
                    HStack(alignment: .top, spacing: SLSpacing.sm) {
                        Image(systemName: isTicked ? "checkmark.square.fill" : "square")
                            .font(.title3)
                            .foregroundStyle(isTicked ? SLColor.primary : SLColor.textMuted)
                        Text(L10n.t("document.consent.checkbox"))
                            .font(SLFont.bodyEmphasis)
                            .foregroundStyle(SLColor.textPrimary)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(L10n.t("document.consent.checkbox")))
                .accessibilityValue(Text(L10n.t(isTicked ? "document.consent.checkbox.on" : "document.consent.checkbox.off")))
                .accessibilityAddTraits(isTicked ? [.isButton, .isSelected] : .isButton)
                .accessibilityIdentifier("document.consent.checkbox")
                .padding(.top, SLSpacing.xs)
            }
        }
        Button(L10n.t("document.consent.link"), action: onOpenPolicy)
            .font(SLFont.caption)
            .foregroundStyle(SLColor.primary)
            .accessibilityIdentifier("document.consent.link")
        }
    }
}
