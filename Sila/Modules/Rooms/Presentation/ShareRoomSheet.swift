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

// MARK: - Sharing the link

/// A room's link, its title and one short line, ready for the system share
/// sheet — WhatsApp, Messages, X, Telegram, Mail, Copy and the rest.
///
/// The link is the room's universal link (`https://known.gmai.sa/rooms/<id>`):
/// it opens the app on a phone that has it, and the room's card on the web
/// for everybody else — never a join, so an open link costs nothing.
public enum RoomShareContent {

    /// Whether the link is offered at all. An invite-only room, or one for a
    /// group the host chose, is not advertised — that is how such a room
    /// would leak; and an ended room has nothing left to open.
    public static func canShareLink(_ room: VoiceRoom) -> Bool {
        room.status != .ended && !room.isInviteOnly && room.groupId == nil
    }

    public static func url(_ room: VoiceRoom) -> URL { Permalink.room(room.id) }

    /// "Listen live with me on Known: <title>" / "Coming up on Known: <title>".
    public static func message(_ room: VoiceRoom) -> String {
        room.status == .live
            ? L10n.t("rooms.shareLink.live", room.title)
            : L10n.t("rooms.shareLink.scheduled", room.title)
    }
}

/// The system share sheet for a room, as an icon or a labelled button.
@MainActor
public struct RoomShareLink: View {
    let room: VoiceRoom
    var showsTitle = false

    public init(room: VoiceRoom, showsTitle: Bool = false) {
        self.room = room
        self.showsTitle = showsTitle
    }

    public var body: some View {
        ShareLink(
            item: RoomShareContent.url(room),
            subject: Text(room.title),
            // No preview of our own: iOS reads the page's link preview
            // (its Open Graph tags) for the header of the sheet.
            message: Text(RoomShareContent.message(room))
        ) {
            if showsTitle {
                Label(L10n.t("rooms.shareLink.action"), systemImage: "square.and.arrow.up")
            } else {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 15, weight: .regular))
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
        }
        .accessibilityLabel(Text(L10n.t("rooms.shareLink.action")))
        .accessibilityIdentifier("rooms.shareLink")
    }
}
