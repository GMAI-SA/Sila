import SwiftUI

/// Every post that carries one hashtag, in the order the viewer keeps.
///
/// The order chips sit under the title and remember themselves on the
/// account — "Top" chosen here is "Top" on the next tag, on every device.
@MainActor
public struct HashtagScreen: View {

    @State private var viewModel: HashtagViewModel
    private let onOpenPost: @MainActor (Post) -> Void
    private let onOpenProfile: @MainActor (String) -> Void
    private let onOpenHashtag: @MainActor (String) -> Void
    private let onOpenRoom: (@MainActor (RoomCard) -> Void)?
    private let onCompose: (@MainActor (ComposerContext) -> Void)?
    private let onStub: @MainActor (String) -> Void
    private let postSafetyMenu: (@MainActor (Post) -> SafetyMenuActions?)?
    private let ownPost: (@MainActor (Post) -> OwnPostActions?)?
    private let hiddenPostIds: Set<UUID>

    public init(
        viewModel: HashtagViewModel,
        onOpenPost: @escaping @MainActor (Post) -> Void,
        onOpenProfile: @escaping @MainActor (String) -> Void = { _ in },
        onOpenHashtag: @escaping @MainActor (String) -> Void = { _ in },
        onOpenRoom: (@MainActor (RoomCard) -> Void)? = nil,
        onCompose: (@MainActor (ComposerContext) -> Void)? = nil,
        onStub: @escaping @MainActor (String) -> Void = { _ in },
        postSafetyMenu: (@MainActor (Post) -> SafetyMenuActions?)? = nil,
        ownPost: (@MainActor (Post) -> OwnPostActions?)? = nil,
        hiddenPostIds: Set<UUID> = []
    ) {
        self._viewModel = State(initialValue: viewModel)
        self.onOpenPost = onOpenPost
        self.onOpenProfile = onOpenProfile
        self.onOpenHashtag = onOpenHashtag
        self.onOpenRoom = onOpenRoom
        self.onCompose = onCompose
        self.onStub = onStub
        self.postSafetyMenu = postSafetyMenu
        self.ownPost = ownPost
        self.hiddenPostIds = hiddenPostIds
    }

    public var body: some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    content
                } header: {
                    header
                }
            }
        }
        .background(SLColor.background)
        .tnNavigationBar(title: viewModel.hashtag)
        .task { await viewModel.load() }
        .refreshable { await viewModel.reload() }
        .tnToast($viewModel.toast)
    }

    /// The count and the order chips. Pinned, so the order is one tap away
    /// however far somebody has scrolled.
    private var header: some View {
        VStack(alignment: .leading, spacing: SLSpacing.sm) {
            HStack(spacing: SLSpacing.sm) {
                Text(viewModel.hashtag)
                    .font(SLFont.displayM)
                    .foregroundStyle(SLColor.textPrimary)
                    .lineLimit(1)
                    .slContentDirection(TextDirection.resolve(languageCode: nil, text: viewModel.hashtag))
                Spacer(minLength: 0)
                if viewModel.loadState == .loaded {
                    Text(L10n.plural("feed.hashtag.postCount", viewModel.postCount))
                        .font(SLFont.caption)
                        .foregroundStyle(SLColor.textSecondary)
                }
            }
            .padding(.horizontal, SLSpacing.lg)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: SLSpacing.sm) {
                    ForEach(HashtagSort.allCases) { sort in
                        SLChip(
                            sort.title,
                            icon: sort.icon,
                            isSelected: sort == viewModel.sort,
                            accessibilityHint: L10n.t("feed.hashtag.sort.a11yHint"),
                            onTap: { Task { await viewModel.select(sort) } }
                        )
                        .accessibilityIdentifier("hashtag.sort.\(sort.rawValue)")
                    }
                }
                .padding(.horizontal, SLSpacing.lg)
            }
            .accessibilityLabel(Text(L10n.t("feed.hashtag.sort.a11yLabel")))

            SLDivider()
        }
        .padding(.top, SLSpacing.sm)
        .background(SLColor.background)
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
                    icon: "number",
                    title: L10n.t("feed.hashtag.empty.title", viewModel.hashtag),
                    subtitle: L10n.t("feed.hashtag.empty.subtitle"),
                    tint: SLColor.textSecondary,
                    actionTitle: onCompose == nil ? nil : L10n.t("feed.hashtag.empty.action"),
                    action: onCompose == nil ? nil : { onCompose?(.newPost) }
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
            // Another tag inside a post on this page opens that tag's page —
            // unless it is this one, which is already open.
            onHashtag: { tag in
                guard HashtagViewModel.normalised(tag) != viewModel.tag else { return }
                onOpenHashtag(tag)
            },
            onOpenRoom: onOpenRoom,
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
