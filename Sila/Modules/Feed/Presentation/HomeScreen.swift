import SwiftUI

/// The home feed: four independent feeds behind one segmented control.
///
/// Each tab keeps its own posts and cursor, so switching back to a feed the
/// user has already read shows it instantly and issues no request.
@MainActor
public struct HomeScreen: View {

    @Bindable private var viewModel: HomeViewModel
    private let onOpenPost: @MainActor (Post) -> Void
    private let onStub: @MainActor (String) -> Void
    private let onCompose: (@MainActor (ComposerContext) -> Void)?
    private let onOpenPreferences: (@MainActor () -> Void)?

    /// - Parameters:
    ///   - viewModel: Owned by ``MainTabView`` so tab state survives navigation.
    ///   - onOpenPost: Pushes the detail screen.
    ///   - onStub: Announces a feature that belongs to a later phase.
    ///   - onCompose: Opens the Phase-4 composer. `nil` — the Phase-3 behaviour —
    ///     falls back to the stub toast, which is what
    ///     ``FeatureFlags/composer`` switches off to.
    ///   - onOpenPreferences: Opens the feed-preferences screen. `nil` — the
    ///     default — renders nothing at all, so every existing caller keeps the
    ///     screen it already had.
    public init(
        viewModel: HomeViewModel,
        onOpenPost: @escaping @MainActor (Post) -> Void,
        onStub: @escaping @MainActor (String) -> Void,
        onCompose: (@MainActor (ComposerContext) -> Void)? = nil,
        onOpenPreferences: (@MainActor () -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.onOpenPost = onOpenPost
        self.onStub = onStub
        self.onCompose = onCompose
        self.onOpenPreferences = onOpenPreferences
    }

    public var body: some View {
        VStack(spacing: 0) {
            SLSegmentedControl(
                items: FeedTab.allCases,
                selection: Binding(
                    get: { viewModel.selectedTab },
                    set: { tab in Task { await viewModel.select(tab) } }
                ),
                accessibilityHint: { $0.accessibilityHint },
                title: { $0.title }
            )

            preferencesBar

            TabView(
                selection: Binding(
                    get: { viewModel.selectedTab },
                    set: { tab in Task { await viewModel.select(tab) } }
                )
            ) {
                ForEach(FeedTab.allCases) { tab in
                    feedList(for: tab)
                        .tag(tab)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
        .tnScreenBackground()
        .task { await viewModel.loadIfNeeded(viewModel.selectedTab) }
        .tnToast($viewModel.toast)
    }

    // MARK: - Preferences entry point

    /// A link to the topic controls, on the one feed they affect.
    ///
    /// International is the only feed the server filters by topic, so the
    /// shortcut appears only there — putting it above Following or My Country
    /// would imply those are filtered too, which is the exact
    /// misunderstanding this feature has to avoid.
    @ViewBuilder
    private var preferencesBar: some View {
        if let onOpenPreferences, viewModel.selectedTab == .international {
            Button(action: onOpenPreferences) {
                HStack(spacing: SLSpacing.sm) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(SLColor.primary)

                    Text("Topics and muted countries")
                        .font(SLFont.caption)
                        .foregroundStyle(SLColor.textSecondary)

                    Spacer(minLength: 0)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(SLColor.textMuted)
                }
                .padding(.horizontal, SLSpacing.lg)
                .padding(.vertical, SLSpacing.sm)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Feed preferences"))
            .accessibilityHint(Text("Opens the topic and muted-country settings that filter this feed"))
        }
    }

    // MARK: - One feed

    @ViewBuilder
    private func feedList(for tab: FeedTab) -> some View {
        let state = viewModel.state(for: tab)

        ScrollView {
            if state.isLoading && !state.isPopulated {
                skeleton
            } else if let empty = state.emptyKind, !state.isPopulated {
                emptyState(empty, tab: tab)
                    .padding(.top, SLSpacing.xxl * 2)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(state.posts) { post in
                        PostCardView(post: post, actions: actions(for: post))
                            .task { await viewModel.loadMoreIfNeeded(currentPost: post, tab: tab) }

                        SLDivider()
                    }

                    if state.isLoadingMore {
                        ProgressView()
                            .tint(SLColor.primary)
                            .padding(SLSpacing.xl)
                            .accessibilityLabel(Text("Loading more posts"))
                    } else if !state.hasMore && state.isPopulated {
                        Text("You're all caught up.")
                            .font(SLFont.caption)
                            .foregroundStyle(SLColor.textMuted)
                            .padding(SLSpacing.xl)
                    }
                }
            }
        }
        .scrollDismissesKeyboard(.immediately)
        .refreshable { await viewModel.refresh(tab) }
    }

    private var skeleton: some View {
        VStack(spacing: SLSpacing.lg) {
            ForEach(0..<5, id: \.self) { _ in
                SLSkeletonRow(lineCount: 3)
                    .padding(.horizontal, SLSpacing.lg)
            }
        }
        .padding(.top, SLSpacing.lg)
        .accessibilityLabel(Text("Loading your feed"))
    }

    @ViewBuilder
    private func emptyState(_ kind: FeedEmptyKind, tab: FeedTab) -> some View {
        switch kind {
        case .noCountry:
            // The 409 the contract documents. It is an explainer, not a failure:
            // the flag comes from verified identity, so there is nothing to
            // retry until verification completes.
            SLEmptyState(
                icon: "flag.slash",
                title: "No verified country yet",
                subtitle: "My Country shows posts from your verified compatriots. Your country flag comes from your verified identity — never from your IP address — so it appears once verification completes.",
                tint: SLColor.secondary,
                actionTitle: "How verification works",
                action: { onStub("Identity verification") }
            )
            .padding(.horizontal, SLSpacing.lg)

        case .noPosts:
            SLEmptyState(
                icon: emptyIcon(for: tab),
                title: emptyTitle(for: tab),
                subtitle: emptySubtitle(for: tab),
                tint: SLColor.textSecondary
            )
            .padding(.horizontal, SLSpacing.lg)

        case let .failed(message):
            SLEmptyState(
                icon: "wifi.exclamationmark",
                title: "Couldn't load this feed",
                subtitle: message,
                tint: SLColor.danger,
                actionTitle: "Try again",
                action: { Task { await viewModel.refresh(tab) } }
            )
            .padding(.horizontal, SLSpacing.lg)
        }
    }

    private func emptyIcon(for tab: FeedTab) -> String {
        switch tab {
        case .following: return "person.2"
        case .myCountry: return "flag"
        case .international: return "globe"
        case .forYou: return "sparkles"
        }
    }

    private func emptyTitle(for tab: FeedTab) -> String {
        switch tab {
        case .following: return "You're not following anyone yet"
        case .myCountry: return "Nothing from your country yet"
        case .international: return "No international posts yet"
        case .forYou: return "Nothing to show yet"
        }
    }

    private func emptySubtitle(for tab: FeedTab) -> String {
        switch tab {
        case .following: return "Posts from accounts you follow appear here, newest first."
        case .myCountry: return "Posts from verified accounts in your country will appear here."
        case .international: return "Threads open to verified accounts worldwide will appear here."
        case .forYou: return "As Sila learns what you read, this feed fills up."
        }
    }

    // MARK: - Card wiring

    /// Opens the composer, or says the feature is not on.
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
            onMention: { _ in onStub("Profiles") },
            onHashtag: { _ in onStub("Hashtag search") },
            onOpenQuoted: onOpenPost,
            onStub: onStub
        )
    }
}

#Preview("HomeScreen — populated") {
    HomeScreen(
        viewModel: HomeViewModel(
            service: FeedServiceMock(scenario: .populated),
            analytics: RecordingAnalyticsClient()
        ),
        onOpenPost: { _ in },
        onStub: { _ in }
    )
    .preferredColorScheme(.dark)
}

#Preview("HomeScreen — no country") {
    HomeScreen(
        viewModel: HomeViewModel(
            service: FeedServiceMock(scenario: .unverifiedNoCountry),
            analytics: RecordingAnalyticsClient(),
            initialTab: .myCountry
        ),
        onOpenPost: { _ in },
        onStub: { _ in }
    )
    .preferredColorScheme(.dark)
}
