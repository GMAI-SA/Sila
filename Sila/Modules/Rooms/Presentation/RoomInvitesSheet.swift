import SwiftUI

/// The host's guest list for a closed room: who is invited, who to add, and
/// who to withdraw.
///
/// Only a host sees this, and only for a room they closed. Two things it is
/// careful to keep apart, because the words are close and the consequences
/// are not:
///
/// **Withdrawing an invitation** stops somebody joining later. It says nothing
/// about anybody in the room right now.
///
/// **Removing** ejects a person from the room and is recorded as a decision
/// about them. That lives on the participant row in the live room, not here.
@MainActor
public struct RoomInvitesSheet: View {

    @State private var viewModel: RoomInvitesViewModel
    private let onClose: () -> Void
    @State private var isPicking = false

    /// - Parameters:
    ///   - viewModel: Owns the guest list and the calls that change it.
    ///   - onClose: Dismisses the sheet.
    public init(viewModel: RoomInvitesViewModel, onClose: @escaping () -> Void) {
        _viewModel = State(initialValue: viewModel)
        self.onClose = onClose
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: SLSpacing.lg) {
                    Text(L10n.t("rooms.invites.explanation"))
                        .font(SLFont.bodyLight)
                        .foregroundStyle(SLColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    addField

                    if viewModel.isLoading && viewModel.invited.isEmpty {
                        SLSkeletonRow(lineCount: 3)
                    } else if viewModel.invited.isEmpty {
                        SLEmptyState(
                            icon: "person.badge.plus",
                            title: L10n.t("rooms.invites.empty.title"),
                            subtitle: L10n.t("rooms.invites.empty.message")
                        )
                    } else {
                        guestList
                    }
                }
                .padding(SLSpacing.lg)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .tnScreenBackground()
            .tnNavigationBar(title: L10n.t("rooms.invites.title"))
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L10n.t("common.done"), action: onClose)
                        .foregroundStyle(SLColor.textSecondary)
                }
            }
            .task { await viewModel.load() }
            .sheet(isPresented: $isPicking) {
                if let directory = viewModel.people {
                    PeoplePickerSheet(
                        viewModel: PeoplePickerViewModel(
                            directory: directory,
                            viewerHandle: viewModel.viewerHandle,
                            excluding: viewModel.invited.map(\.handle)
                        ),
                        onPick: { people in Task { await viewModel.invite(people: people) } },
                        onClose: { isPicking = false }
                    )
                }
            }
            .tnToast($viewModel.toast)
        }
        .tint(SLColor.primary)
    }

    // MARK: - Pieces

    private var addField: some View {
        VStack(alignment: .leading, spacing: SLSpacing.sm) {
            if viewModel.people != nil {
                // The ordinary way in: tick people you know. The typed field
                // below stays for a handle you have not met yet.
                SLButton(
                    L10n.t("people.picker.choose"),
                    variant: .primary,
                    size: .compact,
                    icon: "person.2.badge.plus",
                    action: { isPicking = true }
                )
            }

            SLTextField(
                L10n.t("rooms.invites.add.label"),
                text: $viewModel.handlesText,
                placeholder: L10n.t("rooms.create.guests.placeholder"),
                accessibilityHint: L10n.t("rooms.create.guests.a11yHint"),
                submitLabel: .done,
                onSubmit: { Task { await viewModel.add() } }
            )

            SLButton(
                L10n.t("rooms.invites.add.button"),
                variant: .secondary,
                size: .compact,
                isLoading: viewModel.isAdding,
                isEnabled: viewModel.canAdd,
                accessibilityHint: L10n.t("rooms.invites.add.a11yHint")
            ) {
                Task { await viewModel.add() }
            }
        }
    }

    private var guestList: some View {
        VStack(alignment: .leading, spacing: SLSpacing.sm) {
            Text(L10n.plural("rooms.invites.count", viewModel.invited.count))
                .font(SLFont.micro)
                .tracking(0.8)
                .foregroundStyle(SLColor.textSecondary)

            ForEach(viewModel.invited) { guest in
                SLCard(padding: SLSpacing.md) {
                    HStack(spacing: SLSpacing.md) {
                        SLAvatar(
                            url: guest.avatarURL,
                            initials: guest.displayName,
                            size: .sm,
                            isVerified: guest.isVerified,
                            displayName: guest.displayName
                        )
                        VStack(alignment: .leading, spacing: 2) {
                            Text(guest.displayName)
                                .font(SLFont.bodyEmphasis)
                                .foregroundStyle(SLColor.textPrimary)
                                .lineLimit(1)
                            Text("@\(guest.handle)")
                                .font(SLFont.caption)
                                .foregroundStyle(SLColor.textSecondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Button(L10n.t("rooms.invites.revoke")) {
                            Task { await viewModel.revoke(guest.handle) }
                        }
                        .font(SLFont.caption)
                        .foregroundStyle(SLColor.danger)
                        .disabled(viewModel.revokingHandle != nil)
                        .accessibilityHint(Text(L10n.t("rooms.invites.revoke.a11yHint", guest.handle)))
                    }
                }
                .opacity(viewModel.revokingHandle == guest.handle ? 0.5 : 1)
            }
        }
    }
}

#Preview("Room invites") {
    RoomInvitesSheet(
        viewModel: RoomInvitesViewModel(
            roomId: UUID(),
            service: RoomsServiceMock(),
            analytics: RecordingAnalyticsClient()
        ),
        onClose: {}
    )
    .preferredColorScheme(.dark)
}
