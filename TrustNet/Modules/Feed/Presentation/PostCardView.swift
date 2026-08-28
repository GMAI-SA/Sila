import SwiftUI
import UIKit

/// Everything a ``PostCardView`` can hand back to its host.
///
/// Grouped into one value so the card's signature does not grow a new argument
/// every time a screen wants another hook — Phase 7 reuses the card as-is.
public struct PostCardActions {

    /// The card body was tapped: open the detail screen.
    public var onOpen: @MainActor (Post) -> Void
    /// Like button.
    public var onLike: @MainActor (Post) -> Void
    /// Repost button.
    public var onRepost: @MainActor (Post) -> Void
    /// Bookmark button.
    public var onBookmark: @MainActor (Post) -> Void
    /// Reply button, only called when the viewer is allowed to reply.
    public var onReply: @MainActor (Post) -> Void
    /// Reply button pressed while `viewer.can_reply` is `false`.
    public var onReplyBlocked: @MainActor (Post) -> Void
    /// "Quote" chosen from the long-press menu — opens a new post that embeds
    /// this one. Quoting is not restricted by the quoted post's scope: the
    /// quote is a post of the author's own, with its own audience.
    public var onQuote: @MainActor (Post) -> Void
    /// An `@mention` was tapped; the payload has no leading `@`.
    public var onMention: @MainActor (String) -> Void
    /// A `#hashtag` was tapped; the payload has no leading `#`.
    public var onHashtag: @MainActor (String) -> Void
    /// The embedded quote card was tapped.
    public var onOpenQuoted: @MainActor (Post) -> Void
    /// A long-press menu item with no backend yet (Report / Not interested).
    public var onStub: @MainActor (String) -> Void

    /// Creates an action set. Every hook defaults to doing nothing, so a
    /// preview or a read-only surface only supplies what it needs.
    public init(
        onOpen: @escaping @MainActor (Post) -> Void = { _ in },
        onLike: @escaping @MainActor (Post) -> Void = { _ in },
        onRepost: @escaping @MainActor (Post) -> Void = { _ in },
        onBookmark: @escaping @MainActor (Post) -> Void = { _ in },
        onReply: @escaping @MainActor (Post) -> Void = { _ in },
        onReplyBlocked: @escaping @MainActor (Post) -> Void = { _ in },
        onQuote: @escaping @MainActor (Post) -> Void = { _ in },
        onMention: @escaping @MainActor (String) -> Void = { _ in },
        onHashtag: @escaping @MainActor (String) -> Void = { _ in },
        onOpenQuoted: @escaping @MainActor (Post) -> Void = { _ in },
        onStub: @escaping @MainActor (String) -> Void = { _ in }
    ) {
        self.onOpen = onOpen
        self.onLike = onLike
        self.onRepost = onRepost
        self.onBookmark = onBookmark
        self.onReply = onReply
        self.onReplyBlocked = onReplyBlocked
        self.onQuote = onQuote
        self.onMention = onMention
        self.onHashtag = onHashtag
        self.onOpenQuoted = onOpenQuoted
        self.onStub = onStub
    }
}

/// A post, as it appears in a feed or at the top of a thread.
///
/// **Exported.** Phase 7 renders profile timelines with this exact component,
/// which is why the model, the actions and the style are all public and why the
/// card owns no data of its own beyond animation state.
///
/// The header is deliberately ordered *name → checkmark → country flag*: the
/// flag is the product's differentiator, and it renders only when the author's
/// verified identity supplies a country. There is no IP fallback, and there
/// never will be.
///
/// ```swift
/// PostCardView(post: post, actions: .init(onOpen: { router.open($0) }))
/// ```
@MainActor
public struct PostCardView: View {

    /// Where the card is being shown.
    public enum Style: Equatable, Sendable {
        /// A row in a scrolling feed.
        case feed
        /// The focused post at the top of ``PostDetailScreen`` — larger text,
        /// an absolute timestamp, and the reply-block reason spelled out.
        case detail
        /// A reply inside a thread.
        case reply
    }

    private let post: Post
    private let style: Style
    private let actions: PostCardActions

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var likeScale: CGFloat = 1

    /// Creates a card.
    /// - Parameters:
    ///   - post: What to render.
    ///   - style: Presentation context. Defaults to ``Style/feed``.
    ///   - actions: Callbacks. Defaults to an inert set.
    public init(post: Post, style: Style = .feed, actions: PostCardActions = PostCardActions()) {
        self.post = post
        self.style = style
        self.actions = actions
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: TNSpacing.sm) {
            HStack(alignment: .top, spacing: TNSpacing.md) {
                TNAvatar(
                    url: post.author.avatarURL,
                    initials: post.author.initials,
                    size: style == .detail ? .lg : .md,
                    isVerified: post.author.isVerified,
                    displayName: post.author.displayName
                )

                VStack(alignment: .leading, spacing: TNSpacing.xs) {
                    header
                    scopeChip
                }
            }

            postText
                .padding(.leading, style == .detail ? 0 : 56)

            if let quoted = post.quotedPost {
                QuotedPostCard(post: quoted, onTap: { actions.onOpenQuoted(quoted) })
                    .padding(.leading, style == .detail ? 0 : 56)
            }

            if style == .detail {
                detailFooter
            }

            engagementRow
                .padding(.leading, style == .detail ? 0 : 52)
        }
        .padding(.horizontal, TNSpacing.lg)
        .padding(.vertical, TNSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { actions.onOpen(post) }
        .contextMenu { longPressMenu }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(accessibilitySummary))
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: TNSpacing.xs) {
                Text(post.author.displayName)
                    .font(TNFont.bodyEmphasis)
                    .foregroundStyle(TNColor.textPrimary)
                    .lineLimit(1)

                if post.author.isVerified {
                    TNVerifiedBadge(size: 15, isPulsing: false)
                }

                // The country-verified flag. Absent when the identity does not
                // carry one — never guessed.
                TNCountryBadge(countryCode: post.author.countryCode)
            }

            HStack(spacing: TNSpacing.xs) {
                Text(post.author.atHandle)
                    .font(TNFont.caption)
                    .foregroundStyle(TNColor.textSecondary)
                    .lineLimit(1)

                Text("·")
                    .font(TNFont.caption)
                    .foregroundStyle(TNColor.textMuted)

                Text(RelativeTime.short(post.createdAt))
                    .font(TNFont.caption)
                    .foregroundStyle(TNColor.textSecondary)
                    .accessibilityLabel(Text("Posted \(RelativeTime.accessible(post.createdAt))"))
            }
        }
    }

    private var scopeChip: some View {
        let scope = ScopePresentation.make(for: post)
        return HStack(spacing: TNSpacing.xs) {
            Image(systemName: scope.icon)
                .font(.system(size: 10, weight: .semibold))
            Text(scope.label)
                .font(TNFont.micro)
                .lineLimit(1)
        }
        .foregroundStyle(scopeTint)
        .padding(.horizontal, TNSpacing.sm)
        .padding(.vertical, 2)
        .background(Capsule().fill(scopeTint.opacity(0.12)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(scope.accessibilityLabel))
    }

    private var scopeTint: Color {
        switch post.scope {
        case .international: return TNColor.primary
        case .country: return TNColor.secondary
        case .region: return TNColor.warning
        }
    }

    // MARK: - Body text

    private var postText: some View {
        Text(attributedText)
            .font(style == .detail ? TNFont.displayM : TNFont.body)
            .foregroundStyle(TNColor.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .multilineTextAlignment(.leading)
            .environment(\.openURL, OpenURLAction { url in
                guard let entity = PostEntityLink.parse(url) else { return .systemAction }
                switch entity {
                case let .mention(handle): actions.onMention(handle)
                case let .hashtag(tag): actions.onHashtag(tag)
                }
                return .handled
            })
    }

    /// Post text with `@mentions` and `#hashtags` tinted and tappable.
    private var attributedText: AttributedString {
        var result = AttributedString()
        for token in PostTextParser.tokenize(post.text) {
            switch token {
            case let .plain(value):
                result.append(AttributedString(value))

            case let .mention(handle):
                result.append(entityRun("@\(handle)", link: PostEntityLink.mention(handle).url))

            case let .hashtag(tag):
                result.append(entityRun("#\(tag)", link: PostEntityLink.hashtag(tag).url))
            }
        }
        return result
    }

    private func entityRun(_ text: String, link: URL?) -> AttributedString {
        var run = AttributedString(text)
        run.foregroundColor = TNColor.primary
        // A tag that cannot be percent-encoded into a URL still renders — it
        // just is not tappable. Better than dropping the characters.
        if let link { run.link = link }
        return run
    }

    // MARK: - Detail extras

    @ViewBuilder
    private var detailFooter: some View {
        VStack(alignment: .leading, spacing: TNSpacing.sm) {
            Text(Self.absoluteFormatter.string(from: post.createdAt))
                .font(TNFont.caption)
                .foregroundStyle(TNColor.textMuted)

            if post.metrics.views > 0 {
                Text("\(Self.count(post.metrics.views)) views")
                    .font(TNFont.caption)
                    .foregroundStyle(TNColor.textMuted)
            }

            if let message = ReplyPermission.make(for: post).blockedMessage {
                HStack(alignment: .top, spacing: TNSpacing.sm) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(TNColor.warning)
                    Text(message)
                        .font(TNFont.caption)
                        .foregroundStyle(TNColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(TNSpacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: TNRadius.md)
                        .fill(TNColor.warning.opacity(0.08))
                )
                .accessibilityElement(children: .combine)
            }
        }
    }

    // MARK: - Engagement

    private var engagementRow: some View {
        HStack(spacing: 0) {
            replyButton

            engagementButton(
                icon: "arrow.2.squarepath",
                count: post.metrics.reposts,
                isOn: post.viewer.reposted,
                tint: TNColor.secondary,
                label: post.viewer.reposted ? "Undo repost" : "Repost",
                hint: post.viewer.reposted ? "Removes your repost" : "Shares this post to your followers",
                action: { actions.onRepost(post) }
            )

            likeButton

            engagementButton(
                icon: post.viewer.bookmarked ? "bookmark.fill" : "bookmark",
                count: post.metrics.bookmarks,
                isOn: post.viewer.bookmarked,
                tint: TNColor.primary,
                label: post.viewer.bookmarked ? "Remove bookmark" : "Bookmark",
                hint: post.viewer.bookmarked ? "Removes this post from your bookmarks" : "Saves this post to your bookmarks",
                action: { actions.onBookmark(post) }
            )

            ShareLink(item: shareText) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 14))
                    .foregroundStyle(TNColor.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(Text("Share"))
            .accessibilityHint(Text("Opens the share sheet with this post's text"))
        }
        .padding(.top, TNSpacing.xs)
    }

    private var replyButton: some View {
        let permission = ReplyPermission.make(for: post)
        return Button {
            if permission.canReply {
                actions.onReply(post)
            } else {
                actions.onReplyBlocked(post)
            }
        } label: {
            HStack(spacing: TNSpacing.xs) {
                Image(systemName: permission.canReply ? "bubble.left" : "bubble.left.slash")
                    .font(.system(size: 14))
                if post.metrics.replies > 0 {
                    Text(Self.count(post.metrics.replies)).font(TNFont.micro)
                }
            }
            .foregroundStyle(permission.canReply ? TNColor.textSecondary : TNColor.textMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(permission.canReply ? "Reply" : "Replies restricted"))
        .accessibilityHint(Text(permission.blockedMessage ?? "Writes a reply to this post"))
    }

    private var likeButton: some View {
        Button {
            if !reduceMotion {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.42)) { likeScale = 1.35 }
                withAnimation(.spring(response: 0.32, dampingFraction: 0.7).delay(0.1)) { likeScale = 1 }
            }
            actions.onLike(post)
        } label: {
            HStack(spacing: TNSpacing.xs) {
                Image(systemName: post.viewer.liked ? "heart.fill" : "heart")
                    .font(.system(size: 14))
                    .scaleEffect(post.viewer.liked ? likeScale : 1)
                if post.metrics.likes > 0 {
                    Text(Self.count(post.metrics.likes)).font(TNFont.micro)
                }
            }
            .foregroundStyle(post.viewer.liked ? TNColor.danger : TNColor.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(post.viewer.liked ? "Unlike" : "Like"))
        .accessibilityValue(Text("\(post.metrics.likes) likes"))
        .accessibilityHint(Text(post.viewer.liked ? "Removes your like" : "Likes this post"))
    }

    private func engagementButton(
        icon: String,
        count: Int,
        isOn: Bool,
        tint: Color,
        label: String,
        hint: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: TNSpacing.xs) {
                Image(systemName: icon).font(.system(size: 14))
                if count > 0 {
                    Text(Self.count(count)).font(TNFont.micro)
                }
            }
            .foregroundStyle(isOn ? tint : TNColor.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text("\(count)"))
        .accessibilityHint(Text(hint))
    }

    // MARK: - Long-press menu

    @ViewBuilder
    private var longPressMenu: some View {
        Button {
            actions.onQuote(post)
        } label: {
            Label("Quote", systemImage: "quote.bubble")
        }

        Button {
            actions.onBookmark(post)
        } label: {
            Label(post.viewer.bookmarked ? "Remove Bookmark" : "Bookmark", systemImage: "bookmark")
        }

        Button {
            UIPasteboard.general.string = post.text
        } label: {
            Label("Copy Text", systemImage: "doc.on.doc")
        }

        ShareLink(item: shareText) {
            Label("Share", systemImage: "square.and.arrow.up")
        }

        Button {
            actions.onStub("Not interested")
        } label: {
            Label("Not Interested", systemImage: "hand.thumbsdown")
        }

        Button(role: .destructive) {
            actions.onStub("Report")
        } label: {
            Label("Report", systemImage: "flag")
        }
    }

    // MARK: - Text helpers

    /// What the share sheet carries. No permalink is fabricated — the backend
    /// does not expose a public post URL yet.
    private var shareText: String {
        "\(post.author.displayName) (\(post.author.atHandle)) on TrustNet:\n\n\(post.text)"
    }

    private var accessibilitySummary: String {
        var parts = [post.author.displayName]
        if post.author.isVerified { parts.append("verified") }
        if let label = CountryCode.accessibilityLabel(post.author.countryCode) { parts.append(label) }
        parts.append(post.author.atHandle)
        parts.append(RelativeTime.accessible(post.createdAt))
        parts.append(ScopePresentation.make(for: post).accessibilityLabel)
        parts.append(post.text)
        return parts.joined(separator: ". ")
    }

    /// Compact counts: `1200` → `"1.2K"`. Pure, so it is testable off the main actor.
    nonisolated static func count(_ value: Int) -> String {
        switch value {
        case ..<1_000:
            return String(value)
        case ..<1_000_000:
            let thousands = Double(value) / 1_000
            return thousands < 10
                ? String(format: "%.1fK", thousands)
                : "\(Int(thousands))K"
        default:
            let millions = Double(value) / 1_000_000
            return millions < 10
                ? String(format: "%.1fM", millions)
                : "\(Int(millions))M"
        }
    }

    private static let absoluteFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

// MARK: - Quote card

/// The one-level-deep quoted post embedded inside a ``PostCardView``.
@MainActor
struct QuotedPostCard: View {

    let post: Post
    let onTap: @MainActor () -> Void

    var body: some View {
        TNCard(
            padding: TNSpacing.md,
            accessibilityLabel: "Quoted post by \(post.author.displayName)",
            accessibilityHint: "Opens the quoted post",
            onTap: onTap
        ) {
            VStack(alignment: .leading, spacing: TNSpacing.xs) {
                HStack(spacing: TNSpacing.xs) {
                    TNAvatar(
                        url: post.author.avatarURL,
                        initials: post.author.initials,
                        size: .sm,
                        isVerified: false,
                        displayName: post.author.displayName
                    )
                    Text(post.author.displayName)
                        .font(TNFont.caption)
                        .foregroundStyle(TNColor.textPrimary)
                        .lineLimit(1)
                    if post.author.isVerified {
                        TNVerifiedBadge(size: 12, isPulsing: false)
                    }
                    TNCountryBadge(countryCode: post.author.countryCode)
                    Text(post.author.atHandle)
                        .font(TNFont.micro)
                        .foregroundStyle(TNColor.textMuted)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(RelativeTime.short(post.createdAt))
                        .font(TNFont.micro)
                        .foregroundStyle(TNColor.textMuted)
                }

                Text(post.text)
                    .font(TNFont.bodyLight)
                    .foregroundStyle(TNColor.textSecondary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Entity links

/// The in-text entities the card turns into tappable links.
///
/// Rendered as a private `trustnet://` URL because `AttributedString` has no
/// other way to attach a tap target to a text run; ``PostCardView`` intercepts
/// them with an `OpenURLAction` so nothing ever reaches the system opener.
enum PostEntityLink: Equatable {
    case mention(String)
    case hashtag(String)

    static let scheme = "trustnet"

    /// The URL for this entity, or `nil` if the payload cannot be encoded.
    var url: URL? {
        let (host, value): (String, String) = {
            switch self {
            case let .mention(handle): return ("mention", handle)
            case let .hashtag(tag): return ("hashtag", tag)
            }
        }()
        guard let encoded = value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else {
            return nil
        }
        return URL(string: "\(Self.scheme)://\(host)/\(encoded)")
    }

    /// Parses a URL produced by ``url``.
    static func parse(_ url: URL) -> PostEntityLink? {
        guard url.scheme == scheme else { return nil }
        let value = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let decoded = value.removingPercentEncoding, !decoded.isEmpty else { return nil }
        switch url.host() {
        case "mention": return .mention(decoded)
        case "hashtag": return .hashtag(decoded)
        default: return nil
        }
    }
}

#Preview("PostCardView") {
    ScrollView {
        VStack(spacing: 0) {
            PostCardView(post: FeedServiceMock.quotePost)
            TNDivider()
            PostCardView(post: FeedServiceMock.countryThread)
            TNDivider()
            PostCardView(post: FeedServiceMock.unverifiedAuthorPost)
            TNDivider()
            PostCardView(post: FeedServiceMock.regionThread, style: .detail)
        }
    }
    .background(TNColor.background)
    .preferredColorScheme(.dark)
}
