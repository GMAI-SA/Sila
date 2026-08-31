import SwiftUI

/// The Rooms tab: what is live now, what is coming, and a way to search both.
///
/// Two things here are load-bearing rather than stylistic.
///
/// **Every room is listed to everybody.** A room the viewer cannot speak in
/// appears exactly as prominently as one they can, because the scope decides
/// who may *speak* and never who may listen. Filtering the list by speaking
/// rights would quietly turn Sila into a set of walled gardens, which is the
/// opposite of what verifying an identity is for.
///
/// **A row that cannot be spoken in says so, in the server's words.** The chip
/// carries the room's audience and the row carries ``VoiceRoom/speakRefusal``
/// verbatim. Nothing on this screen re-derives the rule from a country code.
@MainActor
public struct RoomsScreen: View {

    @Bindable private var viewModel: RoomsViewModel
    private let onOpen: (@MainActor (RoomJoin) -> Void)?
    private let onCreate: (@MainActor () -> Void)?
    private let onOpenProfile: (@MainActor (String) -> Void)?

    @FocusState private var isSearchFocused: Bool

    /// - Parameters:
    ///   - viewModel: Owns both lists, the query and the join.
    ///   - onOpen: Pushes the in-room screen with a join already in hand.
    ///   - onCreate: Opens the create sheet. `nil` hides the affordance.
    ///   - onOpenProfile: Opens a host's page.
    public init(
        viewModel: RoomsViewModel,
        onOpen: (@MainActor (RoomJoin) -> Void)? = nil,
        onCreate: (@MainActor () -> Void)? = nil,
        onOpenProfile: (@MainActor (String) -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.onOpen = onOpen
        self.onCreate = onCreate
        self.onOpenProfile = onOpenProfile
    }

    public var body: some View {
        VStack(spacing: 0) {
            searchField
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .tnScreenBackground()
        .tnNavigationBar(title: "Rooms")
        .toolbar {
            if let onCreate {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: onCreate) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(SLColor.primary)
                    }
                    .accessibilityLabel(Text(RoomCopy.createTitle))
                    .accessibilityHint(Text(RoomCopy.createExplanation))
                }
            }
        }
        .task { await viewModel.load() }
        .tnToast($viewModel.toast)
    }

    // MARK: - Search

    private var searchField: some View {
        HStack(spacing: SLSpacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(SLColor.textMuted)

            TextField(
                "",
                text: Binding(
                    get: { viewModel.query },
                    set: { viewModel.updateQuery($0) }
                ),
                prompt: Text("Search rooms").foregroundStyle(SLColor.textMuted)
            )
            .font(SLFont.body)
            .foregroundStyle(SLColor.textPrimary)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.search)
            .focused($isSearchFocused)
            .onSubmit { viewModel.updateQuery(viewModel.query, immediately: true) }
            .accessibilityLabel(Text("Search rooms"))
            .accessibilityHint(Text("Searches room titles and topics, live and scheduled"))

            if viewModel.isSearchActive {
                Button {
                    viewModel.clearSearch()
                    isSearchFocused = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(SLColor.textMuted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Clear search"))
            }
        }
        .padding(.horizontal, SLSpacing.md)
        .padding(.vertical, SLSpacing.sm)
        .background(
            RoundedRectangle(cornerRadius: SLRadius.md).fill(SLColor.surface1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: SLRadius.md).strokeBorder(SLColor.stroke, lineWidth: 1)
        )
        .padding(.horizontal, SLSpacing.lg)
        .padding(.vertical, SLSpacing.sm)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading && !viewModel.hasLoaded {
            loadingState
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: SLSpacing.md) {
                    // The promise, once, at the top of the tab. It belongs
                    // where somebody decides whether to walk into a room, not
                    // in a settings screen they will never open.
                    notRecordedBanner

                    switch viewModel.emptyKind {
                    case .none:
                        rooms
                    case .noRooms:
                        SLEmptyState(
                            icon: "mic.slash",
                            title: RoomCopy.emptyLiveTitle,
                            subtitle: RoomCopy.emptyLiveSubtitle,
                            tint: SLColor.textSecondary,
                            actionTitle: onCreate == nil ? nil : RoomCopy.createTitle,
                            action: onCreate.map { handler in { handler() } }
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
                    case .queryTooShort:
                        SLEmptyState(
                            icon: "character.cursor.ibeam",
                            title: RoomCopy.searchTooShortTitle,
                            subtitle: RoomCopy.searchTooShortSubtitle,
                            tint: SLColor.textSecondary
                        )
                        .padding(.top, SLSpacing.xl)
                    case let .failed(message):
                        SLEmptyState(
                            icon: "wifi.exclamationmark",
                            title: "Couldn't load rooms",
                            subtitle: message,
                            tint: SLColor.danger,
                            actionTitle: "Try again",
                            action: { Task { await viewModel.reload() } }
                        )
                        .padding(.top, SLSpacing.xl)
                    }
                }
                .padding(.horizontal, SLSpacing.lg)
                .padding(.bottom, SLSpacing.xl)
            }
            .refreshable { await viewModel.reload(isRefresh: true) }
        }
    }

    private var notRecordedBanner: some View {
        HStack(spacing: SLSpacing.sm) {
            Image(systemName: "waveform.slash")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(SLColor.secondary)
            Text(RoomCopy.neverRecorded)
                .font(SLFont.micro)
                .foregroundStyle(SLColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(SLSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: SLRadius.md).fill(SLColor.secondary.opacity(0.08)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(RoomCopy.neverRecorded))
    }

    @ViewBuilder
    private var rooms: some View {
        if !viewModel.visibleLive.isEmpty {
            sectionHeader(viewModel.isSearchActive ? "Results" : "Live now")
            ForEach(viewModel.visibleLive) { room in
                RoomCardView(
                    room: room,
                    isOpening: viewModel.isOpening(room),
                    onTap: { open(room) },
                    onOpenHost: onOpenProfile.map { handler in { handler(room.host.handle) } }
                )
            }
        }

        if !viewModel.visibleScheduled.isEmpty {
            sectionHeader("Scheduled")
                .padding(.top, SLSpacing.sm)
            ForEach(viewModel.visibleScheduled) { room in
                RoomCardView(
                    room: room,
                    isOpening: viewModel.isOpening(room),
                    onTap: { open(room) },
                    onOpenHost: onOpenProfile.map { handler in { handler(room.host.handle) } }
                )
            }
        }

        if viewModel.isSearching {
            SLSkeletonRow(lineCount: 2)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(SLFont.micro)
            .tracking(0.8)
            .foregroundStyle(SLColor.textSecondary)
            .accessibilityAddTraits(.isHeader)
    }

    private var loadingState: some View {
        VStack(spacing: SLSpacing.lg) {
            ForEach(0..<4, id: \.self) { _ in
                SLSkeletonRow(lineCount: 3).padding(.horizontal, SLSpacing.lg)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, SLSpacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel(Text("Loading rooms"))
    }

    private func open(_ room: VoiceRoom) {
        Task {
            guard let join = await viewModel.open(room) else { return }
            onOpen?(join)
        }
    }
}

// MARK: - Card

/// One room in the list.
///
/// The refusal line is the interesting part. It is present whenever the server
/// said the viewer cannot speak, and it is the **server's sentence**, not a
/// paraphrase — so the day the backend adds a scope this build has never heard
/// of, the row still explains itself correctly.
@MainActor
struct RoomCardView: View {

    let room: VoiceRoom
    let isOpening: Bool
    let onTap: () -> Void
    var onOpenHost: (() -> Void)?

    var body: some View {
        SLCard(padding: SLSpacing.md) {
            VStack(alignment: .leading, spacing: SLSpacing.sm) {
                header

                Text(room.title)
                    .font(SLFont.bodyEmphasis)
                    .foregroundStyle(SLColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)

                host

                chips

                if let refusal = room.speakRefusalMessage, room.status == .live {
                    // Verbatim. Never rewritten, never shortened.
                    Label(refusal, systemImage: "ear")
                        .font(SLFont.micro)
                        .foregroundStyle(SLColor.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(Text(room.accessibilityDescription))
        .accessibilityHint(Text(
            room.status.isJoinable
                ? "Opens the room. Anyone can listen."
                : "This room isn't open yet."
        ))
    }

    private var header: some View {
        HStack(spacing: SLSpacing.sm) {
            statusPill
            Spacer(minLength: 0)
            if isOpening {
                ProgressView()
                    .controlSize(.small)
                    .tint(SLColor.primary)
                    .accessibilityHidden(true)
            } else if room.status == .live {
                Text(room.attendanceSummary)
                    .font(SLFont.micro)
                    .foregroundStyle(SLColor.textMuted)
            } else if room.status == .scheduled {
                Text(RoomCopy.scheduledFor(room.scheduledFor))
                    .font(SLFont.micro)
                    .foregroundStyle(SLColor.textMuted)
                    .lineLimit(1)
            }
        }
    }

    private var statusPill: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(room.status == .live ? SLColor.danger : SLColor.textMuted)
                .frame(width: 6, height: 6)
            Text(room.status == .live ? "LIVE" : room.status == .scheduled ? "SOON" : "ENDED")
                .font(.system(size: 10, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(room.status == .live ? SLColor.danger : SLColor.textMuted)
        }
        .padding(.horizontal, SLSpacing.sm)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(
                (room.status == .live ? SLColor.danger : SLColor.textMuted).opacity(0.12)
            )
        )
        .accessibilityHidden(true)
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
            if room.host.isVerified {
                SLVerifiedBadge(size: 11, isPulsing: false)
            }
            SLCountryBadge(countryCode: room.host.countryCode)
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture { onOpenHost?() }
    }

    private var chips: some View {
        HStack(spacing: SLSpacing.sm) {
            SLChip(
                room.scopePresentation.label,
                icon: room.scopePresentation.icon,
                accessibilityHint: room.scopePresentation.accessibilityLabel
            )
            if let topic = room.topicLabel {
                SLChip(topic, icon: "number")
            }
            Spacer(minLength: 0)
        }
    }
}

#Preview("Rooms — populated") {
    NavigationStack {
        RoomsScreen(
            viewModel: RoomsViewModel(
                service: RoomsServiceMock(scenario: .populated),
                analytics: RecordingAnalyticsClient()
            ),
            onCreate: {}
        )
    }
    .preferredColorScheme(.dark)
}

#Preview("Rooms — empty") {
    NavigationStack {
        RoomsScreen(
            viewModel: RoomsViewModel(
                service: RoomsServiceMock(scenario: .empty),
                analytics: RecordingAnalyticsClient()
            ),
            onCreate: {}
        )
    }
    .preferredColorScheme(.dark)
}
