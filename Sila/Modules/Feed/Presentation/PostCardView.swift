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
    /// The author's avatar or name was tapped: open their profile.
    ///
    /// Carries the whole ``UserSummary`` rather than a handle so the caller can
    /// decide without a lookup — the profile screen still re-reads the account
    /// from the server, because the copy pinned to a post is only as fresh as
    /// the page it arrived on.
    public var onOpenAuthor: @MainActor (UserSummary) -> Void
    /// A long-press menu item with no backend yet (Not interested).
    public var onStub: @MainActor (String) -> Void

    /// Builds the block / mute / report menu for a post, or returns `nil` when
    /// there should not be one — on the viewer's own post, or on a surface with
    /// no safety backend wired.
    ///
    /// A factory rather than three closures because the menu's *labels* depend
    /// on what the viewer has already done to this author, and that is knowledge
    /// only the safety model has. `nil` restores the pre-safety card exactly:
    /// no `…` button, and Report falls back to ``onStub``.
    public var safetyMenu: (@MainActor (Post) -> SafetyMenuActions?)?
    /// What the *author* can do to their own post. `nil` on everybody
    /// else's — and mutually exclusive with ``safetyMenu``, which is `nil`
    /// on your own, since you cannot block or report yourself.
    public var ownPost: (@MainActor (Post) -> OwnPostActions?)?

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
        onOpenAuthor: @escaping @MainActor (UserSummary) -> Void = { _ in },
        onStub: @escaping @MainActor (String) -> Void = { _ in },
        safetyMenu: (@MainActor (Post) -> SafetyMenuActions?)? = nil,
        ownPost: (@MainActor (Post) -> OwnPostActions?)? = nil
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
        self.onOpenAuthor = onOpenAuthor
        self.onStub = onStub
        self.safetyMenu = safetyMenu
        self.ownPost = ownPost
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
    /// The cover, per card, starting closed. Never remembered across posts:
    /// opening one spoiler is not consent to every spoiler after it.
    @State private var isRevealed = false

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
        VStack(alignment: .leading, spacing: SLSpacing.sm) {
            authorBlock

            if let kind = post.sensitive {
                SensitiveCoverView(
                    kind: kind,
                    note: post.sensitiveNote,
                    isRevealed: $isRevealed
                )
                .padding(.leading, style == .detail ? 0 : 56)
            }

            if post.sensitive == nil || isRevealed {
                postText
                    .padding(.leading, style == .detail ? 0 : 56)

                if !post.imageURLs.isEmpty {
                    images
                        .padding(.leading, style == .detail ? 0 : 56)
                }

                if let quoted = post.quotedPost {
                    QuotedPostCard(post: quoted, onTap: { actions.onOpenQuoted(quoted) })
                        .padding(.leading, style == .detail ? 0 : 56)
                }
            }

            if style == .detail {
                detailFooter
            }

            engagementRow
                .padding(.leading, style == .detail ? 0 : 52)
        }
        .padding(.horizontal, SLSpacing.lg)
        .padding(.vertical, SLSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { actions.onOpen(post) }
        .contextMenu { longPressMenu }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(accessibilitySummary))
    }

    // MARK: - Header

    /// The avatar, name, handle and timestamp — a control in its own right.
    ///
    /// A `Button` nested inside the card, so the author region opens the
    /// profile while the rest of the card still opens the post. The scope chip
    /// is deliberately left outside it: it describes the *thread's* audience,
    /// not the person, and tapping it should not navigate to them.
    private var authorBlock: some View {
        HStack(alignment: .top, spacing: SLSpacing.md) {
            Button {
                actions.onOpenAuthor(post.author)
            } label: {
                HStack(alignment: .top, spacing: SLSpacing.md) {
                    SLAvatar(
                        url: post.author.avatarURL,
                        initials: post.author.initials,
                        size: style == .detail ? .lg : .md,
                        isVerified: post.author.isVerified,
                        displayName: post.author.displayName
                    )

                    VStack(alignment: .leading, spacing: SLSpacing.xs) {
                        header
                        scopeChip
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(authorAccessibilityLabel))
            .accessibilityHint(Text(L10n.t("post.author.openProfile.hint", post.author.displayName)))

            Spacer(minLength: 0)

            // Top-right, away from the engagement row. Report and block must be
            // one tap from any post — Guideline 1.2 is not optional for a
            // user-generated-content app — but they must not sit next to Reply
            // as though they were peers of it.
            if let safety = actions.safetyMenu?(post) {
                SafetyMenuButton(actions: safety)
                    .offset(y: -4)
            }
        }
    }

    /// What VoiceOver reads for the author control, without the post's text.
    private var authorAccessibilityLabel: String {
        var parts = [post.author.displayName]
        if post.author.isVerified { parts.append(L10n.t("post.author.verified.accessibility")) }
        if let label = CountryCode.accessibilityLabel(post.author.countryCode) { parts.append(label) }
        parts.append(post.author.atHandle)
        parts.append(RelativeTime.accessible(post.createdAt))
        return parts.joined(separator: ". ")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: SLSpacing.xs) {
                Text(post.author.displayName)
                    .font(SLFont.bodyEmphasis)
                    .foregroundStyle(SLColor.textPrimary)
                    .lineLimit(1)

                if post.author.isVerified {
                    SLVerifiedBadge(size: 15, isPulsing: false)
                }

                // The country-verified flag. Absent when the identity does not
                // carry one — never guessed.
                SLCountryBadge(countryCode: post.author.countryCode)
            }

            HStack(spacing: SLSpacing.xs) {
                Text(post.author.atHandle)
                    .font(SLFont.caption)
                    .foregroundStyle(SLColor.textSecondary)
                    .lineLimit(1)

                Text("·")
                    .font(SLFont.caption)
                    .foregroundStyle(SLColor.textMuted)

                Text(RelativeTime.short(post.createdAt))
                    .font(SLFont.caption)
                    .foregroundStyle(SLColor.textSecondary)
                    .accessibilityLabel(
                        Text(L10n.t("post.time.posted.accessibility", RelativeTime.accessible(post.createdAt)))
                    )
            }
        }
    }

    private var scopeChip: some View {
        let scope = ScopePresentation.make(for: post)
        return HStack(spacing: SLSpacing.xs) {
            Image(systemName: scope.icon)
                .font(.system(size: 10, weight: .semibold))
            Text(scope.label)
                .font(SLFont.micro)
                .lineLimit(1)
        }
        .foregroundStyle(scopeTint)
        .padding(.horizontal, SLSpacing.sm)
        .padding(.vertical, 2)
        .background(Capsule().fill(scopeTint.opacity(0.12)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(scope.accessibilityLabel))
    }

    private var scopeTint: Color {
        switch post.scope {
        case .international: return SLColor.primary
        case .country: return SLColor.secondary
        case .region: return SLColor.warning
        }
    }

    // MARK: - Body text

    /// The post's own words, laid out in the post's own direction.
    ///
    /// **Not** the interface's direction. An Arabic post read on an English
    /// phone still has to start at the right margin, wrap from the right, and
    /// keep its full stop on the correct end — and the English post quoted
    /// underneath it still has to do the opposite. Forcing `.leading` here was
    /// the one line that made every Arabic post in the feed read wrong.
    /// Attached images.
    ///
    /// One fills the width; two or more go in a grid. Every one keeps a fixed
    /// aspect box so a feed does not reflow as pictures arrive — a timeline that
    /// jumps while somebody is reading it costs them their place.
    ///
    /// No image is ever the whole post: the text is always above it, and a
    /// picture that fails to load leaves the words behind rather than a broken
    /// card.
    @ViewBuilder
    private var images: some View {
        let urls = Array(post.imageURLs.prefix(4))
        let columns = urls.count == 1 ? 1 : 2

        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: SLSpacing.xs), count: columns),
            spacing: SLSpacing.xs
        ) {
            ForEach(urls, id: \.self) { url in
                AsyncImage(url: url) { phase in
                    switch phase {
                    case let .success(image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .failure:
                        // Says what happened rather than showing a grey void.
                        ZStack {
                            SLColor.surface2
                            Image(systemName: "photo")
                                .foregroundStyle(SLColor.textMuted)
                        }
                        .accessibilityLabel(Text(L10n.t("post.image.failed")))
                    default:
                        SLColor.surface2
                    }
                }
                .frame(height: urls.count == 1 ? 220 : 140)
                .frame(maxWidth: .infinity)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: SLRadius.md, style: .continuous))
                .accessibilityAddTraits(.isImage)
            }
        }
        .accessibilityLabel(Text(L10n.plural("post.image.count", urls.count)))
    }

    private var postText: some View {
        Text(attributedText)
            .font(style == .detail ? SLFont.displayM : SLFont.body)
            .foregroundStyle(SLColor.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .slContentDirection(of: post)
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
        run.foregroundColor = SLColor.primary
        // A tag that cannot be percent-encoded into a URL still renders — it
        // just is not tappable. Better than dropping the characters.
        if let link { run.link = link }
        return run
    }

    // MARK: - Detail extras

    @ViewBuilder
    private var detailFooter: some View {
        VStack(alignment: .leading, spacing: SLSpacing.sm) {
            Text(SLFormat.dateTime(post.createdAt))
                .font(SLFont.caption)
                .foregroundStyle(SLColor.textMuted)

            if post.metrics.views > 0 {
                Text(
                    L10n.plural(
                        "post.views.count",
                        post.metrics.views,
                        SLFormat.compactCount(post.metrics.views)
                    )
                )
                .font(SLFont.caption)
                .foregroundStyle(SLColor.textMuted)
            }

            if let message = ReplyPermission.make(for: post).blockedMessage {
                HStack(alignment: .top, spacing: SLSpacing.sm) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(SLColor.warning)
                    Text(message)
                        .font(SLFont.caption)
                        .foregroundStyle(SLColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(SLSpacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: SLRadius.md)
                        .fill(SLColor.warning.opacity(0.08))
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
                tint: SLColor.secondary,
                label: L10n.t(post.viewer.reposted ? "post.repost.undo.label" : "post.repost.label"),
                hint: L10n.t(post.viewer.reposted ? "post.repost.undo.hint" : "post.repost.hint"),
                action: { actions.onRepost(post) }
            )

            likeButton

            engagementButton(
                icon: post.viewer.bookmarked ? "bookmark.fill" : "bookmark",
                count: post.metrics.bookmarks,
                isOn: post.viewer.bookmarked,
                tint: SLColor.primary,
                label: L10n.t(post.viewer.bookmarked ? "post.bookmark.remove.label" : "post.bookmark.label"),
                hint: L10n.t(post.viewer.bookmarked ? "post.bookmark.remove.hint" : "post.bookmark.hint"),
                action: { actions.onBookmark(post) }
            )

            ShareLink(item: shareText) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 14))
                    .foregroundStyle(SLColor.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(Text(L10n.t("common.share")))
            .accessibilityHint(Text(L10n.t("post.share.hint")))
        }
        .padding(.top, SLSpacing.xs)
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
            HStack(spacing: SLSpacing.xs) {
                Image(systemName: permission.canReply ? "bubble.left" : "bubble.left.slash")
                    .font(.system(size: 14))
                if post.metrics.replies > 0 {
                    Text(SLFormat.compactCount(post.metrics.replies)).font(SLFont.micro)
                }
            }
            .foregroundStyle(permission.canReply ? SLColor.textSecondary : SLColor.textMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(L10n.t(permission.canReply ? "post.reply.label" : "post.reply.restricted.label")))
        .accessibilityHint(Text(permission.blockedMessage ?? L10n.t("post.reply.hint")))
    }

    private var likeButton: some View {
        Button {
            if !reduceMotion {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.42)) { likeScale = 1.35 }
                withAnimation(.spring(response: 0.32, dampingFraction: 0.7).delay(0.1)) { likeScale = 1 }
            }
            actions.onLike(post)
        } label: {
            HStack(spacing: SLSpacing.xs) {
                Image(systemName: post.viewer.liked ? "heart.fill" : "heart")
                    .font(.system(size: 14))
                    .scaleEffect(post.viewer.liked ? likeScale : 1)
                if post.metrics.likes > 0 {
                    Text(SLFormat.compactCount(post.metrics.likes)).font(SLFont.micro)
                }
            }
            .foregroundStyle(post.viewer.liked ? SLColor.danger : SLColor.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(L10n.t(post.viewer.liked ? "post.like.undo.label" : "post.like.label")))
        .accessibilityValue(Text(L10n.plural("post.likes.count.accessibility", post.metrics.likes)))
        .accessibilityHint(Text(L10n.t(post.viewer.liked ? "post.like.undo.hint" : "post.like.hint")))
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
            HStack(spacing: SLSpacing.xs) {
                Image(systemName: icon).font(.system(size: 14))
                if count > 0 {
                    Text(Self.count(count)).font(SLFont.micro)
                }
            }
            .foregroundStyle(isOn ? tint : SLColor.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(SLFormat.number(count)))
        .accessibilityHint(Text(hint))
    }

    // MARK: - Long-press menu

    @ViewBuilder
    private var longPressMenu: some View {
        Button {
            actions.onQuote(post)
        } label: {
            Label(L10n.t("post.menu.quote"), systemImage: "quote.bubble")
        }

        Button {
            actions.onBookmark(post)
        } label: {
            Label(L10n.t(post.viewer.bookmarked ? "post.menu.removeBookmark" : "post.menu.bookmark"), systemImage: "bookmark")
        }

        Button {
            UIPasteboard.general.string = post.text
        } label: {
            Label(L10n.t("post.menu.copyText"), systemImage: "doc.on.doc")
        }

        ShareLink(item: shareText) {
            Label(L10n.t("common.share"), systemImage: "square.and.arrow.up")
        }

        Button {
            actions.onStub(MainTabView.StubFeature.notInterested)
        } label: {
            Label(L10n.t("post.menu.notInterested"), systemImage: "hand.thumbsdown")
        }

        // Your own post offers Delete; everybody else's offers the safety
        // verbs. Never both: you cannot block yourself, and you cannot delete
        // somebody else's words.
        if let own = actions.ownPost?(post) {
            Button(role: .destructive, action: own.onDelete) {
                Label(L10n.t("post.menu.delete"), systemImage: "trash")
            }
        } else if let safety = actions.safetyMenu?(post) {
            SafetyMenu(actions: safety)
        } else {
            // The pre-safety fallback, kept so a surface with no safety backend
            // still says what it cannot do rather than hiding Report entirely.
            Button(role: .destructive) {
                actions.onStub(MainTabView.StubFeature.report)
            } label: {
                Label(L10n.t("post.menu.report"), systemImage: "flag")
            }
        }
    }

    // MARK: - Text helpers

    /// What the share sheet carries. No permalink is fabricated — the backend
    /// does not expose a public post URL yet.
    private var shareText: String {
        L10n.t("post.share.body", post.author.displayName, post.author.atHandle, post.text)
    }

    private var accessibilitySummary: String {
        var parts = [post.author.displayName]
        if post.author.isVerified { parts.append(L10n.t("post.author.verified.accessibility")) }
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
        SLCard(
            padding: SLSpacing.md,
            accessibilityLabel: L10n.t("post.quoted.accessibility", post.author.displayName),
            accessibilityHint: L10n.t("post.quoted.hint"),
            onTap: onTap
        ) {
            VStack(alignment: .leading, spacing: SLSpacing.xs) {
                HStack(spacing: SLSpacing.xs) {
                    SLAvatar(
                        url: post.author.avatarURL,
                        initials: post.author.initials,
                        size: .sm,
                        isVerified: false,
                        displayName: post.author.displayName
                    )
                    Text(post.author.displayName)
                        .font(SLFont.caption)
                        .foregroundStyle(SLColor.textPrimary)
                        .lineLimit(1)
                    if post.author.isVerified {
                        SLVerifiedBadge(size: 12, isPulsing: false)
                    }
                    SLCountryBadge(countryCode: post.author.countryCode)
                    Text(post.author.atHandle)
                        .font(SLFont.micro)
                        .foregroundStyle(SLColor.textMuted)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(RelativeTime.short(post.createdAt))
                        .font(SLFont.micro)
                        .foregroundStyle(SLColor.textMuted)
                }

                if let kind = post.sensitive {
                    // The quoted post's own warning holds inside the quote: a
                    // quote is not a way to read around a cover. Its text is
                    // one tap away, on its own page, behind its own cover.
                    HStack(alignment: .firstTextBaseline, spacing: SLSpacing.xs) {
                        Image(systemName: "eye.slash")
                            .font(.system(size: 12, weight: .semibold))
                        Text(SensitiveCopy.quotedLabel(kind, note: post.sensitiveNote))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(SLFont.caption)
                    .foregroundStyle(SLColor.textSecondary)
                    .accessibilityIdentifier("post.quoted.sensitive")
                } else {
                    Text(post.text)
                        .font(SLFont.bodyLight)
                        .foregroundStyle(SLColor.textSecondary)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                        // The quoted post is somebody else's writing and has its
                        // own language, which is routinely not the language of the
                        // post quoting it.
                        .slContentDirection(of: post)
                }
            }
        }
    }
}

// MARK: - Entity links

/// The in-text entities the card turns into tappable links.
///
/// Rendered as a private `sila://` URL because `AttributedString` has no
/// other way to attach a tap target to a text run; ``PostCardView`` intercepts
/// them with an `OpenURLAction` so nothing ever reaches the system opener.
enum PostEntityLink: Equatable {
    case mention(String)
    case hashtag(String)

    static let scheme = "sila"

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
            SLDivider()
            PostCardView(post: FeedServiceMock.countryThread)
            SLDivider()
            PostCardView(post: FeedServiceMock.unverifiedAuthorPost)
            SLDivider()
            PostCardView(post: FeedServiceMock.regionThread, style: .detail)
        }
    }
    .background(SLColor.background)
    .preferredColorScheme(.dark)
}
