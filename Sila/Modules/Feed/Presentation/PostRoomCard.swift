import SwiftUI

/// The room a post is about.
///
/// A room is never recorded, so once it ends there is nothing to play back —
/// this card is the whole trace, which is why it keeps its title, its host
/// and its numbers after the room is over. It says "Ended" plainly rather
/// than offering a door that opens onto nothing.
struct PostRoomCard: View {

    let room: RoomCard
    /// Opens the room, when there is one to open.
    var onOpen: (@MainActor (RoomCard) -> Void)?

    var body: some View {
        let content = VStack(alignment: .leading, spacing: SLSpacing.sm) {
            HStack(spacing: SLSpacing.sm) {
                Image(systemName: room.isJoinable ? "waveform.circle.fill" : "waveform.circle")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(room.isJoinable ? SLColor.danger : SLColor.textMuted)
                Text(statusLabel)
                    .font(SLFont.micro)
                    .foregroundStyle(room.isJoinable ? SLColor.danger : SLColor.textMuted)
                Spacer(minLength: 0)
                if room.isJoinable {
                    Text(L10n.plural("rooms.card.listeners", room.participantCount))
                        .font(SLFont.micro)
                        .foregroundStyle(SLColor.textSecondary)
                }
            }

            Text(room.title)
                .font(SLFont.bodyEmphasis)
                .foregroundStyle(SLColor.textPrimary)
                .lineLimit(2)
                .slContentDirection(TextDirection.resolve(languageCode: nil, text: room.title))

            HStack(spacing: SLSpacing.sm) {
                SLAvatar(
                    url: room.host.avatarURL,
                    initials: room.host.initials,
                    size: .sm,
                    isVerified: room.host.isVerified,
                    displayName: room.host.displayName
                )
                Text(room.host.displayName)
                    .font(SLFont.caption)
                    .foregroundStyle(SLColor.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Label(SLFormat.compactCount(room.metrics.likes), systemImage: "heart")
                    .font(SLFont.micro)
                    .foregroundStyle(SLColor.textMuted)
                Label(SLFormat.compactCount(room.metrics.views), systemImage: "eye")
                    .font(SLFont.micro)
                    .foregroundStyle(SLColor.textMuted)
            }
        }
        .padding(SLSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SLColor.surface2)
        .clipShape(RoundedRectangle(cornerRadius: SLRadius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: SLRadius.md, style: .continuous)
                .strokeBorder(room.isJoinable ? SLColor.danger.opacity(0.35) : SLColor.stroke, lineWidth: 1)
        )

        if let onOpen, room.isJoinable {
            Button { onOpen(room) } label: { content }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityHint(Text(L10n.t("rooms.card.open.a11yHint")))
        } else {
            content
                .accessibilityElement(children: .combine)
        }
    }

    private var statusLabel: String {
        switch room.status {
        case .live: return L10n.t("rooms.card.live")
        case .scheduled: return L10n.t("rooms.card.scheduled")
        case .ended, .unknown: return L10n.t("rooms.card.ended")
        }
    }
}
