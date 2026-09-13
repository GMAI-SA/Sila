import SwiftUI

/// Putting a room on your own timeline, with or without a word of your own.
///
/// A room is never recorded. Once it ends there is nothing to play back, so a
/// post carrying its card is the only way it is ever referred to again — and
/// the only way somebody who was not in it finds out it happened.
@MainActor
struct ShareRoomSheet: View {

    let room: VoiceRoom
    /// Returns `true` when the post was made, so the sheet can close itself.
    let onShare: @MainActor (String) async -> Bool
    let onClose: @MainActor () -> Void

    @State private var text = ""
    @State private var isPosting = false
    @FocusState private var isFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: SLSpacing.lg) {
                Text(L10n.t("rooms.share.explanation"))
                    .font(SLFont.caption)
                    .foregroundStyle(SLColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                TextField(L10n.t("rooms.share.placeholder"), text: $text, axis: .vertical)
                    .font(SLFont.body)
                    .foregroundStyle(SLColor.textPrimary)
                    .lineLimit(3...6)
                    .focused($isFocused)
                    .padding(SLSpacing.md)
                    .background(SLColor.surface2)
                    .clipShape(RoundedRectangle(cornerRadius: SLRadius.md, style: .continuous))
                    .slContentDirection(TextDirection.resolve(languageCode: nil, text: text))
                    .accessibilityIdentifier("rooms.share.text")

                // The card the post will carry, exactly as a reader sees it.
                PostRoomCard(room: card)

                Spacer(minLength: 0)
            }
            .padding(SLSpacing.lg)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .tnScreenBackground()
            .tnNavigationBar(title: L10n.t("rooms.share.title"))
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L10n.t("common.cancel"), action: onClose)
                        .foregroundStyle(SLColor.textSecondary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    SLButton(
                        L10n.t("rooms.share.action"),
                        variant: .primary,
                        size: .compact,
                        isLoading: isPosting,
                        isEnabled: !isPosting,
                        asyncAction: {
                            isPosting = true
                            defer { isPosting = false }
                            if await onShare(text) { onClose() }
                        }
                    )
                    .frame(width: 88)
                }
            }
            .onAppear { isFocused = true }
        }
        .tint(SLColor.primary)
    }

    /// The room as a post will carry it.
    private var card: RoomCard {
        RoomCard(
            id: room.id,
            title: room.title,
            topic: room.topic,
            status: room.status,
            scope: room.scope,
            scopeCountry: room.scopeCountry,
            scopeRegion: room.scopeRegion,
            host: room.host,
            participantCount: room.speakerCount + room.listenerCount,
            scheduledFor: room.scheduledFor,
            startedAt: room.startedAt,
            metrics: room.metrics,
            viewerLiked: room.viewerLiked
        )
    }
}
