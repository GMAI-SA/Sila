import SwiftUI

/// The verified app's shell: five slots, four screens, one honest stub.
///
/// Replaces Phase 1's `FeedPlaceholderScreen` as the destination for
/// ``SessionRoute/feed``. Compose (Phase 4) and Profile (Phase 7) do not exist
/// yet, so they say so out loud rather than pretending — the same contract the
/// wall's "Start Verification" button already honours.
@MainActor
public struct MainTabView: View {

    /// The four selectable destinations. Compose is an action, not a tab.
    public enum Tab: String, Hashable, Sendable, CaseIterable {
        case home, explore, notifications, profile
    }

    private let container: AppContainer
    @State private var selection: Tab = .home
    @State private var viewModel: HomeViewModel
    @State private var exploreViewModel: ExploreViewModel
    /// The Explore tab's own navigation destination. It keeps its own stack so
    /// opening a search result does not disturb the home feed's history.
    @State private var exploreDetailPost: Post?

    /// - Parameter container: The DI root.
    public init(container: AppContainer) {
        self.container = container
        self._viewModel = State(
            initialValue: HomeViewModel(
                service: container.feedService,
                analytics: container.analytics
            )
        )
        self._exploreViewModel = State(
            initialValue: ExploreViewModel(
                search: container.searchService,
                feed: container.feedService,
                analytics: container.analytics
            )
        )
    }

    public var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            TNTabBar(items: tabBarItems, selection: $selection) { id in
                if id == "compose" { openComposer() }
            }
        }
        .tnScreenBackground()
        .sheet(
            item: Binding(
                get: { container.router.presentedComposer },
                set: { container.router.presentedComposer = $0 }
            )
        ) { context in
            ComposerSheetHost { composerViewModel(for: context) }
        }
    }

    // MARK: - Composer

    /// The hook every screen uses to start a composition, or `nil` when Phase 4
    /// is switched off — which is what puts the stub toasts back.
    private var composeHandler: (@MainActor (ComposerContext) -> Void)? {
        guard container.flags.composer else { return nil }
        return { context in
            container.analytics.track(.composerOpened, properties: ["context": context.id])
            container.router.openComposer(context)
        }
    }

    /// Opens the composer, or says why it is not there.
    private func openComposer() {
        guard container.flags.composer else {
            stub("Composing posts")
            return
        }
        container.analytics.track(.composerOpened, properties: ["context": "new"])
        container.router.openComposer(.newPost)
    }

    /// Builds the composer's view model for a presentation.
    ///
    /// Everything it publishes goes somewhere real: the posts land in the feeds
    /// that should hold them, and in the Explore results when they match what
    /// the user is looking at.
    private func composerViewModel(for context: ComposerContext) -> ComposerViewModel {
        ComposerViewModel(
            context: context,
            author: ComposerAuthor(user: container.session.user),
            composer: container.composerService,
            search: container.searchService,
            analytics: container.analytics,
            onPosted: { posted in
                viewModel.insert(newPosts: posted)
                exploreViewModel.insert(posted)
            },
            onClose: { container.router.dismissComposer() }
        )
    }

    // MARK: - Screens

    @ViewBuilder
    private var content: some View {
        switch selection {
        case .home:
            NavigationStack(path: Binding(
                get: { container.router.feedPath },
                set: { container.router.feedPath = $0 }
            )) {
                HomeScreen(
                    viewModel: viewModel,
                    onOpenPost: { container.router.push(FeedRoute.postDetail($0)) },
                    onStub: stub,
                    onCompose: composeHandler
                )
                .tnNavigationBar(title: "TrustNet")
                .navigationDestination(for: FeedRoute.self) { route in
                    destination(for: route)
                }
            }
            .tint(TNColor.primary)

        case .explore:
            NavigationStack {
                ExploreScreen(
                    viewModel: exploreViewModel,
                    onOpenPost: { post in exploreDetailPost = post },
                    onStub: stub,
                    onCompose: composeHandler
                )
                .tnNavigationBar(title: "Explore")
                .navigationDestination(item: $exploreDetailPost) { post in
                    detail(
                        for: post,
                        // Engagement changed on a search result's detail screen
                        // must not be lost when the user swipes back.
                        onDismiss: { updated in
                            exploreViewModel.merge(updated)
                            viewModel.merge(updated)
                        }
                    )
                }
            }
            .tint(TNColor.primary)

        case .notifications:
            NotificationsScreen(onStub: stub)

        case .profile:
            ProfileStubScreen(
                user: container.session.user,
                onStub: stub,
                onSignOut: {
                    container.router.popFeedToRoot()
                    Task { await container.session.signOut() }
                }
            )
        }
    }

    @ViewBuilder
    private func destination(for route: FeedRoute) -> some View {
        switch route {
        case let .postDetail(post):
            // Engagement changed on the detail screen must not be lost when the
            // user swipes back to a feed still holding the old copy.
            detail(for: post, onDismiss: { viewModel.merge($0) })
        }
    }

    /// A post's thread, with the reply bar wired to Phase 4 when it is on.
    private func detail(
        for post: Post,
        onDismiss: @escaping @MainActor (Post) -> Void
    ) -> some View {
        PostDetailScreen(
            viewModel: PostDetailViewModel(
                post: post,
                service: container.feedService,
                analytics: container.analytics
            ),
            onOpenPost: { container.router.push(FeedRoute.postDetail($0)) },
            onStub: stub,
            onDismiss: onDismiss,
            // `nil` when the phase is off, which restores the Phase-3 stub bar.
            composerService: container.flags.composer ? container.composerService : nil,
            searchService: container.flags.composer ? container.searchService : nil,
            author: ComposerAuthor(user: container.session.user),
            analytics: container.analytics,
            onCompose: composeHandler
        )
    }

    // MARK: - Tab bar

    private var tabBarItems: [TNTabBarItem<Tab>] {
        [
            TNTabBarItem(
                id: "home", icon: "house", selectedIcon: "house.fill",
                label: "Home", hint: "Shows your four feeds", kind: .tab(.home)
            ),
            TNTabBarItem(
                id: "explore", icon: "magnifyingglass", selectedIcon: "magnifyingglass",
                label: "Explore", hint: "Search posts and people, and see what is trending", kind: .tab(.explore)
            ),
            TNTabBarItem(
                id: "compose", icon: "plus",
                label: "Post",
                hint: container.flags.composer
                    ? "Opens the composer"
                    : "Writing posts arrives in a later release",
                kind: .action
            ),
            TNTabBarItem(
                id: "notifications", icon: "bell", selectedIcon: "bell.fill",
                label: "Alerts", hint: "Your notifications, coming in a later release", kind: .tab(.notifications)
            ),
            TNTabBarItem(
                id: "profile", icon: "person", selectedIcon: "person.fill",
                label: "Profile", hint: "Your account", kind: .tab(.profile)
            )
        ]
    }

    /// Announces a feature that belongs to a later phase, exactly the way the
    /// verification wall's stub does: record the intent, tell the user plainly.
    private func stub(_ feature: String) {
        container.analytics.track(.featureStubShown, properties: ["feature": feature])
        container.router.show(.info("\(feature) arrives in a later release."))
    }
}

/// The Profile tab until Phase 7 builds the real thing.
///
/// It carries the only affordance a user genuinely needs here today — signing
/// out — and does not invent follower counts or a bio.
@MainActor
struct ProfileStubScreen: View {

    let user: AuthUser?
    let onStub: @MainActor (String) -> Void
    let onSignOut: () -> Void

    var body: some View {
        VStack(spacing: TNSpacing.lg) {
            Spacer()

            TNAvatar(
                initials: user?.initials ?? "TN",
                size: .xl,
                isVerified: user?.verificationStatus == .verified,
                displayName: user?.displayName ?? user?.email
            )

            VStack(spacing: TNSpacing.xs) {
                Text(user?.displayName ?? "Your account")
                    .font(TNFont.displayM)
                    .foregroundStyle(TNColor.textPrimary)

                if let email = user?.email {
                    Text(email)
                        .font(TNFont.mono)
                        .foregroundStyle(TNColor.textMuted)
                        .accessibilityLabel(Text("Signed in as \(email)"))
                }

                if user?.verificationStatus == .verified {
                    TNBadge("Verified", style: .verified, icon: "checkmark.seal.fill")
                }
            }

            TNEmptyState(
                icon: "person.crop.square",
                title: "Profiles arrive later",
                subtitle: "Your handle, country flag, bio, follower counts and post history land with the profile release. Nothing here is guessed in the meantime.",
                tint: TNColor.textSecondary,
                actionTitle: "Tell me when it lands",
                action: { onStub("Profiles") }
            )
            .padding(.horizontal, TNSpacing.lg)

            TNButton(
                "Sign out",
                variant: .ghost,
                size: .compact,
                accessibilityHint: "Ends your session and returns to the welcome screen",
                action: onSignOut
            )
            .padding(.horizontal, TNSpacing.xxl)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .tnScreenBackground()
    }
}

#Preview("MainTabView") {
    MainTabView(container: AppContainer.preview(scenario: .verified))
        .preferredColorScheme(.dark)
}
