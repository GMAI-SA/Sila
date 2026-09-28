import SwiftUI

/// The app as somebody sees it before they join.
///
/// The same feed, the same cards, the same post pages — reading is genuinely
/// open, because reading is what convinces anybody that this place is worth
/// joining. What is different is that every action is an invitation: the
/// prompt names the thing they just reached for, at the moment they wanted
/// it, and leaves quietly if they would rather keep reading.
///
/// The tabs a guest has no account for — notifications, their own profile —
/// are present but answer with the same invitation, because hiding them
/// would hide what joining is *for*. Rooms is not one of them any more
/// (contract v31, owner request 2026-09-28): a guest lists the rooms open to
/// guests and listens to any of them, and only taking part is an invitation.
@MainActor
public struct GuestTabView: View {

    public enum Tab: String, Hashable, Sendable, CaseIterable {
        case home, explore, rooms, notifications, profile
    }

    private let container: AppContainer
    @State private var selection: Tab = .home
    @State private var viewModel: HomeViewModel
    @State private var hashtag: String?
    @State private var openPost: Post?
    /// A tag tapped on a public card: the explainer, read from the card's
    /// own data (contract v24 §3.7). No "See @aziz" — a profile needs an
    /// account, and the explainer already says who.
    @State private var vouchSelection: VouchTagSelection?
    /// The rooms a guest may open (contract v31).
    @State private var roomsViewModel: GuestRoomsViewModel
    /// The room being listened to, pushed like any screen. A connection, not
    /// a document: it closes when it is popped.
    @State private var openRoom: GuestRoomRoute?

    public init(container: AppContainer) {
        self.container = container
        self._roomsViewModel = State(
            initialValue: GuestRoomsViewModel(service: container.guestRoomsService, analytics: container.analytics)
        )
        self._viewModel = State(
            initialValue: HomeViewModel(
                service: container.publicFeedService,
                analytics: container.analytics,
                initialTab: .international,
                // A guest gets the vocabulary but none of the opinions: there
                // is no account yet to have hidden anything. Nothing is
                // remembered between launches for the same reason.
                subjects: GuestSubjects(container.publicTopics)
            )
        )
    }

    public var body: some View {
        VStack(spacing: 0) {
            GuestBanner(onJoin: { ask(.post) })

            NavigationStack {
                content
                    .navigationDestination(item: $openPost) { post in
                        PostDetailScreen(
                            viewModel: PostDetailViewModel(
                                post: post,
                                service: container.publicFeedService,
                                analytics: container.analytics
                            ),
                            onOpenPost: { openPost = $0 },
                            onStub: { _ in ask(.post) },
                            onOpenProfile: { _ in ask(.profile) },
                            onOpenHashtag: { tag in hashtag = tag },
                            onOpenRoom: { card in listen(to: card) }
                        )
                    }
                    .navigationDestination(item: $hashtag) { tag in
                        HashtagScreen(
                            viewModel: HashtagViewModel(
                                tag: tag,
                                service: container.publicFeedService,
                                analytics: container.analytics
                            ),
                            onOpenPost: { openPost = $0 },
                            onOpenProfile: { _ in ask(.profile) },
                            onOpenHashtag: { hashtag = $0 },
                            onOpenRoom: { card in listen(to: card) },
                            onStub: { _ in ask(.post) }
                        )
                    }
                    .navigationDestination(item: $openRoom) { route in
                        guestRoom(route)
                    }
            }
            .tint(SLColor.primary)
            .environment(\.vouchTagAction, VouchTagAction { person in
                vouchSelection = VouchTagSelection(person: person, viewerId: nil)
                if vouchSelection != nil {
                    container.analytics.track(.vouchTagOpened, properties: ["source": "guest"])
                }
            })

            SLTabBar(items: tabs, selection: $selection)
        }
        .tnScreenBackground()
        .sheet(item: $vouchSelection) { tapped in
            VouchExplainerSheet(
                person: tapped.person,
                vouchedBy: tapped.vouchedBy,
                isOwn: false,
                onSeeVoucher: nil,
                onVerify: nil,
                onClose: { vouchSelection = nil }
            )
        }
        .onChange(of: selection) { previous, tab in
            // The two tabs that need an account invite rather than pretend.
            switch tab {
            case .notifications: ask(.notifications); selection = previous
            case .profile: ask(.profile); selection = previous
            case .rooms where !container.flags.rooms: ask(.room); selection = previous
            case .home, .explore, .rooms: break
            }
            // A room is left when its tab is: the connection goes with it.
            if tab == .home || tab == .explore { openRoom = nil }
        }
        // A shared room link (sila.gmai.sa/rooms/…): a guest listens to it at
        // once, as somebody signed out does (contract v31).
        .task { openPendingRoomLink() }
        .onChange(of: container.router.pendingLink) { _, _ in openPendingRoomLink() }
        .sheet(item: Binding(
            get: { container.session.joinPrompt },
            set: { container.session.joinPrompt = $0 }
        )) { prompt in
            JoinPromptSheet(
                prompt: prompt,
                onCreateAccount: { enter(.register, from: prompt) },
                onSignIn: { enter(.signIn, from: prompt) },
                onDismiss: { container.session.joinPrompt = nil }
            )
            .presentationDetents([.medium])
        }
    }

    @ViewBuilder
    private var content: some View {
        switch selection {
        case .rooms where container.flags.rooms:
            GuestRoomsScreen(viewModel: roomsViewModel, onOpen: { card in listen(to: card) })
                .tnNavigationBar(title: L10n.t("rooms.nav.title"))
        case .explore:
            // Search needs an account; the square is what a guest explores.
            feed.tnNavigationBar(title: L10n.t("guest.feed.title"))
        default:
            feed.tnNavigationBar(title: L10n.t("guest.feed.title"))
        }
    }

    private var feed: some View {
        VStack(spacing: 0) {
            if !viewModel.subjects.isEmpty {
                SubjectStrip(
                    subjects: viewModel.subjects,
                    pinned: viewModel.pinnedSubjects,
                    // The preferences screen belongs to an account; a guest
                    // narrows the timeline with the strip alone.
                    onOpenPreferences: nil,
                    onSelect: { subject in Task { await viewModel.pin(subject) } }
                )
            }
            posts
        }
        .task { await viewModel.loadSubjectsIfNeeded() }
    }

    private var posts: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(viewModel.state(for: .international).posts) { post in
                    PostCardView(post: post, actions: actions(for: post))
                        .task { await viewModel.loadMoreIfNeeded(currentPost: post, tab: .international) }
                    SLDivider()
                }
                if viewModel.state(for: .international).isLoading {
                    ProgressView().tint(SLColor.primary).padding(SLSpacing.xl)
                } else if viewModel.state(for: .international).posts.isEmpty,
                          let subject = viewModel.pinnedSubjectLabel {
                    SLEmptyState(
                        icon: "line.3.horizontal.decrease.circle",
                        title: L10n.t("feed.subject.empty.title", subject),
                        subtitle: L10n.t("feed.subject.empty.subtitle"),
                        tint: SLColor.textSecondary,
                        actionTitle: L10n.t("feed.subject.empty.action"),
                        action: { Task { await viewModel.pin(nil) } }
                    )
                    .padding(.horizontal, SLSpacing.lg)
                    .padding(.top, SLSpacing.xxl)
                }
            }
        }
        .refreshable { await viewModel.refresh(.international) }
        .task { await viewModel.loadIfNeeded(.international) }
    }

    private func actions(for post: Post) -> PostCardActions {
        PostCardActions(
            onOpen: { openPost = $0 },
            onLike: { _ in ask(.like) },
            onRepost: { _ in ask(.repost) },
            onBookmark: { _ in ask(.bookmark) },
            onReply: { _ in ask(.reply) },
            onReplyBlocked: { _ in ask(.reply) },
            onQuote: { _ in ask(.repost) },
            onMention: { _ in ask(.profile) },
            onHashtag: { tag in hashtag = tag },
            onOpenRoom: { card in listen(to: card) },
            onOpenQuoted: { openPost = $0 },
            onOpenAuthor: { _ in ask(.profile) },
            onStub: { _ in ask(.post) }
        )
    }

    /// Invites, and records what they were reaching for.
    private func ask(_ prompt: JoinPrompt) {
        container.analytics.track(.guestJoinPromptShown, properties: ["prompt": prompt.rawValue])
        container.session.joinPrompt = prompt
    }

    /// Through one of the two doors. A guest listening in a room comes back
    /// to it once signed in: the room waits on the router as a link would,
    /// and the member's Rooms tab opens it (contract v31).
    private func enter(_ door: AuthRoute, from prompt: JoinPrompt) {
        container.analytics.track(.guestJoinAccepted, properties: [
            "prompt": prompt.rawValue, "door": door == .register ? "register" : "signIn"
        ])
        if let room = openRoom {
            container.router.pendingLink = .room(id: room.id)
        }
        container.session.leaveGuest()
        container.router.push(door)
    }

    // MARK: - Rooms (contract v31)

    /// Listens to a room: the Rooms tab, with the room open on it.
    private func listen(to card: RoomCard) {
        guard container.flags.rooms else { return ask(.room) }
        selection = .rooms
        openRoom = GuestRoomRoute(id: card.id, card: card)
    }

    /// A room link waiting on the router, taken while this shell is the one
    /// on screen — never after the guest has left it for a door, where the
    /// link is the way back into the room once signed in.
    private func openPendingRoomLink() {
        guard container.flags.rooms, container.session.route == .guest,
              case let .room(id)? = container.router.pendingLink else { return }
        container.router.pendingLink = nil
        selection = .rooms
        openRoom = GuestRoomRoute(id: id, card: nil)
    }

    private func guestRoom(_ route: GuestRoomRoute) -> some View {
        Owned({
            GuestRoomViewModel(
                roomId: route.id,
                card: route.card,
                service: container.guestRoomsService,
                passes: container.guestPasses,
                // One engine per connection, built never to ask for the
                // microphone.
                makeEngine: { container.makeGuestVoiceEngine() },
                analytics: container.analytics
            )
        }) { viewModel in
            GuestRoomScreen(
                viewModel: viewModel,
                onLeave: {
                    openRoom = nil
                    // The counts on the list behind are a minute old.
                    Task { await roomsViewModel.load() }
                },
                onAsk: { prompt in ask(prompt) },
                onCreateAccount: { enter(.register, from: .room) },
                onSignIn: { enter(.signIn, from: .room) }
            )
        }
        .id(route.id)
    }

    private var tabs: [SLTabBarItem<Tab>] {
        [
            SLTabBarItem(id: "home", icon: "house", selectedIcon: "house.fill",
                         label: L10n.t("feed.tab.home.label"), hint: L10n.t("feed.tab.home.hint"), kind: .tab(.home)),
            SLTabBarItem(id: "explore", icon: "magnifyingglass", selectedIcon: "magnifyingglass",
                         label: L10n.t("feed.tab.explore.label"), hint: L10n.t("feed.tab.explore.hint"), kind: .tab(.explore)),
            SLTabBarItem(id: "rooms", icon: "waveform", selectedIcon: "waveform.circle.fill",
                         label: L10n.t("feed.tab.rooms.label"),
                         hint: container.flags.rooms ? L10n.t("guest.rooms.tab.hint") : L10n.t("guest.tab.locked.hint"),
                         kind: .tab(.rooms)),
            SLTabBarItem(id: "notifications", icon: "bell", selectedIcon: "bell.fill",
                         label: L10n.t("feed.tab.notifications.label"), hint: L10n.t("guest.tab.locked.hint"), kind: .tab(.notifications)),
            SLTabBarItem(id: "profile", icon: "person", selectedIcon: "person.fill",
                         label: L10n.t("feed.tab.profile.label"), hint: L10n.t("guest.tab.locked.hint"), kind: .tab(.profile)),
        ]
    }
}

/// A room a guest is listening to: its id, and the card the tap came from
/// when it came from one (a shared link brings only the id).
struct GuestRoomRoute: Identifiable, Hashable {
    let id: UUID
    let card: RoomCard?
}
