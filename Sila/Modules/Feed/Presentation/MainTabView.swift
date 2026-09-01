import SwiftUI

/// The verified app's shell: five slots, four screens.
///
/// Replaces Phase 1's `FeedPlaceholderScreen` as the destination for
/// ``SessionRoute/feed``.
///
/// Each tab owns its own navigation stack, and all four carry the same
/// ``FeedRoute`` cases: a post leads to its author, whose timeline leads to
/// another post. Pushing that chain onto the tab it started in is what stops
/// Explore from rearranging the history the home feed is holding — and now
/// stops a tapped notification from doing it either.
@MainActor
public struct MainTabView: View {

    /// The five selectable destinations. Compose is an action, not a tab.
    public enum Tab: String, Hashable, Sendable, CaseIterable {
        case home, explore, rooms, notifications, profile
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
    /// `true` while the five notification switches are up.
    @State private var isShowingNotificationSettings = false
    /// Owns the notification list and — the reason it lives up here rather than
    /// inside the tab — the unread count the tab-bar badge draws. A view model
    /// created inside the Notifications branch would be thrown away every time
    /// somebody switched tabs, taking the badge with it.
    @State private var notificationsViewModel: NotificationsViewModel
    /// Owns both room lists. Up here for the same reason the notifications
    /// model is: a list thrown away on every tab switch would refetch — and
    /// lose somebody's place — every time they glanced at Home.
    @State private var roomsViewModel: RoomsViewModel
    /// Blocking, muting and reporting for every card and every header below.
    ///
    /// One instance for the whole shell rather than one per screen. The block
    /// confirmation has to survive the card it was opened from disappearing —
    /// which is exactly what a block does to it — and a menu on a profile must
    /// already know about a block taken on a post two screens ago.
    @State private var safety: SafetyViewModel

    /// Deleting your own posts, shared for the same reason ``safety`` is:
    /// a post deleted from the feed must also be gone from a profile
    /// timeline and from search, without each screen re-fetching.
    @State private var deletion: PostDeletionViewModel

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
        self._notificationsViewModel = State(
            initialValue: NotificationsViewModel(
                service: container.notificationsService,
                feed: container.feedService,
                analytics: container.analytics,
                suspension: container.suspension
            )
        )
        self._roomsViewModel = State(
            initialValue: RoomsViewModel(
                service: container.roomsService,
                analytics: container.analytics,
                suspension: container.suspension
            )
        )
        // `onChange` is wired after construction, because it has to reach the
        // two view models built just above.
        self._deletion = State(
            initialValue: PostDeletionViewModel(
                service: container.feedService,
                analytics: container.analytics,
                viewerHandle: container.session.user?.handle
            )
        )
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
        .sheet(isPresented: $isShowingNotificationSettings) {
            NavigationStack {
                NotificationSettingsSheet(
                    viewModel: NotificationSettingsViewModel(
                        service: container.preferencesService,
                        analytics: container.analytics
                    ),
                    onClose: { isShowingNotificationSettings = false }
                )
            }
            .tint(SLColor.primary)
        }
        .sheet(
            isPresented: Binding(
                get: { container.router.isCreatingRoom },
                set: { container.router.isCreatingRoom = $0 }
            )
        ) {
            NavigationStack {
                CreateRoomSheet(
                    viewModel: createRoomViewModel(),
                    onClose: { container.router.isCreatingRoom = false },
                    // Straight into the room that was just opened, when it is
                    // one. A scheduled room has nothing to walk into yet, so it
                    // is left on the list where it belongs.
                    onCreated: { room in
                        guard room.status.isJoinable else { return }
                        selection = .rooms
                        openRoom(room)
                    }
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
        .confirmationDialog(
            L10n.t("feed.delete.confirm.title"),
            isPresented: Binding(
                get: { deletion.pending != nil },
                set: { if !$0 { deletion.cancel() } }
            ),
            titleVisibility: .visible
        ) {
            Button(L10n.t("common.delete"), role: .destructive) { Task { await deletion.confirm() } }
            Button(L10n.t("feed.delete.confirm.keep"), role: .cancel) { deletion.cancel() }
        } message: {
            // States what is actually lost. There is no undo on the server.
            Text(L10n.t("feed.delete.confirm.message"))
        }
        .alert(
            L10n.t("feed.delete.failed.title"),
            isPresented: Binding(
                get: { deletion.error != nil },
                set: { if !$0 { deletion.clearError() } }
            )
        ) {
            Button(L10n.t("common.ok"), role: .cancel) { deletion.clearError() }
        } message: {
            Text(deletion.error ?? "")
        }
        .task {
            // Only so the menus say "Unmute" rather than "Mute" where that is
            // true. Failures are swallowed inside; a label optimisation must not
            // put an error banner in front of somebody who asked for nothing.
            await safety.loadRelationships()
        }
        .task {
            // The badge, before anybody opens the tab. Reading the count is not
            // reading the notifications: nothing is marked, and the number is
            // the server's rather than one counted from rows this shell holds.
            await notificationsViewModel.refreshUnreadCount()
        }
        .onChange(of: selection) { _, current in
            // Coming back to another tab is the moment the badge would
            // otherwise go stale — the list itself keeps its place and is
            // refreshed by pulling down.
            guard current != .notifications else { return }
            Task { await notificationsViewModel.refreshUnreadCount() }
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
        container.router.notificationsPath.removeAll(where: isAbout)
        // A room the blocked account is hosting is not removed: leaving one is
        // a teardown, not an array edit, and dropping the screen would strand a
        // live socket. Their profile page goes, which is what a block promises.
        container.router.roomsPath.removeAll { route in
            guard case let .profile(handle) = route else { return false }
            return Handle.normalised(handle) == target
        }
    }

    /// The `…` menu for one post, or `nil` on the viewer's own.
    private func safetyMenu(for post: Post) -> SafetyMenuActions? {
        safety.menu(for: post)
    }

    /// Delete, on the viewer's own posts only. `nil` on everybody else's,
    /// where the safety menu takes over instead.
    private func ownPostMenu(for post: Post) -> OwnPostActions? {
        deletion.actions(for: post)
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
            stub(StubFeature.composing)
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
                    safetyMenu: safetyMenu(for:),
                    ownPost: ownPostMenu(for:)
                )
                .tnNavigationBar(title: L10n.t("feed.home.navTitle"))
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
                    safetyMenu: safetyMenu(for:),
                    ownPost: ownPostMenu(for:)
                )
                .tnNavigationBar(title: L10n.t("search.navTitle"))
                .navigationDestination(for: FeedRoute.self) { route in
                    destination(for: route)
                }
            }
            .tint(SLColor.primary)

        case .rooms:
            NavigationStack(path: Binding(
                get: { container.router.roomsPath },
                set: { container.router.roomsPath = $0 }
            )) {
                RoomsScreen(
                    viewModel: roomsViewModel,
                    onOpen: { join in container.router.roomsPath.append(.room(join)) },
                    onCreate: roomCreationHandler,
                    onOpenProfile: openRoomProfile
                )
                .navigationDestination(for: RoomsRoute.self) { route in
                    roomsDestination(for: route)
                }
            }
            .tint(SLColor.primary)

        case .notifications:
            NavigationStack(path: Binding(
                get: { container.router.notificationsPath },
                set: { container.router.notificationsPath = $0 }
            )) {
                NotificationsScreen(
                    viewModel: notificationsViewModel,
                    onOpenPost: openPost,
                    onOpenProfile: openProfile,
                    onOpenSettings: {
                        guard container.flags.preferences else {
                            stub(StubFeature.notificationSettings)
                            return
                        }
                        isShowingNotificationSettings = true
                    }
                )
                .navigationDestination(for: FeedRoute.self) { route in
                    destination(for: route)
                }
            }
            .tint(SLColor.primary)

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
                postSafetyMenu: safetyMenu(for:),
                ownPost: ownPostMenu(for:)
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
            return L10n.t("feed.tab.profile.label")
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
    private func push(_ route: FeedRoute) {
        switch selection {
        case .home: container.router.feedPath.append(route)
        case .explore: container.router.explorePath.append(route)
        case .profile: container.router.profilePath.append(route)
        case .notifications: container.router.notificationsPath.append(route)
        // The Rooms tab keeps its own route type, because a room is a live
        // connection rather than a document — it has to be torn down when it
        // is popped, which a `FeedRoute` knows nothing about. Only the profile
        // case crosses over; a post has no way of being reached from in here.
        case .rooms:
            if case let .profile(handle) = route {
                container.router.roomsPath.append(.profile(handle: handle))
            }
        }
    }

    // MARK: - Rooms

    /// Opens the create sheet, or `nil` when the phase is off — which hides the
    /// affordance rather than showing one that goes nowhere.
    private var roomCreationHandler: (@MainActor () -> Void)? {
        guard container.flags.rooms else { return nil }
        return { container.router.isCreatingRoom = true }
    }

    /// Builds the create sheet's view model.
    ///
    /// Fresh each time, so the sheet always opens on an empty draft and on the
    /// server's current taxonomy rather than one cached from a previous visit.
    private func createRoomViewModel() -> CreateRoomViewModel {
        CreateRoomViewModel(
            author: ComposerAuthor(user: container.session.user),
            service: container.roomsService,
            preferences: container.preferencesService,
            analytics: container.analytics,
            suspension: container.suspension,
            onCreated: { room in roomsViewModel.insert(room) }
        )
    }

    /// Joins a room and pushes it. Used after creating one.
    private func openRoom(_ room: VoiceRoom) {
        Task {
            guard let join = await roomsViewModel.open(room) else { return }
            container.router.roomsPath.append(.room(join))
        }
    }

    /// Opens a profile from inside the Rooms tab, without disturbing any other
    /// tab's history.
    private func openRoomProfile(_ handle: String) {
        guard container.flags.profile else {
            stub(StubFeature.profiles)
            return
        }
        let component = Handle.pathComponent(handle)
        guard !component.isEmpty else { return }
        container.router.roomsPath.append(.profile(handle: component))
    }

    @ViewBuilder
    private func roomsDestination(for route: RoomsRoute) -> some View {
        switch route {
        case let .room(join):
            LiveRoomScreen(
                viewModel: LiveRoomViewModel(
                    join: join,
                    viewerHandle: container.session.user?.handle ?? "",
                    service: container.roomsService,
                    // One engine per room. A shared one would mean the second
                    // room somebody opened silently stole the first's socket.
                    engine: container.makeVoiceEngine(),
                    analytics: container.analytics,
                    suspension: container.suspension
                ),
                onLeave: {
                    // Back to the list, and anything pushed above the room —
                    // a profile opened from the participant list — goes with
                    // it: it was reached through a room that has been left.
                    container.router.roomsPath.removeAll()
                    // The count on the row behind is stale by exactly one.
                    Task { await roomsViewModel.reload(isRefresh: true) }
                },
                onOpenProfile: openRoomProfile,
                safetyMenu: { target in safety.menu(for: target) }
            )

        case let .profile(handle):
            ProfileScreenHost(
                makeViewModel: { profileViewModel(handle: handle) },
                onOpenPost: openPost,
                onOpenProfile: openRoomProfile,
                onStub: stub,
                onCompose: composeHandler,
                ownerActions: ProfileOwnerActions(
                    onOpenAccount: accountHandler,
                    onOpenPreferences: preferencesHandler,
                    onOpenSafety: safetyHandler
                ),
                safetyMenu: safetyMenu(for:),
                postSafetyMenu: safetyMenu(for:),
                ownPost: ownPostMenu(for:)
            )
            .tnNavigationBar(title: "@\(handle)")
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
            stub(StubFeature.profiles)
            return
        }
        let component = Handle.pathComponent(handle)
        guard !component.isEmpty else {
            container.router.show(.info(L10n.t("feed.profile.invalidHandle")))
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
                postSafetyMenu: safetyMenu(for:),
                ownPost: ownPostMenu(for:)
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
        var items: [SLTabBarItem<Tab>] = [
            SLTabBarItem(
                id: "home", icon: "house", selectedIcon: "house.fill",
                label: L10n.t("feed.tab.home.label"), hint: L10n.t("feed.tab.home.hint"), kind: .tab(.home)
            ),
            SLTabBarItem(
                id: "explore", icon: "magnifyingglass", selectedIcon: "magnifyingglass",
                label: L10n.t("feed.tab.explore.label"), hint: L10n.t("feed.tab.explore.hint"), kind: .tab(.explore)
            ),
            SLTabBarItem(
                id: "compose", icon: "plus",
                label: L10n.t("feed.tab.compose.label"),
                hint: container.flags.composer
                    ? L10n.t("feed.tab.compose.hint")
                    : L10n.t("feed.tab.compose.disabledHint"),
                kind: .action
            ),
            SLTabBarItem(
                id: "notifications", icon: "bell", selectedIcon: "bell.fill",
                label: L10n.t("feed.tab.notifications.label"),
                hint: L10n.t("feed.tab.notifications.hint"),
                kind: .tab(.notifications),
                // The server's count, straight from the last response. Nothing
                // here recounts rows: the badge and the list have to agree, and
                // they only can if both come from the same place.
                badge: notificationsViewModel.unreadCount
            ),
            SLTabBarItem(
                id: "profile", icon: "person", selectedIcon: "person.fill",
                label: L10n.t("feed.tab.profile.label"), hint: L10n.t("feed.tab.profile.hint"), kind: .tab(.profile)
            )
        ]
        // Inserted rather than appended, so Rooms sits beside the compose
        // button where a thing you *start* belongs — and so the flag's off
        // state is a bar with no gap in it rather than a hidden slot.
        if container.flags.rooms {
            items.insert(
                SLTabBarItem(
                    id: "rooms", icon: "waveform", selectedIcon: "waveform.circle.fill",
                    label: L10n.t("feed.tab.rooms.label"),
                    hint: L10n.t("feed.tab.rooms.hint"),
                    kind: .tab(.rooms)
                ),
                at: 3
            )
        }
        return items
    }

    /// Announces a feature that belongs to a later phase, exactly the way the
    /// verification wall's stub does: record the intent, tell the user plainly.
    private func stub(_ feature: String) {
        container.analytics.track(.featureStubShown, properties: ["feature": feature])
        container.router.show(.info(L10n.t("feed.stub.comingSoon", StubFeature.displayName(feature))))
    }

    /// The features that still answer with a stub, and the copy each one shows.
    ///
    /// The raw strings are **analytics identifiers** and go on the wire, so they
    /// stay English and stay stable. The sentence a user reads is looked up
    /// separately — which is the whole reason this is a lookup rather than the
    /// interpolation it used to be, where the analytics value *was* the copy and
    /// translating one would have silently renamed the other.
    enum StubFeature {
        static let composing = "Composing posts"
        static let notificationSettings = "Notification settings"
        static let profiles = "Profiles"
        static let notInterested = "Not interested"
        static let report = "Report"
        static let replying = "Replying"
        static let quotePosts = "Quote posts"
        static let hashtagSearch = "Hashtag search"
        static let identityVerification = "Identity verification"

        static func displayName(_ identifier: String) -> String {
            switch identifier {
            case composing: return L10n.t("feed.stub.name.composing")
            case notificationSettings: return L10n.t("feed.stub.name.notificationSettings")
            case profiles: return L10n.t("feed.stub.name.profiles")
            case notInterested: return L10n.t("feed.stub.name.notInterested")
            case report: return L10n.t("feed.stub.name.report")
            case replying: return L10n.t("feed.stub.name.replying")
            case quotePosts: return L10n.t("feed.stub.name.quotePosts")
            case hashtagSearch: return L10n.t("feed.stub.name.hashtagSearch")
            case identityVerification: return L10n.t("feed.stub.name.identityVerification")
            // A stub added later without a matching key still says something
            // truthful, in English, rather than rendering a key.
            default: return identifier
            }
        }
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
                Text(user?.displayName ?? L10n.t("feed.profileOff.fallbackName"))
                    .font(SLFont.displayM)
                    .foregroundStyle(SLColor.textPrimary)

                if let email = user?.email {
                    Text(email)
                        .font(SLFont.mono)
                        .foregroundStyle(SLColor.textMuted)
                        .accessibilityLabel(Text(L10n.t("feed.profileOff.signedInAs", email)))
                }

                if user?.verificationStatus == .verified {
                    SLBadge(L10n.t("feed.profileOff.verifiedBadge"), style: .verified, icon: "checkmark.seal.fill")
                }
            }

            if let onOpenAccount {
                settingsEntry(
                    icon: "person.text.rectangle",
                    title: L10n.t("feed.profileOff.account.title"),
                    detail: L10n.t("feed.profileOff.account.detail"),
                    hint: L10n.t("feed.profileOff.account.hint"),
                    open: onOpenAccount
                )
                .padding(.horizontal, SLSpacing.lg)
            }

            if let onOpenPreferences {
                settingsEntry(
                    icon: "slider.horizontal.3",
                    title: L10n.t("feed.profileOff.preferences.title"),
                    detail: L10n.t("feed.profileOff.preferences.detail"),
                    hint: L10n.t("feed.profileOff.preferences.hint"),
                    open: onOpenPreferences
                )
                .padding(.horizontal, SLSpacing.lg)
            }

            if let onOpenSafety {
                settingsEntry(
                    icon: "hand.raised",
                    title: L10n.t("feed.profileOff.safety.title"),
                    detail: L10n.t("feed.profileOff.safety.detail"),
                    hint: L10n.t("feed.profileOff.safety.hint"),
                    open: onOpenSafety
                )
                .padding(.horizontal, SLSpacing.lg)
            }

            SLEmptyState(
                icon: "person.crop.square",
                title: L10n.t("feed.profileOff.empty.title"),
                subtitle: L10n.t("feed.profileOff.empty.subtitle"),
                tint: SLColor.textSecondary,
                actionTitle: L10n.t("feed.profileOff.empty.action"),
                action: { onStub(MainTabView.StubFeature.profiles) }
            )
            .padding(.horizontal, SLSpacing.lg)

            SLButton(
                L10n.t("common.signOut"),
                variant: .ghost,
                size: .compact,
                accessibilityHint: L10n.t("auth.signOut.hint"),
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
