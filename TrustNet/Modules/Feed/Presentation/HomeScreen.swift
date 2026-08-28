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

    /// - Parameters:
    ///   - viewModel: Owned by ``MainTabView`` so tab state survives navigation.
    ///   - onOpenPost: Pushes the detail screen.
    ///   - onStub: Announces a feature that belongs to a later phase.
    public init(
        viewModel: HomeViewModel,
        onOpenPost: @escaping @MainActor (Post) -> Void,
        onStub: @escaping @MainActor (String) -> Void
    ) {
        self.viewModel = viewModel
        self.onOpenPost = onOpenPost
        self.onStub = onStub
    }

    public var body: some View {
        VStack(spacing: 0) {
            TNSegmentedControl(
                items: FeedTab.allCases,
                selection: Binding(
                    get: { viewModel.selectedTab },
                    set: { tab in Task { await viewModel.select(tab) } }
                ),
                accessibilityHint: { $0.accessibilityHint },
                title: { $0.title }
            )

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

    // MARK: - One feed

    @ViewBuilder
    private func feedList(for tab: FeedTab) -> some View {
        let state = viewModel.state(for: tab)

        ScrollView {
            if state.isLoading && !state.isPopulated {
                skeleton
            } else if let empty = state.emptyKind, !state.isPopulated {
                emptyState(empty, tab: tab)
                    .padding(.top, TNSpacing.xxl * 2)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(state.posts) { post in
                        PostCardView(post: post, actions: actions(for: post))
                            .task { await viewModel.loadMoreIfNeeded(currentPost: post, tab: tab) }

                        TNDivider()
                    }

                    if state.isLoadingMore {
                        ProgressView()
                            .tint(TNColor.primary)
                            .padding(TNSpacing.xl)
                            .accessibilityLabel(Text("Loading more posts"))
                    } else if !state.hasMore && state.isPopulated {
                        Text("You're all caught up.")
                            .font(TNFont.caption)
                            .foregroundStyle(TNColor.textMuted)
                            .padding(TNSpacing.xl)
                    }
                }
            }
        }
        .scrollDismissesKeyboard(.immediately)
        .refreshable { await viewModel.refresh(tab) }
    }

    private var skeleton: some View {
        VStack(spacing: TNSpacing.lg) {
            ForEach(0..<5, id: \.self) { _ in
                TNSkeletonRow(lineCount: 3)
                    .padding(.horizontal, TNSpacing.lg)
            }
        }
        .padding(.top, TNSpacing.lg)
        .accessibilityLabel(Text("Loading your feed"))
    }

    @ViewBuilder
    private func emptyState(_ kind: FeedEmptyKind, tab: FeedTab) -> some View {
        switch kind {
        case .noCountry:
            // The 409 the contract documents. It is an explainer, not a failure:
            // the flag comes from verified identity, so there is nothing to
            // retry until verification completes.
            TNEmptyState(
                icon: "flag.slash",
                title: "No verified country yet",
                subtitle: "My Country shows posts from your verified compatriots. Your country flag comes from your verified identity — never from your IP address — so it appears once verification completes.",
                tint: TNColor.secondary,
                actionTitle: "How verification works",
                action: { onStub("Identity verification") }
            )
            .padding(.horizontal, TNSpacing.lg)

        case .noPosts:
            TNEmptyState(
                icon: emptyIcon(for: tab),
                title: emptyTitle(for: tab),
                subtitle: emptySubtitle(for: tab),
                tint: TNColor.textSecondary
            )
            .padding(.horizontal, TNSpacing.lg)

        case let .failed(message):
            TNEmptyState(
                icon: "wifi.exclamationmark",
                title: "Couldn't load this feed",
                subtitle: message,
                tint: TNColor.danger,
                actionTitle: "Try again",
                action: { Task { await viewModel.refresh(tab) } }
            )
            .padding(.horizontal, TNSpacing.lg)
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
        case .forYou: return "As TrustNet learns what you read, this feed fills up."
        }
    }

    // MARK: - Card wiring

    private func actions(for post: Post) -> PostCardActions {
        PostCardActions(
            onOpen: onOpenPost,
            onLike: { post in Task { await viewModel.toggleLike(post) } },
            onRepost: { post in Task { await viewModel.toggleRepost(post) } },
            onBookmark: { post in Task { await viewModel.toggleBookmark(post) } },
            onReply: { _ in onStub("Replying") },
            onReplyBlocked: { post in viewModel.replyBlocked(post) },
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
