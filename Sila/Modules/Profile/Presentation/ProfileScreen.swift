import SwiftUI

/// The affordances that only belong on the viewer's **own** profile.
///
/// Passed in rather than built here because none of them are the Profile
/// module's business: editing lives in `Modules/Account/`, the feed filters live
/// in `Modules/Preferences/`, and ending a session belongs to `AuthSession`.
/// Each is optional, and a `nil` renders nothing at all — which is how the
/// feature flags switch a destination off without leaving a control that goes
/// nowhere.
public struct ProfileOwnerActions {

    /// Opens the existing account/profile editor.
    public var onOpenAccount: (@MainActor () -> Void)?
    /// Opens feed preferences.
    public var onOpenPreferences: (@MainActor () -> Void)?
    /// Opens the blocked, muted and reported lists.
    public var onOpenSafety: (@MainActor () -> Void)?
    /// Ends the session.
    public var onSignOut: (@MainActor () -> Void)?

    public init(
        onOpenAccount: (@MainActor () -> Void)? = nil,
        onOpenPreferences: (@MainActor () -> Void)? = nil,
        onOpenSafety: (@MainActor () -> Void)? = nil,
        onSignOut: (@MainActor () -> Void)? = nil
    ) {
        self.onOpenAccount = onOpenAccount
        self.onOpenPreferences = onOpenPreferences
        self.onOpenSafety = onOpenSafety
        self.onSignOut = onSignOut
    }

    /// `true` when nothing at all was supplied.
    public var isEmpty: Bool {
        onOpenAccount == nil && onOpenPreferences == nil
            && onOpenSafety == nil && onSignOut == nil
    }
}

/// One person's public page: who they are, what they have posted, and the one
/// button that changes the viewer's relationship to them.
///
/// Three things it deliberately does **not** do.
///
/// * **It does not invent a second profile editor.** On your own profile the
///   Follow button is replaced by a route into `AccountScreen`, which already
///   owns the name, handle, bio and picture.
/// * **It does not claim the timeline is complete.** The server excludes
///   replies, so ``ProfileCopy/timelineScope`` says so under the heading —
///   including when the list is empty.
/// * **It does not offer a Retry for a handle that does not exist.** A
///   deactivated or unknown account is a dead end, and a button that can only
///   fail again is an invitation to keep pressing it.
@MainActor
public struct ProfileScreen: View {

    @Bindable private var viewModel: ProfileViewModel
    private let onOpenPost: @MainActor (Post) -> Void
    private let onOpenProfile: @MainActor (String) -> Void
    private let onStub: @MainActor (String) -> Void
    private let onCompose: (@MainActor (ComposerContext) -> Void)?
    private let ownerActions: ProfileOwnerActions
    private let safetyMenu: (@MainActor (SafetyTarget) -> SafetyMenuActions?)?
    private let postSafetyMenu: (@MainActor (Post) -> SafetyMenuActions?)?
    /// Builds the author's own menu for a card — Delete, on your posts only.
    private let ownPost: (@MainActor (Post) -> OwnPostActions?)?

    /// - Parameters:
    ///   - viewModel: Owns the profile and the timeline.
    ///   - onOpenPost: Pushes a post's detail screen.
    ///   - onOpenProfile: Pushes another account's profile — a mention, or the
    ///     author of a quoted post.
    ///   - onStub: Announces a feature that belongs to a later phase.
    ///   - onCompose: Opens the composer for a reply or a quote. `nil` falls
    ///     back to the stub toast.
    ///   - ownerActions: Routes shown only on the viewer's own profile.
    ///   - safetyMenu: Builds the header's `…` menu, or returns `nil` when there
    ///     should not be one — on the viewer's own page, or with no safety
    ///     backend wired.
    ///   - postSafetyMenu: The same, for each card on the timeline.
    public init(
        viewModel: ProfileViewModel,
        onOpenPost: @escaping @MainActor (Post) -> Void,
        onOpenProfile: @escaping @MainActor (String) -> Void = { _ in },
        onStub: @escaping @MainActor (String) -> Void = { _ in },
        onCompose: (@MainActor (ComposerContext) -> Void)? = nil,
        ownerActions: ProfileOwnerActions = ProfileOwnerActions(),
        safetyMenu: (@MainActor (SafetyTarget) -> SafetyMenuActions?)? = nil,
        postSafetyMenu: (@MainActor (Post) -> SafetyMenuActions?)? = nil,
        ownPost: (@MainActor (Post) -> OwnPostActions?)? = nil
    ) {
        self.viewModel = viewModel
        self.onOpenPost = onOpenPost
        self.onOpenProfile = onOpenProfile
        self.onStub = onStub
        self.onCompose = onCompose
        self.ownerActions = ownerActions
        self.safetyMenu = safetyMenu
        self.postSafetyMenu = postSafetyMenu
        self.ownPost = ownPost
    }

    public var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .tnScreenBackground()
            .task {
                await viewModel.load()
                // Somebody already blocked, opened from a mention or a search
                // result, must arrive on the blocked panel rather than on a
                // timeline the server is about to stop serving.
                syncBlockState(isBlockedByViewer)
            }
            // The app's safety model is the source of truth for "is this person
            // blocked", and it is what a confirmation dialog three screens up
            // writes to. Watching it here is what makes a block taken from the
            // header empty this timeline immediately.
            .onChange(of: isBlockedByViewer) { _, blocked in
                syncBlockState(blocked)
            }
            .onChange(of: isMutedByViewer) { _, muted in
                viewModel.apply(muted ? .muted(safetyTarget) : .unmuted(safetyTarget))
            }
            .tnToast($viewModel.toast)
    }

    // MARK: - Safety state

    /// The header's menu, when there should be one.
    ///
    /// Built from the handle rather than from a loaded ``Profile`` on purpose: a
    /// blocked account 404s, so on exactly the page where the Unblock control
    /// matters most there is no profile object to build a menu from.
    private var headerSafety: SafetyMenuActions? {
        safetyMenu?(safetyTarget)
    }

    /// Who this page is about, for the local state updates.
    private var safetyTarget: SafetyTarget {
        SafetyTarget(handle: viewModel.handle, name: viewModel.profile?.displayName)
    }

    /// Whether the app's safety model says this account is blocked.
    private var isBlockedByViewer: Bool { headerSafety?.isBlocked ?? false }

    /// Whether it says this account is muted.
    private var isMutedByViewer: Bool { headerSafety?.isMuted ?? false }

    /// Brings the timeline into line with a block that was taken or lifted.
    private func syncBlockState(_ blocked: Bool) {
        guard blocked != viewModel.isBlocked else { return }
        if blocked {
            viewModel.apply(.blocked(safetyTarget))
        } else {
            Task { await viewModel.reloadAfterUnblock() }
        }
    }

    // MARK: - Routing

    @ViewBuilder
    private var content: some View {
        switch viewModel.loadState {
        case .idle, .loading:
            skeleton

        case .unavailable:
            // **A blocked account 404s.** The server makes a block
            // indistinguishable from a handle that never existed, which is the
            // right answer to give a stranger and the wrong one to show the
            // person who made the block. This client knows which it is, so it
            // says so — and offers the undo. Without this branch, blocking
            // somebody and later opening their page would claim their account
            // had been deleted.
            if viewModel.isBlocked {
                blockedRoot
            } else {
                // No action, on purpose: the handle will not start existing
                // because somebody pressed a button. The owner routes stay
                // reachable so the Profile tab is never a trap.
                ScrollView {
                    VStack(spacing: SLSpacing.lg) {
                        SLEmptyState(
                            icon: "person.crop.circle.badge.xmark",
                            title: ProfileCopy.unavailableTitle,
                            subtitle: ProfileCopy.unavailableSubtitle(for: viewModel.handle),
                            tint: SLColor.textSecondary
                        )
                        ownerSection
                    }
                    .padding(.horizontal, SLSpacing.lg)
                    .padding(.top, SLSpacing.xxl)
                }
            }

        case let .failed(message):
            ScrollView {
                VStack(spacing: SLSpacing.lg) {
                    SLEmptyState(
                        icon: "wifi.exclamationmark",
                        title: L10n.t("profile.error.title"),
                        subtitle: message,
                        tint: SLColor.danger,
                        actionTitle: L10n.t("profile.action.tryAgain"),
                        action: { Task { await viewModel.reload() } }
                    )
                    ownerSection
                }
                .padding(.horizontal, SLSpacing.lg)
                .padding(.top, SLSpacing.xxl)
            }

        case .loaded:
            timeline
        }
    }

    private var skeleton: some View {
        VStack(spacing: SLSpacing.lg) {
            ForEach(0..<5, id: \.self) { _ in
                SLSkeletonRow(lineCount: 3).padding(.horizontal, SLSpacing.lg)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, SLSpacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel(Text(L10n.t("profile.loading.accessibilityLabel")))
    }

    // MARK: - Timeline

    private var timeline: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                header
                ownerSection
                    .padding(.horizontal, SLSpacing.lg)
                    .padding(.bottom, SLSpacing.lg)

                SLDivider()
                timelineHeading

                if viewModel.isBlocked {
                    blockedPanel

                } else if viewModel.isLoadingPosts && viewModel.posts.isEmpty {
                    VStack(spacing: SLSpacing.lg) {
                        ForEach(0..<3, id: \.self) { _ in
                            SLSkeletonRow(lineCount: 2).padding(.horizontal, SLSpacing.lg)
                        }
                    }
                    .padding(.vertical, SLSpacing.lg)
                    .accessibilityLabel(Text(L10n.t("profile.timeline.loading.accessibilityLabel")))

                } else if let error = viewModel.postsError {
                    SLEmptyState(
                        icon: "wifi.exclamationmark",
                        title: L10n.t("profile.timeline.error.title"),
                        subtitle: error,
                        tint: SLColor.danger,
                        actionTitle: L10n.t("profile.action.tryAgain"),
                        action: { Task { await viewModel.reload(isRefresh: true) } }
                    )
                    .padding(.horizontal, SLSpacing.lg)
                    .padding(.vertical, SLSpacing.xl)

                } else if viewModel.posts.isEmpty {
                    SLEmptyState(
                        icon: "text.bubble",
                        title: ProfileCopy.emptyTimelineTitle,
                        subtitle: ProfileCopy.emptyTimelineSubtitle(
                            for: viewModel.profile?.displayName ?? viewModel.handle
                        ),
                        tint: SLColor.textSecondary
                    )
                    .padding(.horizontal, SLSpacing.lg)
                    .padding(.vertical, SLSpacing.xl)

                } else {
                    ForEach(viewModel.posts) { post in
                        PostCardView(post: post, actions: actions(for: post))
                            .task { await viewModel.loadMoreIfNeeded(currentPost: post) }

                        SLDivider()
                    }

                    if viewModel.isLoadingMore {
                        ProgressView()
                            .tint(SLColor.primary)
                            .frame(maxWidth: .infinity)
                            .padding(SLSpacing.xl)
                            .accessibilityLabel(Text(L10n.t("profile.timeline.loadingMore.accessibilityLabel")))
                    } else if !viewModel.hasMore {
                        Text(L10n.t("profile.timeline.end"))
                            .font(SLFont.caption)
                            .foregroundStyle(SLColor.textMuted)
                            .frame(maxWidth: .infinity)
                            .padding(SLSpacing.xl)
                    }
                }
            }
        }
        .scrollDismissesKeyboard(.immediately)
        .refreshable { await viewModel.reload(isRefresh: true) }
    }

    /// What the timeline becomes once this account is blocked.
    ///
    /// The posts are gone *now*, not after a refetch, which is the whole point:
    /// a block that leaves somebody's posts on screen while a request goes out
    /// reads as a button that did not work. The undo is right here rather than
    /// buried in settings, and it says plainly what unblocking does not restore.
    private var blockedPanel: some View {
        VStack(spacing: SLSpacing.md) {
            SLEmptyState(
                icon: "hand.raised.fill",
                title: L10n.t(
                    "profile.blocked.title",
                    viewModel.profile?.displayName ?? viewModel.handle
                ),
                subtitle: L10n.t("profile.blocked.subtitle"),
                tint: SLColor.textSecondary
            )

            if let unblock = headerSafety?.onUnblock {
                SLButton(
                    L10n.t("safety.action.unblock.short"),
                    variant: .secondary,
                    size: .compact,
                    accessibilityHint: L10n.t("safety.unblock.hint"),
                    // Only asks for the unblock. The timeline comes back when the
                    // app's safety model says the block is gone — see
                    // ``syncBlockState(_:)`` — rather than on a hopeful reload
                    // fired before the request has landed.
                    action: unblock
                )
                .frame(width: 160)
            }
        }
        .padding(.horizontal, SLSpacing.lg)
        .padding(.vertical, SLSpacing.xl)
    }

    /// The whole screen, when the header could not load because the block made
    /// the account 404.
    ///
    /// Same panel, presented as the page rather than under a header there is no
    /// data to draw. The owner routes ride along so the Profile tab can never
    /// become a dead end.
    private var blockedRoot: some View {
        ScrollView {
            VStack(spacing: SLSpacing.lg) {
                blockedPanel
                ownerSection
            }
            .padding(.horizontal, SLSpacing.lg)
            .padding(.top, SLSpacing.xl)
        }
    }

    private var timelineHeading: some View {
        VStack(alignment: .leading, spacing: SLSpacing.xs) {
            Text(L10n.t("profile.timeline.heading"))
                .font(SLFont.micro)
                .tracking(0.8)
                .foregroundStyle(SLColor.textSecondary)

            // Stated whether or not the list has rows: the exclusion is a fact
            // about what this endpoint returns, not about today's contents.
            Text(ProfileCopy.timelineScope)
                .font(SLFont.micro)
                .foregroundStyle(SLColor.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, SLSpacing.lg)
        .padding(.top, SLSpacing.lg)
        .padding(.bottom, SLSpacing.sm)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        if let profile = viewModel.profile {
            VStack(alignment: .leading, spacing: SLSpacing.md) {
                HStack(alignment: .top, spacing: SLSpacing.lg) {
                    SLAvatar(
                        url: profile.user.avatarURL,
                        initials: profile.user.initials,
                        size: .xl,
                        isVerified: profile.user.isVerified,
                        displayName: profile.displayName
                    )

                    Spacer(minLength: 0)

                    followControl(profile)

                    // Beside Follow, not instead of it. Report, mute and block
                    // have to be reachable from a profile — Guideline 1.2 — but
                    // a page whose loudest control was "Block" would be a
                    // strange thing to open somebody's account and find.
                    if let safety = headerSafety {
                        SafetyMenuButton(actions: safety, size: 17)
                    }
                }

                VStack(alignment: .leading, spacing: SLSpacing.xs) {
                    HStack(spacing: SLSpacing.sm) {
                        // A display name is written by the person it belongs to,
                        // so it is laid out in its own direction rather than the
                        // interface's — an Arabic name in an English UI still
                        // reads right-to-left.
                        Text(profile.displayName)
                            .font(SLFont.displayM)
                            .foregroundStyle(SLColor.textPrimary)
                            .lineLimit(2)
                            .slContentDirection(
                                TextDirection.resolve(languageCode: nil, text: profile.displayName)
                            )

                        if profile.user.isVerified {
                            SLVerifiedBadge(size: 20, isPulsing: false)
                        }
                    }

                    HStack(spacing: SLSpacing.sm) {
                        Text(profile.atHandle)
                            .font(SLFont.mono)
                            .foregroundStyle(SLColor.textSecondary)
                            .lineLimit(1)

                        // The country flag is drawn only for a verified
                        // account. `country_code` is written by the
                        // verification pipeline alone, so this is belt and
                        // braces — the platform's core trust signal must not be
                        // one server change away from appearing on an
                        // unverified account.
                        if profile.user.isVerified {
                            SLCountryBadge(countryCode: profile.user.countryCode, size: .regular)
                        }
                    }

                    if let since = verifiedSince(profile) {
                        Text(since)
                            .font(SLFont.micro)
                            .foregroundStyle(SLColor.textMuted)
                    }

                    // Muting silences a feed; it does not blank a page somebody
                    // deliberately opened. The badge is the whole difference
                    // between a mute and a block on this screen — and it says,
                    // where the user can read it, that the mute is not announced.
                    if viewModel.isMuted && !viewModel.isBlocked {
                        SLBadge(L10n.t("profile.badge.muted"), style: .neutral, icon: "speaker.slash.fill")
                            .padding(.top, SLSpacing.xs)
                            .accessibilityLabel(Text(L10n.t("profile.badge.muted.accessibilityLabel")))
                    }
                }

                if let bio = profile.bio {
                    // The bio is the person's own words; it follows them, not
                    // the app's language.
                    Text(bio)
                        .font(SLFont.body)
                        .foregroundStyle(SLColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .slContentDirection(TextDirection.resolve(languageCode: nil, text: bio))
                }

                counts(profile)
            }
            .padding(.horizontal, SLSpacing.lg)
            .padding(.top, SLSpacing.lg)
            .padding(.bottom, SLSpacing.md)
        }
    }

    /// "Verified since March 2026", or `nil` when the account is not verified.
    private func verifiedSince(_ profile: Profile) -> String? {
        guard profile.user.isVerified, let date = profile.user.verifiedSince else { return nil }
        return L10n.t("profile.verifiedSince", SLFormat.monthAndYear(date))
    }

    /// The three counters.
    ///
    /// Plain text rather than buttons: there is no endpoint that lists an
    /// account's followers, and a tappable number that opens nothing is a
    /// promise the backend cannot keep.
    private func counts(_ profile: Profile) -> some View {
        HStack(spacing: SLSpacing.xl) {
            count(profile.postCount, labelKey: "profile.count.posts", spokenKey: "profile.count.posts.accessibility")
            count(profile.followerCount, labelKey: "profile.count.followers", spokenKey: "profile.count.followers.accessibility")
            count(profile.followingCount, labelKey: "profile.count.following", spokenKey: "profile.count.following.accessibility")
            Spacer(minLength: 0)
        }
        .padding(.top, SLSpacing.xs)
    }

    /// One counter: an abbreviated number beside its noun.
    ///
    /// Both keys are plurals, and both are selected by `value`. English needs
    /// two forms and gets away with a ternary; Arabic needs six, and "2
    /// followers" and "11 followers" take different words from each other and
    /// from "3 followers". The visible label is separate from the spoken one
    /// because the visible number is abbreviated ("1.2K") and the spoken one
    /// must not be.
    private func count(_ value: Int, labelKey: String, spokenKey: String) -> some View {
        HStack(spacing: SLSpacing.xs) {
            Text(SLFormat.compactCount(value))
                .font(SLFont.bodyEmphasis)
                .monospacedDigit()
                .foregroundStyle(SLColor.textPrimary)
            Text(L10n.plural(labelKey, value))
                .font(SLFont.caption)
                .foregroundStyle(SLColor.textSecondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(L10n.plural(spokenKey, value)))
    }

    /// Follow / Following, or the route into the existing editor when the
    /// profile is the viewer's own. Never both, and never a disabled Follow.
    @ViewBuilder
    private func followControl(_ profile: Profile) -> some View {
        if profile.showsFollowControl {
            SLButton(
                viewModel.followButtonTitle,
                variant: profile.isFollowing ? .secondary : .primary,
                size: .compact,
                icon: profile.isFollowing ? "checkmark" : "plus",
                isLoading: viewModel.isFollowPending,
                accessibilityHint: viewModel.followButtonHint,
                action: { Task { await viewModel.toggleFollow() } }
            )
            .frame(width: 132)
        } else if let onOpenAccount = ownerActions.onOpenAccount {
            SLButton(
                L10n.t("profile.editProfile"),
                variant: .secondary,
                size: .compact,
                icon: "square.and.pencil",
                accessibilityHint: L10n.t("profile.editProfile.hint"),
                action: onOpenAccount
            )
            .frame(width: 148)
        }
    }

    // MARK: - Owner routes

    /// The settings routes, shown only on the viewer's own profile.
    ///
    /// Gated on ``ProfileViewModel/isOwnProfile``, which answers from the
    /// server's `is_me` once it has one and from the handles before that — so
    /// the Profile tab stays a way into account settings even on a bad network,
    /// because deletion and the data export live behind it and a dead end
    /// there is not survivable.
    @ViewBuilder
    private var ownerSection: some View {
        if !ownerActions.isEmpty, viewModel.isOwnProfile {
            VStack(spacing: SLSpacing.md) {
                if let open = ownerActions.onOpenAccount {
                    settingsEntry(
                        icon: "person.text.rectangle",
                        title: L10n.t("feed.profileOff.account.title"),
                        detail: L10n.t("feed.profileOff.account.detail"),
                        hint: L10n.t("feed.profileOff.account.hint"),
                        open: open
                    )
                }

                if let open = ownerActions.onOpenPreferences {
                    settingsEntry(
                        icon: "slider.horizontal.3",
                        title: L10n.t("feed.profileOff.preferences.title"),
                        detail: L10n.t("feed.profileOff.preferences.detail"),
                        hint: L10n.t("feed.profileOff.preferences.hint"),
                        open: open
                    )
                }

                if let open = ownerActions.onOpenSafety {
                    settingsEntry(
                        icon: "hand.raised",
                        title: L10n.t("feed.profileOff.safety.title"),
                        detail: L10n.t("feed.profileOff.safety.detail"),
                        hint: L10n.t("feed.profileOff.safety.hint"),
                        open: open
                    )
                }

                if let signOut = ownerActions.onSignOut {
                    SLButton(
                        L10n.t("common.signOut"),
                        variant: .ghost,
                        size: .compact,
                        accessibilityHint: L10n.t("auth.signOut.hint"),
                        action: signOut
                    )
                    .padding(.top, SLSpacing.xs)
                }
            }
        }
    }

    /// One route into a settings screen.
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

    // MARK: - Card wiring

    private func compose(_ context: ComposerContext, fallback: String) {
        guard let onCompose else {
            onStub(fallback)
            return
        }
        onCompose(context)
    }

    private func actions(for post: Post) -> PostCardActions {
        PostCardActions(
            onOpen: onOpenPost,
            onLike: { post in Task { await viewModel.toggleLike(post) } },
            onRepost: { post in Task { await viewModel.toggleRepost(post) } },
            onBookmark: { post in Task { await viewModel.toggleBookmark(post) } },
            onReply: { post in compose(.reply(to: post), fallback: MainTabView.StubFeature.replying) },
            onReplyBlocked: { post in viewModel.replyBlocked(post) },
            onQuote: { post in compose(.quote(post), fallback: MainTabView.StubFeature.quotePosts) },
            onMention: { handle in onOpenProfile(handle) },
            onHashtag: { _ in onStub(MainTabView.StubFeature.hashtagSearch) },
            onOpenQuoted: onOpenPost,
            // Every author on this page is the person whose profile it is,
            // except inside a quote card — so this only ever navigates
            // somewhere new, and never pushes a copy of the current screen.
            onOpenAuthor: { author in
                guard author.handle != viewModel.handle else { return }
                onOpenProfile(author.handle)
            },
            onStub: onStub,
            safetyMenu: postSafetyMenu,
            ownPost: ownPost
        )
    }

}

// MARK: - Host

/// Owns a ``ProfileViewModel`` for the lifetime of one navigation destination.
///
/// `navigationDestination`'s builder is re-invoked whenever the enclosing view
/// re-renders, so a view model constructed inline there would be thrown away and
/// rebuilt — refetching the profile, and losing the timeline — every time a
/// toast appeared. The `@State` here is what makes the destination's state
/// survive its parent's redraws. Same contract as ``ComposerSheetHost``.
@MainActor
public struct ProfileScreenHost: View {

    @State private var viewModel: ProfileViewModel
    private let onOpenPost: @MainActor (Post) -> Void
    private let onOpenProfile: @MainActor (String) -> Void
    private let onStub: @MainActor (String) -> Void
    private let onCompose: (@MainActor (ComposerContext) -> Void)?
    private let ownerActions: ProfileOwnerActions
    private let safetyMenu: (@MainActor (SafetyTarget) -> SafetyMenuActions?)?
    private let postSafetyMenu: (@MainActor (Post) -> SafetyMenuActions?)?
    private let ownPost: (@MainActor (Post) -> OwnPostActions?)?

    /// - Parameters:
    ///   - makeViewModel: Called **once**, when the destination first appears.
    ///   - onOpenPost: Pushes a post's detail screen.
    ///   - onOpenProfile: Pushes another account's profile.
    ///   - onStub: Announces a feature that belongs to a later phase.
    ///   - onCompose: Opens the composer.
    ///   - ownerActions: Routes shown only on the viewer's own profile.
    ///   - safetyMenu: Builds the header's `…` menu.
    ///   - postSafetyMenu: Builds each timeline card's `…` menu.
    ///   - ownPost: Builds the Delete menu on the viewer's own cards.
    public init(
        makeViewModel: () -> ProfileViewModel,
        onOpenPost: @escaping @MainActor (Post) -> Void,
        onOpenProfile: @escaping @MainActor (String) -> Void = { _ in },
        onStub: @escaping @MainActor (String) -> Void = { _ in },
        onCompose: (@MainActor (ComposerContext) -> Void)? = nil,
        ownerActions: ProfileOwnerActions = ProfileOwnerActions(),
        safetyMenu: (@MainActor (SafetyTarget) -> SafetyMenuActions?)? = nil,
        postSafetyMenu: (@MainActor (Post) -> SafetyMenuActions?)? = nil,
        ownPost: (@MainActor (Post) -> OwnPostActions?)? = nil
    ) {
        self._viewModel = State(initialValue: makeViewModel())
        self.onOpenPost = onOpenPost
        self.onOpenProfile = onOpenProfile
        self.onStub = onStub
        self.onCompose = onCompose
        self.ownerActions = ownerActions
        self.safetyMenu = safetyMenu
        self.postSafetyMenu = postSafetyMenu
        self.ownPost = ownPost
    }

    public var body: some View {
        ProfileScreen(
            viewModel: viewModel,
            onOpenPost: onOpenPost,
            onOpenProfile: onOpenProfile,
            onStub: onStub,
            onCompose: onCompose,
            ownerActions: ownerActions,
            safetyMenu: safetyMenu,
            postSafetyMenu: postSafetyMenu,
            ownPost: ownPost
        )
    }
}

#Preview("Profile — someone else") {
    NavigationStack {
        ProfileScreen(
            viewModel: ProfileViewModel(
                handle: "yuki",
                service: ProfileServiceMock(scenario: .populated),
                feed: FeedServiceMock(scenario: .populated),
                analytics: RecordingAnalyticsClient()
            ),
            onOpenPost: { _ in }
        )
        .tnNavigationBar(title: "@yuki")
    }
    .preferredColorScheme(.dark)
}

#Preview("Profile — your own") {
    NavigationStack {
        ProfileScreen(
            viewModel: ProfileViewModel(
                handle: "aziz",
                service: ProfileServiceMock(scenario: .populated),
                feed: FeedServiceMock(scenario: .populated),
                analytics: RecordingAnalyticsClient()
            ),
            onOpenPost: { _ in },
            ownerActions: ProfileOwnerActions(
                onOpenAccount: {},
                onOpenPreferences: {},
                onSignOut: {}
            )
        )
        .tnNavigationBar(title: "@aziz")
    }
    .preferredColorScheme(.dark)
}

#Preview("Profile — unavailable") {
    NavigationStack {
        ProfileScreen(
            viewModel: ProfileViewModel(
                handle: "ghost",
                service: ProfileServiceMock(scenario: .notFound),
                feed: FeedServiceMock(scenario: .populated),
                analytics: RecordingAnalyticsClient()
            ),
            onOpenPost: { _ in }
        )
        .tnNavigationBar(title: "@ghost")
    }
    .preferredColorScheme(.dark)
}
