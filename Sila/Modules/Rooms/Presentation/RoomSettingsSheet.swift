import SwiftUI

/// Room settings, for the host and co-hosts (contract v31): whether people
/// without an account may listen.
///
/// Turning it off takes the guests listening now out at once. A closed room
/// has no guests to allow, and says why; a private host is told when the
/// server refuses.
@MainActor
struct RoomSettingsSheet: View {

    @Bindable var viewModel: LiveRoomViewModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: SLSpacing.md) {
                    Toggle(isOn: Binding(
                        get: { viewModel.allowsGuests },
                        set: { allow in Task { await viewModel.setAllowGuests(allow) } }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L10n.t("rooms.guests.allow"))
                                .font(SLFont.body)
                                .foregroundStyle(SLColor.textPrimary)
                            Text(L10n.t("rooms.guests.allow.detail"))
                                .font(SLFont.micro)
                                .foregroundStyle(SLColor.textMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .tint(SLColor.primary)
                    .disabled(viewModel.isChangingGuests || (viewModel.guestsBlockedReason != nil && !viewModel.room.allowGuests))
                    .accessibilityIdentifier("room.settings.guests")

                    if let blocked = viewModel.guestsBlockedReason, !viewModel.room.allowGuests {
                        Label(blocked, systemImage: "lock.fill")
                            .font(SLFont.caption)
                            .foregroundStyle(SLColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("room.settings.blocked")
                    }
                    if viewModel.room.guestCount > 0 {
                        Label(RoomCopy.guestsListening(viewModel.room.guestCount), systemImage: "ear")
                            .font(SLFont.caption)
                            .foregroundStyle(SLColor.textSecondary)
                            .accessibilityIdentifier("room.settings.count")
                    }
                    if let error = viewModel.guestsError {
                        Text(error)
                            .font(SLFont.caption)
                            .foregroundStyle(SLColor.danger)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("room.settings.error")
                    }
                }
                .padding(SLSpacing.lg)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .tnScreenBackground()
            .tnNavigationBar(title: L10n.t("rooms.settings.title"))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.t("common.done")) { viewModel.isShowingSettings = false }
                        .foregroundStyle(SLColor.primary)
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}

/// "Guests can listen · 3 guests listening" under a room's title or on its
/// card (contract v31). Nothing when a room has neither to say.
@MainActor
struct RoomGuestsLine: View {
    let text: String?

    var body: some View {
        if let text {
            Label(text, systemImage: "ear")
                .font(SLFont.micro)
                .foregroundStyle(SLColor.textSecondary)
                .accessibilityIdentifier("room.guests")
        }
    }
}
