import SwiftUI

/// A single post with its reply thread, and its parent above it when the post
/// is itself a reply.
///
/// The composer bar at the bottom is a Phase-4 stub, but it is **not** a lie:
/// when `viewer.can_reply` is `false` the bar shows the server's reason in
/// human language instead of a button that would fail.
@MainActor
public struct PostDetailScreen: View {

    @Bindable private var viewModel: PostDetailViewModel
    private let onOpenPost: @MainActor (Post) -> Void
    private let onStub: @MainActor (String) -> Void
    private let onDismiss: @MainActor (Post) -> Void

    /// - Parameters:
    ///   - viewModel: Owns the thread.
    ///   - onOpenPost: Pushes another post (parent, quote, or reply).
    ///   - onStub: Announces a feature that belongs to a later phase.
    ///   - onDismiss: Called on disappear with the current post, so the feed can
    ///     adopt engagement changes made here.
    public init(
        viewModel: PostDetailViewModel,
        onOpenPost: @escaping @MainActor (Post) -> Void,
        onStub: @escaping @MainActor (String) -> Void,
        onDismiss: @escaping @MainActor (Post) -> Void = { _ in }
    ) {
        self.viewModel = viewModel
        self.onOpenPost = onOpenPost
        self.onStub = onStub
        self.onDismiss = onDismiss
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

                    TNDivider()

                    repliesSection
                }
            }

            composerBar
        }
        .tnScreenBackground()
        .tnNavigationBar(title: "Post")
        .task { await viewModel.load() }
        .onDisappear { onDismiss(viewModel.post) }
        .tnToast($viewModel.toast)
    }

    // MARK: - Parent context

    private func parentContext(_ parent: Post) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Replying to")
                .font(TNFont.micro)
                .foregroundStyle(TNColor.textMuted)
                .padding(.horizontal, TNSpacing.lg)
                .padding(.top, TNSpacing.md)

            PostCardView(post: parent, actions: actions(for: parent))

            // The thread line that ties the parent to the focused post.
            Rectangle()
                .fill(TNColor.stroke)
                .frame(width: 2, height: 18)
                .padding(.leading, TNSpacing.lg + 21)

            TNDivider()
        }
    }

    // MARK: - Replies

    @ViewBuilder
    private var repliesSection: some View {
        if viewModel.isLoading && viewModel.replies.isEmpty {
            VStack(spacing: TNSpacing.lg) {
                ForEach(0..<3, id: \.self) { _ in
                    TNSkeletonRow(lineCount: 2)
                        .padding(.horizontal, TNSpacing.lg)
                }
            }
            .padding(.vertical, TNSpacing.lg)
            .accessibilityLabel(Text("Loading replies"))

        } else if viewModel.replies.isEmpty {
            TNEmptyState(
                icon: "bubble.left",
                title: "No replies yet",
                subtitle: viewModel.replyPermission.blockedMessage
                    ?? "Be the first verified human to reply.",
                tint: TNColor.textSecondary
            )
            .padding(.vertical, TNSpacing.xxl)

        } else {
            ForEach(viewModel.replies) { reply in
                PostCardView(post: reply, style: .reply, actions: actions(for: reply))
                    .task { await viewModel.loadMoreRepliesIfNeeded(currentReply: reply) }

                TNDivider()
            }

            if viewModel.isLoadingMoreReplies {
                ProgressView()
                    .tint(TNColor.primary)
                    .frame(maxWidth: .infinity)
                    .padding(TNSpacing.xl)
                    .accessibilityLabel(Text("Loading more replies"))
            }
        }
    }

    // MARK: - Composer bar (Phase 4 stub)

    @ViewBuilder
    private var composerBar: some View {
        let permission = viewModel.replyPermission

        VStack(spacing: 0) {
            TNDivider()

            if let message = permission.blockedMessage {
                HStack(alignment: .center, spacing: TNSpacing.md) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(TNColor.warning)

                    Text(message)
                        .font(TNFont.caption)
                        .foregroundStyle(TNColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, TNSpacing.lg)
                .padding(.vertical, TNSpacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(TNColor.surface1)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text("Replies restricted. \(message)"))

            } else {
                HStack(spacing: TNSpacing.md) {
                    Text("Reply to \(viewModel.post.author.atHandle)")
                        .font(TNFont.body)
                        .foregroundStyle(TNColor.textMuted)
                        .lineLimit(1)

                    Spacer(minLength: 0)

                    TNButton(
                        "Reply",
                        variant: .primary,
                        size: .compact,
                        accessibilityHint: "Opens the reply composer",
                        action: { onStub("Replying") }
                    )
                    .frame(width: 92)
                }
                .padding(.horizontal, TNSpacing.lg)
                .padding(.vertical, TNSpacing.md)
                .frame(maxWidth: .infinity)
                .background(TNColor.surface1)
                .contentShape(Rectangle())
                .onTapGesture { onStub("Replying") }
                .accessibilityElement(children: .contain)
            }
        }
    }

    // MARK: - Card wiring

    private func actions(for post: Post, allowOpen: Bool = true) -> PostCardActions {
        PostCardActions(
            onOpen: { post in if allowOpen { onOpenPost(post) } },
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
