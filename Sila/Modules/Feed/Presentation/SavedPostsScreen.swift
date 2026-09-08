import SwiftUI

/// The viewer's saved posts. Reached from their own profile.
@MainActor
public struct SavedPostsScreen: View {

    @State private var viewModel: SavedPostsViewModel
    private let onOpenPost: @MainActor (Post) -> Void
    private let onOpenProfile: @MainActor (String) -> Void
    private let onCompose: (@MainActor (ComposerContext) -> Void)?
    private let onStub: @MainActor (String) -> Void
    private let postSafetyMenu: (@MainActor (Post) -> SafetyMenuActions?)?
    private let ownPost: (@MainActor (Post) -> OwnPostActions?)?
    /// Posts deleted this session, hidden without waiting for a refresh.
    private let hiddenPostIds: Set<UUID>

    /// - Parameters:
    ///   - viewModel: Owned here; built once by the caller.
    ///   - onOpenPost: Pushes a post's detail screen.
    ///   - onOpenProfile: Pushes an account's profile.
    ///   - onCompose: Opens the composer for a reply or a quote.
    ///   - onStub: Announces a feature that belongs to a later phase.
    ///   - postSafetyMenu: Builds each card's `…` menu.
    ///   - ownPost: Builds the Delete menu on the viewer's own cards.
    ///   - hiddenPostIds: Posts deleted this session.
    public init(
        viewModel: SavedPostsViewModel,
        onOpenPost: @escaping @MainActor (Post) -> Void,
        onOpenProfile: @escaping @MainActor (String) -> Void = { _ in },
        onCompose: (@MainActor (ComposerContext) -> Void)? = nil,
        onStub: @escaping @MainActor (String) -> Void = { _ in },
        postSafetyMenu: (@MainActor (Post) -> SafetyMenuActions?)? = nil,
        ownPost: (@MainActor (Post) -> OwnPostActions?)? = nil,
        hiddenPostIds: Set<UUID> = []
    ) {
        self._viewModel = State(initialValue: viewModel)
        self.onOpenPost = onOpenPost
        self.onOpenProfile = onOpenProfile
        self.onCompose = onCompose
        self.onStub = onStub
        self.postSafetyMenu = postSafetyMenu
        self.ownPost = ownPost
        self.hiddenPostIds = hiddenPostIds
    }

    public var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                content
            }
        }
        .background(SLColor.background)
        .navigationTitle(L10n.t("saved.title"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.load() }
        .refreshable { await viewModel.reload() }
        .tnToast($viewModel.toast)
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.loadState {
        case .idle, .loading:
            ProgressView()
                .tint(SLColor.primary)
                .padding(SLSpacing.xl)
                .frame(maxWidth: .infinity)

        case let .failed(message):
            SLEmptyState(
                icon: "exclamationmark.triangle",
                title: message,
                subtitle: L10n.t("feed.error.pullToRefresh"),
                tint: SLColor.textSecondary,
                actionTitle: L10n.t("feed.error.retry"),
                action: { Task { await viewModel.reload() } }
            )
            .padding(SLSpacing.lg)

        case .loaded:
            let visible = viewModel.posts.filter { !hiddenPostIds.contains($0.id) }
            if visible.isEmpty {
                SLEmptyState(
                    icon: "bookmark",
                    title: L10n.t("saved.empty.title"),
                    subtitle: L10n.t("saved.empty.subtitle"),
                    tint: SLColor.textSecondary
                )
                .padding(.horizontal, SLSpacing.lg)
                .padding(.vertical, SLSpacing.xl)
            } else {
                ForEach(visible) { post in
                    PostCardView(post: post, actions: actions(for: post))
                        .task { await viewModel.loadMoreIfNeeded(currentPost: post) }
                    SLDivider()
                }
                if viewModel.isLoadingMore {
                    ProgressView()
                        .tint(SLColor.primary)
                        .padding(SLSpacing.xl)
                        .accessibilityLabel(Text(L10n.t("feed.loadingMore")))
                }
            }
        }
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
            onOpenAuthor: { author in onOpenProfile(author.handle) },
            onStub: onStub,
            safetyMenu: postSafetyMenu,
            ownPost: ownPost
        )
    }

    private func compose(_ context: ComposerContext, fallback: String) {
        if let onCompose {
            onCompose(context)
        } else {
            onStub(fallback)
        }
    }
}
