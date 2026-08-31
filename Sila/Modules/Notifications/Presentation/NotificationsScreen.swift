import SwiftUI

/// Follows, likes, reposts, replies and mentions.
///
/// Three things about this screen are load-bearing rather than stylistic.
///
/// **Every row says what happened, in its own words.** "Noura liked your post"
/// and "Yuki replied to you" are different events with different urgency, and a
/// list of identical "new notification" rows would force somebody to open all
/// of them to find the one that mattered.
///
/// **A row whose post has been deleted still renders**, without an excerpt and
/// with a line saying so. Hiding it would silently rewrite what happened to
/// somebody, and "Sam mentioned you" remains true after the post is gone.
///
/// **Nothing is marked read by looking at it.** The only control that clears is
/// the one labelled "Mark all read", and opening a single row marks that row.
/// Both are deliberate acts, and neither can be undone — there is no endpoint
/// that makes a notification unread again.
@MainActor
public struct NotificationsScreen: View {

    @Bindable private var viewModel: NotificationsViewModel
    private let onOpenPost: (@MainActor (Post) -> Void)?
    private let onOpenProfile: (@MainActor (String) -> Void)?
    private let onOpenSettings: (@MainActor () -> Void)?

    /// - Parameters:
    ///   - viewModel: Owns the list, the cursor and the server's unread count.
    ///   - onOpenPost: Pushes a post's thread. `nil` makes post rows inert,
    ///     which is the honest state when the feed is switched off.
    ///   - onOpenProfile: Pushes somebody's page. `nil` for the same reason.
    ///   - onOpenSettings: Opens the five notification switches.
    public init(
        viewModel: NotificationsViewModel,
        onOpenPost: (@MainActor (Post) -> Void)? = nil,
        onOpenProfile: (@MainActor (String) -> Void)? = nil,
        onOpenSettings: (@MainActor () -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.onOpenPost = onOpenPost
        self.onOpenProfile = onOpenProfile
        self.onOpenSettings = onOpenSettings
    }

    public var body: some View {
        VStack(spacing: 0) {
            SLSegmentedControl(
                items: NotificationFilter.allCases,
                selection: Binding(
                    get: { viewModel.filter },
                    set: { value in Task { await viewModel.setFilter(value) } }
                ),
                accessibilityHint: { $0.accessibilityHint },
                title: { $0.title }
            )

            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .tnScreenBackground()
        .tnNavigationBar(title: "Notifications")
        .toolbar {
            if let onOpenSettings {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: onOpenSettings) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(SLColor.primary)
                    }
                    .accessibilityLabel(Text("Notification settings"))
                    .accessibilityHint(Text("Chooses which kinds of notification reach this list"))
                }
            }
        }
        .task { await viewModel.load() }
        .tnToast($viewModel.toast)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading && !viewModel.hasLoaded {
            loadingState
        } else if let error = viewModel.loadError {
            ScrollView {
                SLEmptyState(
                    icon: "wifi.exclamationmark",
                    title: "Couldn't load your notifications",
                    subtitle: error,
                    tint: SLColor.danger,
                    actionTitle: "Try again",
                    action: { Task { await viewModel.reload() } }
                )
                .padding(.horizontal, SLSpacing.lg)
                .padding(.top, SLSpacing.xxl)
            }
            .refreshable { await viewModel.reload(isRefresh: true) }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: SLSpacing.md) {
                    header

                    if viewModel.isEmpty {
                        emptyState
                    } else {
                        ForEach(viewModel.notifications) { notification in
                            row(notification)
                                .task { await viewModel.loadMoreIfNeeded(current: notification) }
                        }

                        if viewModel.isLoadingMore {
                            SLSkeletonRow(lineCount: 2)
                                .padding(.top, SLSpacing.xs)
                        }
                    }
                }
                .padding(.horizontal, SLSpacing.lg)
                .padding(.vertical, SLSpacing.lg)
            }
            .refreshable { await viewModel.reload(isRefresh: true) }
        }
    }

    private var loadingState: some View {
        VStack(spacing: SLSpacing.lg) {
            ForEach(0..<5, id: \.self) { _ in
                SLSkeletonRow(lineCount: 2).padding(.horizontal, SLSpacing.lg)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, SLSpacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel(Text("Loading your notifications"))
    }

    // MARK: - Header

    /// The count, and the only control that clears anything.
    ///
    /// The number is the server's. It is shown even when it is zero, because
    /// "nothing unread" is the answer to the question somebody opened this tab
    /// to ask.
    private var header: some View {
        HStack(spacing: SLSpacing.md) {
            Text(viewModel.unreadSummary)
                .font(SLFont.bodyEmphasis)
                .foregroundStyle(
                    viewModel.unreadCount > 0 ? SLColor.textPrimary : SLColor.textSecondary
                )
                .accessibilityLabel(Text(viewModel.unreadSummary))

            Spacer(minLength: 0)

            if viewModel.unreadCount > 0 {
                SLButton(
                    "Mark all read",
                    variant: .secondary,
                    size: .compact,
                    isLoading: viewModel.isMarkingAll,
                    isEnabled: viewModel.canMarkAllRead,
                    accessibilityHint: NotificationCopy.markAllHint,
                    asyncAction: { await viewModel.markAllRead() }
                )
                .frame(width: 148)
            }
        }
        .padding(.bottom, SLSpacing.xs)
    }

    // MARK: - Empty

    @ViewBuilder
    private var emptyState: some View {
        if viewModel.filter == .unread {
            SLEmptyState(
                icon: "checkmark.circle",
                title: NotificationCopy.emptyUnreadTitle,
                subtitle: NotificationCopy.emptyUnreadSubtitle(total: viewModel.unreadCount),
                tint: SLColor.secondary
            )
            .padding(.top, SLSpacing.xl)
        } else {
            SLEmptyState(
                icon: "bell",
                title: NotificationCopy.emptyTitle,
                subtitle: NotificationCopy.emptySubtitle,
                tint: SLColor.textSecondary
            )
            .padding(.top, SLSpacing.xl)
        }
    }

    // MARK: - Row

    private func row(_ notification: UserNotification) -> some View {
        SLCard(padding: SLSpacing.md) {
            HStack(alignment: .top, spacing: SLSpacing.md) {
                unreadDot(notification)

                ZStack(alignment: .bottomTrailing) {
                    SLAvatar(
                        url: notification.actor.avatarURL,
                        initials: notification.actor.initials,
                        size: .md,
                        isVerified: notification.actor.isVerified,
                        displayName: notification.actor.displayName
                    )

                    kindMarker(notification.kind)
                        .offset(x: 4, y: 4)
                }

                VStack(alignment: .leading, spacing: SLSpacing.xs) {
                    HStack(alignment: .firstTextBaseline, spacing: SLSpacing.xs) {
                        Text(notification.sentence)
                            .font(SLFont.body)
                            .foregroundStyle(SLColor.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)

                        if notification.actor.isVerified {
                            SLVerifiedBadge(size: 12, isPulsing: false)
                        }
                        SLCountryBadge(countryCode: notification.actor.countryCode)
                    }

                    excerpt(notification)

                    HStack(spacing: SLSpacing.sm) {
                        Text(RelativeTime.short(notification.createdAt))
                            .font(SLFont.micro)
                            .foregroundStyle(SLColor.textMuted)

                        Text(notification.actor.atHandle)
                            .font(SLFont.micro)
                            .foregroundStyle(SLColor.textMuted)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)

                if viewModel.isOpening(notification) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(SLColor.primary)
                        .accessibilityHidden(true)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { open(notification) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(Text(notification.accessibilityDescription))
        .accessibilityHint(Text(NotificationCopy.openHint(notification.kind)))
    }

    /// The unread marker. A dot, not a colour wash: the row has to stay legible
    /// and it has to keep looking like the read ones next to it.
    @ViewBuilder
    private func unreadDot(_ notification: UserNotification) -> some View {
        Circle()
            .fill(notification.read ? Color.clear : SLColor.primary)
            .frame(width: 8, height: 8)
            .padding(.top, SLSpacing.lg)
            .accessibilityHidden(true)
    }

    /// The little symbol that says which of the five this is.
    private func kindMarker(_ kind: NotificationKind) -> some View {
        ZStack {
            Circle()
                .fill(SLColor.surface1)
                .frame(width: 20, height: 20)
            Circle()
                .strokeBorder(SLColor.stroke, lineWidth: 1)
                .frame(width: 20, height: 20)
            Image(systemName: kind.icon)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(kind.tint)
        }
        .accessibilityHidden(true)
    }

    /// The post's first line — or the fact that there is no longer a post.
    @ViewBuilder
    private func excerpt(_ notification: UserNotification) -> some View {
        if let excerpt = notification.postExcerpt {
            Text(excerpt)
                .font(SLFont.caption)
                .foregroundStyle(SLColor.textSecondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        } else if notification.postWasDeleted {
            // The row stays. Dropping it would quietly edit somebody's history
            // to make a list tidier, and the event still happened.
            Text(NotificationCopy.deletedPost)
                .font(SLFont.caption)
                .foregroundStyle(SLColor.textMuted)
                .italic()
        }
    }

    // MARK: - Navigation

    private func open(_ notification: UserNotification) {
        Task {
            guard let destination = await viewModel.open(notification) else { return }
            switch destination {
            case let .post(post): onOpenPost?(post)
            case let .profile(handle): onOpenProfile?(handle)
            }
        }
    }
}

#Preview("Notifications — populated") {
    NavigationStack {
        NotificationsScreen(
            viewModel: NotificationsViewModel(
                service: NotificationsServiceMock(scenario: .populated),
                feed: FeedServiceMock(scenario: .populated),
                analytics: RecordingAnalyticsClient()
            ),
            onOpenSettings: {}
        )
    }
    .preferredColorScheme(.dark)
}

#Preview("Notifications — empty") {
    NavigationStack {
        NotificationsScreen(
            viewModel: NotificationsViewModel(
                service: NotificationsServiceMock(scenario: .empty),
                feed: FeedServiceMock(scenario: .empty),
                analytics: RecordingAnalyticsClient()
            )
        )
    }
    .preferredColorScheme(.dark)
}
