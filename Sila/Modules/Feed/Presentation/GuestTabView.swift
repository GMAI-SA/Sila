import SwiftUI

/// The app as somebody sees it before they join.
///
/// The same feed, the same cards, the same post pages — reading is genuinely
/// open, because reading is what convinces anybody that this place is worth
/// joining. What is different is that every action is an invitation: the
/// prompt names the thing they just reached for, at the moment they wanted
/// it, and leaves quietly if they would rather keep reading.
///
/// The tabs a guest has no account for — messages, notifications, their own
/// profile — are present but answer with the same invitation, because hiding
/// them would hide what joining is *for*.
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

    public init(container: AppContainer) {
        self.container = container
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
                            onOpenRoom: { _ in ask(.room) }
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
                            onOpenRoom: { _ in ask(.room) },
                            onStub: { _ in ask(.post) }
                        )
                    }
            }
            .tint(SLColor.primary)

            SLTabBar(items: tabs, selection: $selection)
        }
        .tnScreenBackground()
        .onChange(of: selection) { _, tab in
            // The three tabs that need an account invite rather than pretend.
            switch tab {
            case .notifications: ask(.notifications); selection = .home
            case .profile: ask(.profile); selection = .home
            case .rooms: ask(.room); selection = .home
            case .home, .explore: break
            }
        }
        .sheet(item: Binding(
            get: { container.session.joinPrompt },
            set: { container.session.joinPrompt = $0 }
        )) { prompt in
            JoinPromptSheet(
                prompt: prompt,
                onCreateAccount: {
                    container.analytics.track(.guestJoinAccepted, properties: ["prompt": prompt.rawValue, "door": "register"])
                    container.session.leaveGuest()
                    container.router.push(.register)
                },
                onSignIn: {
                    container.analytics.track(.guestJoinAccepted, properties: ["prompt": prompt.rawValue, "door": "signIn"])
                    container.session.leaveGuest()
                    container.router.push(.signIn)
                },
                onDismiss: { container.session.joinPrompt = nil }
            )
            .presentationDetents([.medium])
        }
    }

    @ViewBuilder
    private var content: some View {
        switch selection {
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
                    pinned: viewModel.pinnedSubject,
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
            onOpenRoom: { _ in ask(.room) },
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

    private var tabs: [SLTabBarItem<Tab>] {
        [
            SLTabBarItem(id: "home", icon: "house", selectedIcon: "house.fill",
                         label: L10n.t("feed.tab.home.label"), hint: L10n.t("feed.tab.home.hint"), kind: .tab(.home)),
            SLTabBarItem(id: "explore", icon: "magnifyingglass", selectedIcon: "magnifyingglass",
                         label: L10n.t("feed.tab.explore.label"), hint: L10n.t("feed.tab.explore.hint"), kind: .tab(.explore)),
            SLTabBarItem(id: "rooms", icon: "waveform", selectedIcon: "waveform.circle.fill",
                         label: L10n.t("feed.tab.rooms.label"), hint: L10n.t("guest.tab.locked.hint"), kind: .tab(.rooms)),
            SLTabBarItem(id: "notifications", icon: "bell", selectedIcon: "bell.fill",
                         label: L10n.t("feed.tab.notifications.label"), hint: L10n.t("guest.tab.locked.hint"), kind: .tab(.notifications)),
            SLTabBarItem(id: "profile", icon: "person", selectedIcon: "person.fill",
                         label: L10n.t("feed.tab.profile.label"), hint: L10n.t("guest.tab.locked.hint"), kind: .tab(.profile)),
        ]
    }
}
