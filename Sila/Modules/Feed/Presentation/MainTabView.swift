import SwiftUI

/// The verified app's shell: five slots, four screens.
///
/// Replaces Phase 1's `FeedPlaceholderScreen` as the destination for
/// ``SessionRoute/feed``. Notifications is the last surface with no backend
/// behind it, and it says so out loud rather than pretending — the same
/// contract the wall's "Start Verification" button already honours.
///
/// Each tab owns its own navigation stack, and all three carry the same
/// ``FeedRoute`` cases: a post leads to its author, whose timeline leads to
/// another post. Pushing that chain onto the tab it started in is what stops
/// Explore from rearranging the history the home feed is holding.
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
    /// `true` while the feed-preferences sheet is up. A sheet rather than a
    /// push, because both entry points (Profile and the International feed)
    /// live in different navigation stacks.
    @State private var isShowingPreferences = false
    /// `true` while account settings are up.
    @State private var isShowingAccount = false
    /// `true` while the blocked / muted / reported lists are up.
    @State private var isShowingSafety = false
    /// Blocking, muting and reporting for every card and every header below.
    ///
    /// One instance for the whole shell rather than one per screen. The block
    /// confirmation has to survive the card it was opened from disappearing —
    /// which is exactly what a block does to it — and a menu on a profile must
    /// already know about a block taken on a post two screens ago.
    @State private var safety: SafetyViewModel

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
        // `onChange` is wired after construction, because it has to reach the
        // two view models built just above.
        self._safety = State(
            initialValue: SafetyViewModel(
                service: container.safetyService,
                analytics: container.analytics,
                suspension: container.suspension,
                viewerHandle: container.session.user?.handle
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
        .sheet(isPresented: $isShowingSafety) {
            NavigationStack {
                SafetyListsScreen(
                    viewModel: safetyListsViewModel(),
                    onClose: { isShowingSafety = false },
                    onOpenProfile: { handle in
                        isShowingSafety = false
                        openProfile(handle)
                    }
                )
            }
            .tint(SLColor.primary)
        }
        // The block confirmation, the report sheet and the safety toast, hosted
        // once above the tab bar. They have to outlive whatever card or row they
        // were started from — a block's whole job is to make that row disappear.
        .safetyPresentation(safety)
        .task {
            // Only so the menus say "Unmute" rather than "Mute" where that is
            // true. Failures are swallowed inside; a label optimisation must not
            // put an error banner in front of somebody who asked for nothing.
            await safety.loadRelationships()
        }
        // **This is what makes a block visible.** The safety model is the single
        // record of who is blocked; when it grows, everything that person wrote
        // leaves the feeds, the search results and the navigation stacks at once
        // — rather than sitting there until somebody pulls to refresh.
        .onChange(of: safety.blockedHandles) { previous, current in
            for handle in current.subtracting(previous) {
                viewModel.removeAuthor(handle)
                exploreViewModel.removeAuthor(handle)
                pruneStacks(blocking: handle)
            }
        }
    }

    // MARK: - Safety

    /// Opens the blocked / muted / reported lists, which are always available.
    ///
    /// Unlike the other two settings routes this one has no flag behind it and
    /// never returns `nil`: an app carrying user-generated content has to let
    /// somebody see and undo their own blocks, and a build where that entry
    /// point could be switched off is a build that should not reach review.
    private var safetyHandler: (@MainActor () -> Void)? {
        {
            container.analytics.track(.safetyListsOpened)
            isShowingSafety = true
        }
    }

    /// Builds the lists' view model for a presentation.
    ///
    /// Fresh each time, so the screen always opens on the server's current
    /// state; changes are pushed back into the shared model so the `…` menus
    /// agree without a round trip.
    private func safetyListsViewModel() -> SafetyListsViewModel {
        SafetyListsViewModel(
            service: container.safetyService,
            analytics: container.analytics,
            suspension: container.suspension,
            onChange: { change in safety.adopt(change) }
        )
    }

    /// Drops any pushed screen that is *about* a blocked account.
    ///
    /// Their profile 404s from this moment and their post detail would render a
    /// thread nobody can reply to, so both are removed from the stacks rather
    /// than left for the user to walk back into. Removal is by predicate across
    /// the whole path, not just its tail: the offending screen is often two back
    /// by the time a block is confirmed from a card further in.
    private func pruneStacks(blocking handle: String) {
        let target = Handle.normalised(handle)
        guard !target.isEmpty else { return }
        let isAbout: (FeedRoute) -> Bool = { route in
            switch route {
            case let .profile(handle): return Handle.normalised(handle) == target
            case let .postDetail(post): return Handle.normalised(post.author.handle) == target
            }
        }
        container.router.feedPath.removeAll(where: isAbout)
        container.router.explorePath.removeAll(where: isAbout)
        container.router.profilePath.removeAll(where: isAbout)
    }

    /// The `…` menu for one post, or `nil` on the viewer's own.
    private func safetyMenu(for post: Post) -> SafetyMenuActions? {
        safety.menu(for: post)
    }

    /// The `…` menu for a profile header, or `nil` on the viewer's own page.
    private func safetyMenu(for target: SafetyTarget) -> SafetyMenuActions? {
        safety.menu(for: target)
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
                container.suspension.clear()
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
                    onOpenPost: openPost,
                    onStub: stub,
                    onOpenProfile: openProfile,
                    onCompose: composeHandler,
                    onOpenPreferences: preferencesHandler,
                    safetyMenu: safetyMenu(for:)
                )
                .tnNavigationBar(title: "Sila")
                .navigationDestination(for: FeedRoute.self) { route in
                    destination(for: route)
                }
            }
            .tint(SLColor.primary)

        case .explore:
            NavigationStack(path: Binding(
                get: { container.router.explorePath },
                set: { container.router.explorePath = $0 }
            )) {
                ExploreScreen(
                    viewModel: exploreViewModel,
                    onOpenPost: openPost,
                    onStub: stub,
                    onOpenProfile: openProfile,
                    onCompose: composeHandler,
                    safetyMenu: safetyMenu(for:)
                )
                .tnNavigationBar(title: "Explore")
                .navigationDestination(for: FeedRoute.self) { route in
                    destination(for: route)
                }
            }
            .tint(SLColor.primary)

        case .notifications:
            NotificationsScreen(onStub: stub)

        case .profile:
            NavigationStack(path: Binding(
                get: { container.router.profilePath },
                set: { container.router.profilePath = $0 }
            )) {
                ownProfile
                    .navigationDestination(for: FeedRoute.self) { route in
                        destination(for: route)
                    }
            }
            .tint(SLColor.primary)
        }
    }

    // MARK: - Profile

    /// The Profile tab's root.
    ///
    /// The real page when Phase 7 is on, and the honest stub when it is not —
    /// the flag has a genuine off state, and the stub is still the route into
    /// account settings and sign-out.
    @ViewBuilder
    private var ownProfile: some View {
        if container.flags.profile {
            ProfileScreenHost(
                makeViewModel: {
                    // The session's handle is both *whose* page this is and the
                    // provisional answer to `is_me`, so the settings routes are
                    // on screen before the server confirms anything — and stay
                    // there if it never does.
                    profileViewModel(handle: container.session.user?.handle ?? "")
                },
                onOpenPost: openPost,
                onOpenProfile: openProfile,
                onStub: stub,
                onCompose: composeHandler,
                ownerActions: ProfileOwnerActions(
                    onOpenAccount: accountHandler,
                    onOpenPreferences: preferencesHandler,
                    onOpenSafety: safetyHandler,
                    onSignOut: {
                        container.suspension.clear()
                        container.router.popFeedToRoot()
                        Task { await container.session.signOut() }
                    }
                ),
                safetyMenu: safetyMenu(for:),
                postSafetyMenu: safetyMenu(for:)
            )
            .tnNavigationBar(title: profileTitle)
        } else {
            ProfileStubScreen(
                user: container.session.user,
                onStub: stub,
                onOpenPreferences: preferencesHandler,
                onOpenAccount: accountHandler,
                onOpenSafety: safetyHandler,
                onSignOut: {
                    container.suspension.clear()
                    container.router.popFeedToRoot()
                    Task { await container.session.signOut() }
                }
            )
        }
    }

    /// `"@aziz"`, or the neutral title when the session carries no handle.
    private var profileTitle: String {
        guard let handle = container.session.user?.handle, !handle.isEmpty else {
            return "Profile"
        }
        return "@\(handle)"
    }

    /// Builds a profile view model for one destination.
    private func profileViewModel(handle: String) -> ProfileViewModel {
        ProfileViewModel(
            handle: handle,
            viewerHandle: container.session.user?.handle,
            service: container.profileService,
            feed: container.feedService,
            analytics: container.analytics
        )
    }

    // MARK: - Navigation

    /// Pushes a route onto the stack the user is currently looking at.
    ///
    /// Notifications has no stack of its own; it also has nothing that pushes.
    private func push(_ route: FeedRoute) {
        switch selection {
        case .home: container.router.feedPath.append(route)
        case .explore: container.router.explorePath.append(route)
        case .profile: container.router.profilePath.append(route)
        case .notifications: break
        }
    }

    private func openPost(_ post: Post) {
        push(.postDetail(post))
    }

    /// Opens somebody's profile, or says why it is not there.
    ///
    /// A handle that cannot survive ``Handle/pathComponent(_:)`` is refused
    /// here rather than pushed: it would only produce the "isn't available"
    /// screen, and a mention that was never a handle is not a missing account.
    private func openProfile(_ handle: String) {
        guard container.flags.profile else {
            stub("Profiles")
            return
        }
        let component = Handle.pathComponent(handle)
        guard !component.isEmpty else {
            container.router.show(.info("That doesn't look like a Sila handle."))
            return
        }
        container.analytics.track(.profileOpened, properties: ["handle": component])
        push(.profile(handle: component))
    }

    @ViewBuilder
    private func destination(for route: FeedRoute) -> some View {
        switch route {
        case let .postDetail(post):
            // Engagement changed on the detail screen must not be lost when the
            // user swipes back to a list still holding the old copy. Both lists
            // are told, because either could be the one behind this screen.
            detail(for: post, onDismiss: { updated in
                viewModel.merge(updated)
                exploreViewModel.merge(updated)
            })

        case let .profile(handle):
            ProfileScreenHost(
                makeViewModel: { profileViewModel(handle: handle) },
                onOpenPost: openPost,
                onOpenProfile: openProfile,
                onStub: stub,
                onCompose: composeHandler,
                // No sign-out on a pushed page: ending the session is a Profile
                // tab affordance, not something to meet at the end of a
                // navigation chain. The other two only render when the page
                // turns out to be the viewer's own.
                ownerActions: ProfileOwnerActions(
                    onOpenAccount: accountHandler,
                    onOpenPreferences: preferencesHandler,
                    onOpenSafety: safetyHandler
                ),
                safetyMenu: safetyMenu(for:),
                postSafetyMenu: safetyMenu(for:)
            )
            .tnNavigationBar(title: "@\(handle)")
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
            onOpenPost: openPost,
            onStub: stub,
            onOpenProfile: openProfile,
            onDismiss: onDismiss,
            safetyMenu: safetyMenu(for:),
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
                label: "Profile", hint: "Your profile, your posts and your account settings", kind: .tab(.profile)
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

/// The Profile tab when ``FeatureFlags/profile`` is off.
///
/// Retained as the flag's genuine off state rather than deleted: it carries the
/// affordances a user needs whatever else is switched off — account settings,
/// feed preferences and signing out — and it invents no follower counts and no
/// bio, because with the endpoints unreachable there are none to show.
@MainActor
struct ProfileStubScreen: View {

    let user: AuthUser?
    let onStub: @MainActor (String) -> Void
    /// Opens feed preferences, or `nil` when the flag is off.
    var onOpenPreferences: (@MainActor () -> Void)?
    /// Opens account settings, or `nil` when the flag is off.
    var onOpenAccount: (@MainActor () -> Void)?
    /// Opens the blocked / muted / reported lists. Never `nil` in the app —
    /// there is no flag behind it, because an app with user-generated content
    /// has to let people see and undo their own blocks.
    var onOpenSafety: (@MainActor () -> Void)?
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

            if let onOpenSafety {
                settingsEntry(
                    icon: "hand.raised",
                    title: "Safety",
                    detail: "Who you've blocked, who you've muted, and what you've reported. "
                        + "None of them were told.",
                    hint: "Opens your blocked and muted accounts, each undoable in place, "
                        + "and the reports you have filed",
                    open: onOpenSafety
                )
                .padding(.horizontal, SLSpacing.lg)
            }

            SLEmptyState(
                icon: "person.crop.square",
                title: "Profiles are switched off",
                subtitle: "Public profile pages — follower counts, post history and how others see you — are turned off in this build. Your name, handle, bio and picture are editable now under Account. Nothing here is guessed in the meantime.",
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
