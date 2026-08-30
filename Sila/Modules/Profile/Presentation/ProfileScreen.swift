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
    /// Ends the session.
    public var onSignOut: (@MainActor () -> Void)?

    public init(
        onOpenAccount: (@MainActor () -> Void)? = nil,
        onOpenPreferences: (@MainActor () -> Void)? = nil,
        onSignOut: (@MainActor () -> Void)? = nil
    ) {
        self.onOpenAccount = onOpenAccount
        self.onOpenPreferences = onOpenPreferences
        self.onSignOut = onSignOut
    }

    /// `true` when nothing at all was supplied.
    public var isEmpty: Bool {
        onOpenAccount == nil && onOpenPreferences == nil && onSignOut == nil
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

    /// - Parameters:
    ///   - viewModel: Owns the profile and the timeline.
    ///   - onOpenPost: Pushes a post's detail screen.
    ///   - onOpenProfile: Pushes another account's profile — a mention, or the
    ///     author of a quoted post.
    ///   - onStub: Announces a feature that belongs to a later phase.
    ///   - onCompose: Opens the composer for a reply or a quote. `nil` falls
    ///     back to the stub toast.
    ///   - ownerActions: Routes shown only on the viewer's own profile.
    public init(
        viewModel: ProfileViewModel,
        onOpenPost: @escaping @MainActor (Post) -> Void,
        onOpenProfile: @escaping @MainActor (String) -> Void = { _ in },
        onStub: @escaping @MainActor (String) -> Void = { _ in },
        onCompose: (@MainActor (ComposerContext) -> Void)? = nil,
        ownerActions: ProfileOwnerActions = ProfileOwnerActions()
    ) {
        self.viewModel = viewModel
        self.onOpenPost = onOpenPost
        self.onOpenProfile = onOpenProfile
        self.onStub = onStub
        self.onCompose = onCompose
        self.ownerActions = ownerActions
    }

    public var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .tnScreenBackground()
            .task { await viewModel.load() }
            .tnToast($viewModel.toast)
    }

    // MARK: - Routing

    @ViewBuilder
    private var content: some View {
        switch viewModel.loadState {
        case .idle, .loading:
            skeleton

        case .unavailable:
            // No action, on purpose: the handle will not start existing because
            // somebody pressed a button. The owner routes stay reachable so the
            // Profile tab is never a trap.
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

        case let .failed(message):
            ScrollView {
                VStack(spacing: SLSpacing.lg) {
                    SLEmptyState(
                        icon: "wifi.exclamationmark",
                        title: "Couldn't load this profile",
                        subtitle: message,
                        tint: SLColor.danger,
                        actionTitle: "Try again",
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
        .accessibilityLabel(Text("Loading this profile"))
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

                if viewModel.isLoadingPosts && viewModel.posts.isEmpty {
                    VStack(spacing: SLSpacing.lg) {
                        ForEach(0..<3, id: \.self) { _ in
                            SLSkeletonRow(lineCount: 2).padding(.horizontal, SLSpacing.lg)
                        }
                    }
                    .padding(.vertical, SLSpacing.lg)
                    .accessibilityLabel(Text("Loading posts"))

                } else if let error = viewModel.postsError {
                    SLEmptyState(
                        icon: "wifi.exclamationmark",
                        title: "Couldn't load these posts",
                        subtitle: error,
                        tint: SLColor.danger,
                        actionTitle: "Try again",
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
                            .accessibilityLabel(Text("Loading more posts"))
                    } else if !viewModel.hasMore {
                        Text("That's every post here.")
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

    private var timelineHeading: some View {
        VStack(alignment: .leading, spacing: SLSpacing.xs) {
            Text("POSTS")
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
                }

                VStack(alignment: .leading, spacing: SLSpacing.xs) {
                    HStack(spacing: SLSpacing.sm) {
                        Text(profile.displayName)
                            .font(SLFont.displayM)
                            .foregroundStyle(SLColor.textPrimary)
                            .lineLimit(2)

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
                }

                if let bio = profile.bio {
                    Text(bio)
                        .font(SLFont.body)
                        .foregroundStyle(SLColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
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
        return "Verified since \(Self.monthFormatter.string(from: date))"
    }

    /// The three counters.
    ///
    /// Plain text rather than buttons: there is no endpoint that lists an
    /// account's followers, and a tappable number that opens nothing is a
    /// promise the backend cannot keep.
    private func counts(_ profile: Profile) -> some View {
        HStack(spacing: SLSpacing.xl) {
            count(profile.postCount, label: profile.postCount == 1 ? "Post" : "Posts")
            count(profile.followerCount, label: profile.followerCount == 1 ? "Follower" : "Followers")
            count(profile.followingCount, label: "Following")
            Spacer(minLength: 0)
        }
        .padding(.top, SLSpacing.xs)
    }

    private func count(_ value: Int, label: String) -> some View {
        HStack(spacing: SLSpacing.xs) {
            Text(PostCardView.count(value))
                .font(SLFont.bodyEmphasis)
                .monospacedDigit()
                .foregroundStyle(SLColor.textPrimary)
            Text(label)
                .font(SLFont.caption)
                .foregroundStyle(SLColor.textSecondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(value) \(label.lowercased())"))
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
                "Edit profile",
                variant: .secondary,
                size: .compact,
                icon: "square.and.pencil",
                accessibilityHint: "Opens your name, handle, bio and picture in account settings",
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
                        title: "Account",
                        detail: "Your name, handle, picture, email, password — and how to "
                            + "download or delete everything.",
                        hint: "Opens your profile details, sign-in credentials, data export "
                            + "and account deletion",
                        open: open
                    )
                }

                if let open = ownerActions.onOpenPreferences {
                    settingsEntry(
                        icon: "slider.horizontal.3",
                        title: "Feed preferences",
                        detail: "Topics, muted topics and muted countries — and how posts get labelled.",
                        hint: "Opens topic interests, muted topics and muted countries, and "
                            + "explains how posts are labelled",
                        open: open
                    )
                }

                if let signOut = ownerActions.onSignOut {
                    SLButton(
                        "Sign out",
                        variant: .ghost,
                        size: .compact,
                        accessibilityHint: "Ends your session and returns to the welcome screen",
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
            onReply: { post in compose(.reply(to: post), fallback: "Replying") },
            onReplyBlocked: { post in viewModel.replyBlocked(post) },
            onQuote: { post in compose(.quote(post), fallback: "Quote posts") },
            onMention: { handle in onOpenProfile(handle) },
            onHashtag: { _ in onStub("Hashtag search") },
            onOpenQuoted: onOpenPost,
            // Every author on this page is the person whose profile it is,
            // except inside a quote card — so this only ever navigates
            // somewhere new, and never pushes a copy of the current screen.
            onOpenAuthor: { author in
                guard author.handle != viewModel.handle else { return }
                onOpenProfile(author.handle)
            },
            onStub: onStub
        )
    }

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMM y")
        return formatter
    }()
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

    /// - Parameters:
    ///   - makeViewModel: Called **once**, when the destination first appears.
    ///   - onOpenPost: Pushes a post's detail screen.
    ///   - onOpenProfile: Pushes another account's profile.
    ///   - onStub: Announces a feature that belongs to a later phase.
    ///   - onCompose: Opens the composer.
    ///   - ownerActions: Routes shown only on the viewer's own profile.
    public init(
        makeViewModel: () -> ProfileViewModel,
        onOpenPost: @escaping @MainActor (Post) -> Void,
        onOpenProfile: @escaping @MainActor (String) -> Void = { _ in },
        onStub: @escaping @MainActor (String) -> Void = { _ in },
        onCompose: (@MainActor (ComposerContext) -> Void)? = nil,
        ownerActions: ProfileOwnerActions = ProfileOwnerActions()
    ) {
        self._viewModel = State(initialValue: makeViewModel())
        self.onOpenPost = onOpenPost
        self.onOpenProfile = onOpenProfile
        self.onStub = onStub
        self.onCompose = onCompose
        self.ownerActions = ownerActions
    }

    public var body: some View {
        ProfileScreen(
            viewModel: viewModel,
            onOpenPost: onOpenPost,
            onOpenProfile: onOpenProfile,
            onStub: onStub,
            onCompose: onCompose,
            ownerActions: ownerActions
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
