import SwiftUI

/// The Rooms tab for somebody without an account (contract v31, owner
/// request 2026-09-28): what is live now and what is coming, only rooms a
/// guest may open. Tapping one listens at once — nothing is asked of the
/// phone but playback.
///
/// Laid out as the member tab is (``RoomsScreen``), less what needs an
/// account: no reminders, no hosting, no events.
@MainActor
public struct GuestRoomsScreen: View {

    @Bindable private var viewModel: GuestRoomsViewModel
    private let onOpen: @MainActor (RoomCard) -> Void

    @FocusState private var isSearchFocused: Bool

    public init(viewModel: GuestRoomsViewModel, onOpen: @escaping @MainActor (RoomCard) -> Void) {
        self.viewModel = viewModel
        self.onOpen = onOpen
    }

    public var body: some View {
        VStack(spacing: 0) {
            searchField
            ScrollView {
                LazyVStack(alignment: .leading, spacing: SLSpacing.md) {
                    banner
                    content
                }
                .padding(.horizontal, SLSpacing.lg)
                .padding(.bottom, SLSpacing.xl)
            }
            .refreshable { await viewModel.load() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .tnScreenBackground()
        .task { await viewModel.loadIfNeeded() }
    }

    // MARK: - Search

    private var searchField: some View {
        HStack(spacing: SLSpacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(SLColor.textMuted)
            TextField(
                "",
                text: $viewModel.query,
                prompt: Text(L10n.t("rooms.search.placeholder")).foregroundStyle(SLColor.textMuted)
            )
            .font(SLFont.body)
            .foregroundStyle(SLColor.textPrimary)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.search)
            .focused($isSearchFocused)
            .slContentDirection(TextDirection.resolve(languageCode: nil, text: viewModel.query))
            .accessibilityLabel(Text(L10n.t("rooms.search.placeholder")))
            .accessibilityHint(Text(L10n.t("rooms.search.a11yHint")))

            if viewModel.isSearching {
                Button {
                    viewModel.query = ""
                    isSearchFocused = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(SLColor.textMuted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(L10n.t("rooms.search.clear")))
            }
        }
        .padding(.horizontal, SLSpacing.md)
        .padding(.vertical, SLSpacing.sm)
        .background(RoundedRectangle(cornerRadius: SLRadius.md).fill(SLColor.surface1))
        .overlay(RoundedRectangle(cornerRadius: SLRadius.md).strokeBorder(SLColor.stroke, lineWidth: 1))
        .padding(.horizontal, SLSpacing.lg)
        .padding(.vertical, SLSpacing.sm)
    }

    // MARK: - Banner

    /// What this tab is for a guest, and the promise every room tab makes.
    private var banner: some View {
        VStack(alignment: .leading, spacing: SLSpacing.sm) {
            HStack(alignment: .top, spacing: SLSpacing.sm) {
                Image(systemName: "ear")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SLColor.primary)
                Text(L10n.t("guest.rooms.banner"))
                    .font(SLFont.micro)
                    .foregroundStyle(SLColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("guest.rooms.note")
            HStack(alignment: .top, spacing: SLSpacing.sm) {
                Image(systemName: "waveform.slash")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SLColor.secondary)
                Text(RoomCopy.neverRecorded)
                    .font(SLFont.micro)
                    .foregroundStyle(SLColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
        }
        .padding(SLSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: SLRadius.md).fill(SLColor.secondary.opacity(0.08)))
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch viewModel.emptyKind {
        case let .failed(message):
            SLEmptyState(
                icon: "wifi.exclamationmark",
                title: L10n.t("rooms.error.title"),
                subtitle: message,
                tint: SLColor.danger,
                actionTitle: L10n.t("rooms.error.retry"),
                action: { Task { await viewModel.load() } }
            )
            .padding(.top, SLSpacing.xl)
        case .queryTooShort:
            SLEmptyState(
                icon: "character.cursor.ibeam",
                title: RoomCopy.searchTooShortTitle,
                subtitle: RoomCopy.searchTooShortSubtitle,
                tint: SLColor.textSecondary
            )
            .padding(.top, SLSpacing.xl)
        case let .noMatches(query):
            SLEmptyState(
                icon: "magnifyingglass",
                title: RoomCopy.emptySearchTitle,
                subtitle: RoomCopy.emptySearchSubtitle(query),
                tint: SLColor.textSecondary
            )
            .padding(.top, SLSpacing.xl)
        case .noRooms:
            SLEmptyState(
                icon: "mic.slash",
                title: L10n.t("guest.rooms.empty.title"),
                subtitle: L10n.t("guest.rooms.empty.subtitle"),
                tint: SLColor.textSecondary,
                actionTitle: L10n.t("rooms.error.retry"),
                action: { Task { await viewModel.load() } }
            )
            .padding(.top, SLSpacing.xl)
            .accessibilityIdentifier("guest.rooms.empty")
        case .none:
            if viewModel.live == nil {
                ForEach(0..<3, id: \.self) { _ in SLSkeletonRow(lineCount: 3) }
                    .accessibilityLabel(Text(L10n.t("rooms.loading.a11y")))
            } else {
                rooms
            }
        }
    }

    @ViewBuilder
    private var rooms: some View {
        if !viewModel.visibleLive.isEmpty {
            sectionHeader(viewModel.isSearching ? L10n.t("rooms.section.results") : L10n.t("rooms.section.liveNow"))
            ForEach(viewModel.visibleLive) { room in
                GuestRoomCardView(room: room) { onOpen(room) }
            }
        }
        if !viewModel.visibleLater.isEmpty {
            sectionHeader(L10n.t("rooms.section.scheduled"))
                .padding(.top, SLSpacing.sm)
            ForEach(viewModel.visibleLater) { room in
                GuestRoomCardView(room: room) { onOpen(room) }
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(SLFont.micro)
            .slTracking(0.8)
            .foregroundStyle(SLColor.textSecondary)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Card

/// One room, as a guest sees it: the member card less what needs an account.
/// The whole card listens.
@MainActor
struct GuestRoomCardView: View {

    let room: RoomCard
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            SLCard(padding: SLSpacing.md) {
                VStack(alignment: .leading, spacing: SLSpacing.sm) {
                    header
                    Text(room.title)
                        .font(SLFont.bodyEmphasis)
                        .foregroundStyle(SLColor.textPrimary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .slContentDirection(TextDirection.resolve(languageCode: nil, text: room.title))
                    if let question = room.starterQuestion {
                        Label(question, systemImage: "questionmark.bubble")
                            .font(SLFont.caption)
                            .foregroundStyle(SLColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .slContentDirection(TextDirection.resolve(languageCode: nil, text: question))
                    }
                    host
                    chips
                    if room.liveGuestCount > 0 {
                        Label(RoomCopy.guestsListening(room.liveGuestCount), systemImage: "ear")
                            .font(SLFont.micro)
                            .foregroundStyle(SLColor.textSecondary)
                            .accessibilityIdentifier("guest.room.card.guests")
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(Text(accessibilityDescription))
        .accessibilityHint(Text(L10n.t("guest.rooms.card.a11yHint")))
        .accessibilityIdentifier("guest.room.card")
    }

    private var isLive: Bool { room.status == .live }

    private var header: some View {
        HStack(spacing: SLSpacing.sm) {
            HStack(spacing: 4) {
                Circle()
                    .fill(isLive ? SLColor.danger : SLColor.textMuted)
                    .frame(width: 6, height: 6)
                Text(isLive ? L10n.t("rooms.status.live") : L10n.t("rooms.status.soon"))
                    .font(.system(size: 10, weight: .bold))
                    .slTracking(0.6)
                    .foregroundStyle(isLive ? SLColor.danger : SLColor.textMuted)
            }
            .padding(.horizontal, SLSpacing.sm)
            .padding(.vertical, 3)
            .background(Capsule().fill((isLive ? SLColor.danger : SLColor.textMuted).opacity(0.12)))
            Spacer(minLength: 0)
            Text(isLive
                 ? L10n.plural("rooms.attendance.listening", max(room.participantCount, room.metrics.listeners))
                 : RoomCopy.scheduledFor(room.scheduledFor))
                .font(SLFont.micro)
                .foregroundStyle(SLColor.textMuted)
                .lineLimit(1)
        }
    }

    private var host: some View {
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
                .slContentDirection(TextDirection.resolve(languageCode: nil, text: room.host.displayName))
            if room.host.isVerified {
                SLVerifiedBadge(size: 11, isPulsing: false)
            }
            SLCountryBadge(countryCode: room.host.countryCode)
            Spacer(minLength: 0)
        }
    }

    private var chips: some View {
        HStack(spacing: SLSpacing.sm) {
            SLChip(
                room.scopePresentation.label,
                icon: room.scopePresentation.icon,
                accessibilityHint: room.scopePresentation.accessibilityLabel
            )
            if room.isAMA {
                SLChip(L10n.t("rooms.create.ama"), icon: "questionmark.bubble")
            }
            if let topic = room.topicLabel {
                SLChip(topic, icon: "number")
            }
            Spacer(minLength: 0)
        }
    }

    private var accessibilityDescription: String {
        var parts = [room.title, room.scopePresentation.accessibilityLabel]
        parts.append(L10n.t("rooms.card.a11y.hostedBy", room.host.displayName))
        if isLive {
            parts.append(L10n.plural("rooms.attendance.listening", max(room.participantCount, room.metrics.listeners)))
            if room.liveGuestCount > 0 { parts.append(RoomCopy.guestsListening(room.liveGuestCount)) }
        } else {
            parts.append(RoomCopy.scheduledFor(room.scheduledFor))
        }
        return parts.joined(separator: ". ")
    }
}

#Preview("Guest rooms") {
    NavigationStack {
        GuestRoomsScreen(
            viewModel: GuestRoomsViewModel(service: GuestRoomsServiceMock(), analytics: RecordingAnalyticsClient()),
            onOpen: { _ in }
        )
        .tnNavigationBar(title: L10n.t("rooms.nav.title"))
    }
    .preferredColorScheme(.dark)
}
