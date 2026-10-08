import SwiftUI

/// A room reached from outside the app — a link, a push, an invitation —
/// shown before anything is joined (round-2 security finding CA-1).
///
/// Joining puts the person in the host's listener list by verified name, so
/// the app never does it on a link's say-so: this card shows whose room it
/// is and what it is about, and only the Join button (Listen, signed out)
/// goes in. "Not now" leaves without the host ever knowing.
@MainActor
struct RoomLinkScreen: View {

    enum Action { case join, listen }

    /// `nil` while a guest's card is being looked up.
    let preview: RoomLinkPreview?
    let action: Action
    let onEnter: @MainActor () -> Void
    let onCancel: @MainActor () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SLSpacing.lg) {
                Text(L10n.t("rooms.link.heading"))
                    .font(SLFont.caption)
                    .foregroundStyle(SLColor.textMuted)
                    .accessibilityIdentifier("roomLink.heading")
                SLCard {
                    card
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("roomLink.card")
                Text(L10n.t(action == .join ? "rooms.link.join.note" : "rooms.link.listen.note"))
                    .font(SLFont.caption)
                    .foregroundStyle(SLColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                buttons
            }
            .padding(.horizontal, SLSpacing.lg)
            .padding(.vertical, SLSpacing.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .tnScreenBackground()
        .accessibilityIdentifier("roomLink.screen")
    }

    @ViewBuilder
    private var card: some View {
        if let preview {
            VStack(alignment: .leading, spacing: SLSpacing.sm) {
                Text(preview.title ?? L10n.t("rooms.link.unlisted.title"))
                    .font(SLFont.displayM)
                    .foregroundStyle(SLColor.textPrimary)
                    .slContentDirection(TextDirection.resolve(languageCode: nil, text: preview.title ?? ""))
                if let topic = preview.topic, !topic.isEmpty {
                    Text(topic)
                        .font(SLFont.body)
                        .foregroundStyle(SLColor.textSecondary)
                }
                if let name = preview.hostName {
                    HStack(spacing: SLSpacing.sm) {
                        SLAvatar(initials: String(name.prefix(2)), size: .sm,
                                 isVerified: preview.isHostVerified, displayName: name)
                        Text(L10n.t("rooms.link.host", name))
                            .font(SLFont.caption)
                            .foregroundStyle(SLColor.textSecondary)
                    }
                }
                Text(statusLine(preview))
                    .font(SLFont.caption)
                    .foregroundStyle(preview.status == .live ? SLColor.primary : SLColor.textMuted)
                    .accessibilityIdentifier("roomLink.status")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(spacing: SLSpacing.sm) {
                ProgressView()
                Text(L10n.t("rooms.link.loading"))
                    .font(SLFont.caption)
                    .foregroundStyle(SLColor.textMuted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func statusLine(_ preview: RoomLinkPreview) -> String {
        switch preview.status {
        case .live:
            if let count = preview.peopleCount { return L10n.plural("rooms.link.live.people", count) }
            return L10n.t("rooms.link.live")
        case .scheduled:
            return L10n.t("rooms.link.scheduled")
        case .ended:
            return L10n.t("rooms.link.ended")
        case .unknown:
            return L10n.t("rooms.link.unlisted.status")
        }
    }

    private var buttons: some View {
        VStack(spacing: SLSpacing.sm) {
            if preview?.canEnter ?? false {
                SLButton(
                    L10n.t(action == .join ? "rooms.link.join" : "rooms.link.listen"),
                    variant: .primary,
                    icon: action == .join ? "person.wave.2" : "headphones",
                    accessibilityHint: L10n.t(action == .join ? "rooms.link.join.hint" : "rooms.link.listen.hint"),
                    action: { onEnter() }
                )
                .accessibilityIdentifier("roomLink.enter")
            }
            SLButton(
                L10n.t("rooms.link.notNow"),
                variant: .ghost,
                action: { onCancel() }
            )
            .accessibilityIdentifier("roomLink.cancel")
        }
    }
}
