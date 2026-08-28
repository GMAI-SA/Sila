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
    /// `true` while the feed-preferences sheet is up. A sheet rather than a
    /// push, because both entry points (Profile and the International feed)
    /// live in different navigation stacks.
    @State private var isShowingPreferences = false
    /// `true` while account settings are up.
    @State private var isShowingAccount = false

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

            SLTabBar(items: tabBarItems, selection: $selection) { id in
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
        .sheet(isPresented: $isShowingPreferences) {
            NavigationStack {
                PreferencesScreen(
                    viewModel: preferencesViewModel(),
                    onClose: { isShowingPreferences = false }
                )
            }
            .tint(SLColor.primary)
        }
        .sheet(isPresented: $isShowingAccount) {
            NavigationStack {
                AccountScreen(
                    viewModel: accountViewModel(),
                    onClose: { isShowingAccount = false }
                )
            }
            .tint(SLColor.primary)
        }
    }

    // MARK: - Account

    /// Opens account settings, or `nil` when the flag is off — which hides the
    /// affordance rather than showing one that goes nowhere.
    private var accountHandler: (@MainActor () -> Void)? {
        guard container.flags.account else { return nil }
        return {
            container.analytics.track(.accountOpened)
            isShowingAccount = true
        }
    }

    /// Builds the account view model for a presentation.
    ///
    /// Fresh each time, so the screen always opens on the server's current state
    /// — which matters more here than anywhere else, because a stale copy could
    /// show a deleted account as healthy.
    private func accountViewModel() -> AccountViewModel {
        AccountViewModel(
            service: container.accountService,
            analytics: container.analytics,
            onSignOut: {
                isShowingAccount = false
                container.router.popFeedToRoot()
                Task { await container.session.signOut() }
            }
        )
    }

    // MARK: - Preferences

    /// The hook both entry points use, or `nil` when the flag is off — which is
    /// what hides the affordance rather than showing one that goes nowhere.
    private var preferencesHandler: (@MainActor () -> Void)? {
        guard container.flags.preferences else { return nil }
        return {
            container.analytics.track(.preferencesOpened)
            isShowingPreferences = true
        }
    }

    /// Builds the preferences view model for a presentation.
    ///
    /// A fresh one each time, so the screen always opens on the server's
    /// current state rather than on a draft left behind by an earlier visit.
    private func preferencesViewModel() -> PreferencesViewModel {
        PreferencesViewModel(
            service: container.preferencesService,
            analytics: container.analytics,
            onFilteringChanged: {
                // `GET /feed/international` applies these server-side, so the
                // page already on screen was chosen under the old settings.
                Task { await viewModel.invalidateInternationalFeed() }
            }
        )
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
                    onCompose: composeHandler,
                    onOpenPreferences: preferencesHandler
                )
                .tnNavigationBar(title: "Sila")
                .navigationDestination(for: FeedRoute.self) { route in
                    destination(for: route)
                }
            }
            .tint(SLColor.primary)

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
            .tint(SLColor.primary)

        case .notifications:
            NotificationsScreen(onStub: stub)

        case .profile:
            ProfileStubScreen(
                user: container.session.user,
                onStub: stub,
                onOpenPreferences: preferencesHandler,
                onOpenAccount: accountHandler,
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

    private var tabBarItems: [SLTabBarItem<Tab>] {
        [
            SLTabBarItem(
                id: "home", icon: "house", selectedIcon: "house.fill",
                label: "Home", hint: "Shows your four feeds", kind: .tab(.home)
            ),
            SLTabBarItem(
                id: "explore", icon: "magnifyingglass", selectedIcon: "magnifyingglass",
                label: "Explore", hint: "Search posts and people, and see what is trending", kind: .tab(.explore)
            ),
            SLTabBarItem(
                id: "compose", icon: "plus",
                label: "Post",
                hint: container.flags.composer
                    ? "Opens the composer"
                    : "Writing posts arrives in a later release",
                kind: .action
            ),
            SLTabBarItem(
                id: "notifications", icon: "bell", selectedIcon: "bell.fill",
                label: "Alerts", hint: "Your notifications, coming in a later release", kind: .tab(.notifications)
            ),
            SLTabBarItem(
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
/// It carries the affordances a user genuinely needs here today — feed
/// preferences and signing out — and does not invent follower counts or a bio.
@MainActor
struct ProfileStubScreen: View {

    let user: AuthUser?
    let onStub: @MainActor (String) -> Void
    /// Opens feed preferences, or `nil` when the flag is off.
    var onOpenPreferences: (@MainActor () -> Void)?
    /// Opens account settings, or `nil` when the flag is off.
    var onOpenAccount: (@MainActor () -> Void)?
    let onSignOut: () -> Void

    var body: some View {
        ScrollView {
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .tnScreenBackground()
    }

    private var content: some View {
        VStack(spacing: SLSpacing.lg) {
            Spacer(minLength: SLSpacing.xl)

            SLAvatar(
                initials: user?.initials ?? "TN",
                size: .xl,
                isVerified: user?.verificationStatus == .verified,
                displayName: user?.displayName ?? user?.email
            )

            VStack(spacing: SLSpacing.xs) {
                Text(user?.displayName ?? "Your account")
                    .font(SLFont.displayM)
                    .foregroundStyle(SLColor.textPrimary)

                if let email = user?.email {
                    Text(email)
                        .font(SLFont.mono)
                        .foregroundStyle(SLColor.textMuted)
                        .accessibilityLabel(Text("Signed in as \(email)"))
                }

                if user?.verificationStatus == .verified {
                    SLBadge("Verified", style: .verified, icon: "checkmark.seal.fill")
                }
            }

            if let onOpenAccount {
                settingsEntry(
                    icon: "person.text.rectangle",
                    title: "Account",
                    detail: "Your name, handle, picture, email, password — and how to "
                        + "download or delete everything.",
                    hint: "Opens your profile details, sign-in credentials, data export "
                        + "and account deletion",
                    open: onOpenAccount
                )
                .padding(.horizontal, SLSpacing.lg)
            }

            if let onOpenPreferences {
                settingsEntry(
                    icon: "slider.horizontal.3",
                    title: "Feed preferences",
                    detail: "Topics, muted topics and muted countries — and how posts get labelled.",
                    hint: "Opens topic interests, muted topics and muted countries, and "
                        + "explains how posts are labelled",
                    open: onOpenPreferences
                )
                .padding(.horizontal, SLSpacing.lg)
            }

            SLEmptyState(
                icon: "person.crop.square",
                title: "Profiles arrive later",
                subtitle: "Your public profile page — follower counts, post history and how others see you — lands with the profile release. Your name, handle, bio and picture are editable now under Account. Nothing here is guessed in the meantime.",
                tint: SLColor.textSecondary,
                actionTitle: "Tell me when it lands",
                action: { onStub("Profiles") }
            )
            .padding(.horizontal, SLSpacing.lg)

            SLButton(
                "Sign out",
                variant: .ghost,
                size: .compact,
                accessibilityHint: "Ends your session and returns to the welcome screen",
                action: onSignOut
            )
            .padding(.horizontal, SLSpacing.xxl)

            Spacer(minLength: SLSpacing.xl)
        }
        .frame(maxWidth: .infinity)
    }

    /// One route into a settings screen.
    ///
    /// A full-width card rather than a line of small print. Feed preferences is
    /// where the automatic topic labelling is disclosed and Account is where
    /// deletion and the data export live, so both have to be findable by someone
    /// who does not already know they exist.
    private func settingsEntry(
        icon: String,
        title: String,
        detail: String,
        hint: String,
        open: @escaping @MainActor () -> Void
    ) -> some View {
        SLCard(accessibilityLabel: title, accessibilityHint: hint, onTap: open) {
            HStack(spacing: SLSpacing.md) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(SLColor.primary)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(SLFont.bodyEmphasis)
                        .foregroundStyle(SLColor.textPrimary)

                    Text(detail)
                        .font(SLFont.caption)
                        .foregroundStyle(SLColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SLColor.textMuted)
            }
        }
    }
}

#Preview("MainTabView") {
    MainTabView(container: AppContainer.preview(scenario: .verified))
        .preferredColorScheme(.dark)
}
