import SwiftUI

/// A single post with its reply thread, and its parent above it when the post
/// is itself a reply.
///
/// The bar at the bottom is Phase 4's ``ReplyComposerBar`` when a composer
/// service is supplied, and the Phase-3 stub otherwise — so the feature flag
/// has a real off state. Either way it never lies: when `viewer.can_reply` is
/// `false` the bar shows the server's reason in human language instead of an
/// input that could only produce a 403.
@MainActor
public struct PostDetailScreen: View {

    @Bindable private var viewModel: PostDetailViewModel
    private let onOpenPost: @MainActor (Post) -> Void
    private let onOpenProfile: @MainActor (String) -> Void
    private let onStub: @MainActor (String) -> Void
    private let onDismiss: @MainActor (Post) -> Void
    private let onCompose: (@MainActor (ComposerContext) -> Void)?
    private let safetyMenu: (@MainActor (Post) -> SafetyMenuActions?)?
    /// Owns the reply draft. `nil` when Phase 4 is switched off, which is what
    /// puts the Phase-3 stub bar back.
    ///
    /// Held as `@State` so a re-render never throws away half-typed text.
    @State private var replyViewModel: ComposerViewModel?

    /// - Parameters:
    ///   - viewModel: Owns the thread.
    ///   - onOpenPost: Pushes another post (parent, quote, or reply).
    ///   - onOpenProfile: Pushes an account's profile — a tapped author or an
    ///     `@mention` anywhere in the thread.
    ///   - onStub: Announces a feature that belongs to a later phase.
    ///   - onDismiss: Called on disappear with the current post, so the feed can
    ///     adopt engagement changes made here.
    ///   - composerService: Enables the live reply bar. `nil` keeps the
    ///     Phase-3 stub, which is what ``FeatureFlags/composer`` switches off to.
    ///   - searchService: Backs `@mention` autocomplete inside the reply bar.
    ///   - author: The signed-in account. Replies inherit their parent's scope,
    ///     so this is only used for consistency with the sheet composer.
    ///   - analytics: Event sink for the reply composer.
    ///   - onCompose: Opens the composer sheet for a quote, or for a reply to a
    ///     post other than the focused one. `nil` falls back to the stub toast.
    public init(
        viewModel: PostDetailViewModel,
        onOpenPost: @escaping @MainActor (Post) -> Void,
        onStub: @escaping @MainActor (String) -> Void,
        onOpenProfile: @escaping @MainActor (String) -> Void = { _ in },
        onDismiss: @escaping @MainActor (Post) -> Void = { _ in },
        safetyMenu: (@MainActor (Post) -> SafetyMenuActions?)? = nil,
        composerService: ComposerServiceProtocol? = nil,
        searchService: SearchServiceProtocol? = nil,
        author: ComposerAuthor = ComposerAuthor(isVerified: false),
        analytics: AnalyticsClient = ConsoleAnalyticsClient(),
        onCompose: (@MainActor (ComposerContext) -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.onOpenPost = onOpenPost
        self.onOpenProfile = onOpenProfile
        self.onStub = onStub
        self.onDismiss = onDismiss
        self.onCompose = onCompose
        self.safetyMenu = safetyMenu

        guard let composerService else {
            self._replyViewModel = State(initialValue: nil)
            return
        }
        self._replyViewModel = State(
            initialValue: ComposerViewModel(
                context: .reply(to: viewModel.post),
                author: author,
                composer: composerService,
                search: searchService,
                analytics: analytics,
                onPosted: { [weak viewModel] posted in viewModel?.insert(replies: posted) }
            )
        )
    }

    public var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let parent = viewModel.parent {
                        parentContext(parent)
                    }

                    PostCardView(
                        post: viewModel.post,
                        style: .detail,
                        actions: actions(for: viewModel.post, allowOpen: false)
                    )

                    SLDivider()

                    repliesSection
                }
            }

            composerBar
        }
        .tnScreenBackground()
        .tnNavigationBar(title: "Post")
        .task { await viewModel.load() }
        // `load()` re-reads the post, and `viewer.can_reply` is computed per
        // request — so the bar adopts the fresh permission rather than the one
        // the feed happened to be holding.
        .onChange(of: viewModel.post) { _, fresh in
            replyViewModel?.updateReplyTarget(fresh)
        }
        // A block taken on a reply takes that reply out of the thread now. The
        // *focused* post's author is handled a level up, by pruning this whole
        // destination off the stack: blanking the top of a thread in place would
        // leave a reply list with nothing above it.
        .onChange(of: blockedRepliers) { previous, current in
            for handle in current.subtracting(previous) {
                viewModel.removeAuthor(handle)
            }
        }
        .onDisappear { onDismiss(viewModel.post) }
        .tnToast($viewModel.toast)
    }

    /// Everyone on this screen the viewer has now blocked.
    ///
    /// Derived from the same menus the cards draw, so there is one record of who
    /// is blocked rather than a second copy kept in step by hand.
    private var blockedRepliers: Set<String> {
        guard let safetyMenu else { return [] }
        var handles: Set<String> = []
        for reply in viewModel.replies where safetyMenu(reply)?.isBlocked == true {
            handles.insert(Handle.normalised(reply.author.handle))
        }
        return handles
    }

    // MARK: - Parent context

    private func parentContext(_ parent: Post) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Replying to")
                .font(SLFont.micro)
                .foregroundStyle(SLColor.textMuted)
                .padding(.horizontal, SLSpacing.lg)
                .padding(.top, SLSpacing.md)

            PostCardView(post: parent, actions: actions(for: parent))

            // The thread line that ties the parent to the focused post.
            Rectangle()
                .fill(SLColor.stroke)
                .frame(width: 2, height: 18)
                .padding(.leading, SLSpacing.lg + 21)

            SLDivider()
        }
    }

    // MARK: - Replies

    @ViewBuilder
    private var repliesSection: some View {
        if viewModel.isLoading && viewModel.replies.isEmpty {
            VStack(spacing: SLSpacing.lg) {
                ForEach(0..<3, id: \.self) { _ in
                    SLSkeletonRow(lineCount: 2)
                        .padding(.horizontal, SLSpacing.lg)
                }
            }
            .padding(.vertical, SLSpacing.lg)
            .accessibilityLabel(Text("Loading replies"))

        } else if viewModel.replies.isEmpty {
            SLEmptyState(
                icon: "bubble.left",
                title: "No replies yet",
                subtitle: viewModel.replyPermission.blockedMessage
                    ?? "Be the first verified human to reply.",
                tint: SLColor.textSecondary
            )
            .padding(.vertical, SLSpacing.xxl)

        } else {
            ForEach(viewModel.replies) { reply in
                PostCardView(post: reply, style: .reply, actions: actions(for: reply))
                    .task { await viewModel.loadMoreRepliesIfNeeded(currentReply: reply) }

                SLDivider()
            }

            if viewModel.isLoadingMoreReplies {
                ProgressView()
                    .tint(SLColor.primary)
                    .frame(maxWidth: .infinity)
                    .padding(SLSpacing.xl)
                    .accessibilityLabel(Text("Loading more replies"))
            }
        }
    }

    // MARK: - Composer bar

    @ViewBuilder
    private var composerBar: some View {
        if let replyViewModel {
            ReplyComposerBar(viewModel: replyViewModel)
        } else {
            stubComposerBar
        }
    }

    /// The Phase-3 bar, retained as ``FeatureFlags/composer``'s off state.
    @ViewBuilder
    private var stubComposerBar: some View {
        let permission = viewModel.replyPermission

        VStack(spacing: 0) {
            SLDivider()

            if let message = permission.blockedMessage {
                HStack(alignment: .center, spacing: SLSpacing.md) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(SLColor.warning)

                    Text(message)
                        .font(SLFont.caption)
                        .foregroundStyle(SLColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, SLSpacing.lg)
                .padding(.vertical, SLSpacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(SLColor.surface1)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text("Replies restricted. \(message)"))

            } else {
                HStack(spacing: SLSpacing.md) {
                    Text("Reply to \(viewModel.post.author.atHandle)")
                        .font(SLFont.body)
                        .foregroundStyle(SLColor.textMuted)
                        .lineLimit(1)

                    Spacer(minLength: 0)

                    SLButton(
                        "Reply",
                        variant: .primary,
                        size: .compact,
                        accessibilityHint: "Opens the reply composer",
                        action: { onStub("Replying") }
                    )
                    .frame(width: 92)
                }
                .padding(.horizontal, SLSpacing.lg)
                .padding(.vertical, SLSpacing.md)
                .frame(maxWidth: .infinity)
                .background(SLColor.surface1)
                .contentShape(Rectangle())
                .onTapGesture { onStub("Replying") }
                .accessibilityElement(children: .contain)
            }
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

    private func actions(for post: Post, allowOpen: Bool = true) -> PostCardActions {
        PostCardActions(
            onOpen: { post in if allowOpen { onOpenPost(post) } },
            onLike: { post in Task { await viewModel.toggleLike(post) } },
            onRepost: { post in Task { await viewModel.toggleRepost(post) } },
            onBookmark: { post in Task { await viewModel.toggleBookmark(post) } },
            onReply: { post in compose(.reply(to: post), fallback: "Replying") },
            onReplyBlocked: { post in viewModel.replyBlocked(post) },
            onQuote: { post in compose(.quote(post), fallback: "Quote posts") },
            onMention: { handle in onOpenProfile(handle) },
            onHashtag: { _ in onStub("Hashtag search") },
            onOpenQuoted: onOpenPost,
            onOpenAuthor: { author in onOpenProfile(author.handle) },
            onStub: onStub,
            safetyMenu: safetyMenu
        )
    }
}

#Preview("PostDetailScreen — repliable") {
    NavigationStack {
        PostDetailScreen(
            viewModel: PostDetailViewModel(
                post: FeedServiceMock.internationalRoot,
                service: FeedServiceMock(scenario: .populated),
                analytics: RecordingAnalyticsClient()
            ),
            onOpenPost: { _ in },
            onStub: { _ in }
        )
    }
    .preferredColorScheme(.dark)
}

#Preview("PostDetailScreen — country-locked") {
    NavigationStack {
        PostDetailScreen(
            viewModel: PostDetailViewModel(
                post: FeedServiceMock.countryThread,
                service: FeedServiceMock(scenario: .populated),
                analytics: RecordingAnalyticsClient()
            ),
            onOpenPost: { _ in },
            onStub: { _ in }
        )
    }
    .preferredColorScheme(.dark)
}
