import Foundation

/// Why the composer was opened.
///
/// Carrying the whole ``Post`` rather than its id is deliberate: a quote needs
/// the post's author and text to render the embedded card, and a reply needs
/// the parent's `scope` and `viewer.can_reply`. Both are already in hand at
/// every call site, and re-fetching them would put a spinner in front of a
/// composer that has nothing to wait for.
///
/// > Note: The Phase-4 spec's export was
/// > `openComposer(replyTo: UUID?, quotedPost: UUID?)`. That signature cannot
/// > render the quoted card without a round trip, so the payload is the post.
public enum ComposerContext: Identifiable, Hashable, Sendable {

    /// A root post. The scope picker is shown.
    case newPost
    /// A reply to `post`. The scope is inherited, so there is no picker.
    case reply(to: Post)
    /// A new post quoting `post`. The quote is rendered beneath the editor and
    /// the scope picker is shown, because a quote is a post of its own.
    case quote(Post)

    public var id: String {
        switch self {
        case .newPost: return "new"
        case let .reply(post): return "reply-\(post.id.uuidString)"
        case let .quote(post): return "quote-\(post.id.uuidString)"
        }
    }

    /// The post being replied to, when there is one.
    public var replyTarget: Post? {
        if case let .reply(post) = self { return post }
        return nil
    }

    /// The post being quoted, when there is one.
    public var quotedPost: Post? {
        if case let .quote(post) = self { return post }
        return nil
    }

    /// Whether the composer offers a scope picker. Replies inherit their
    /// parent's audience, so offering a choice there would be a lie.
    public var showsScopePicker: Bool { replyTarget == nil }

    /// Screen title.
    public var title: String {
        switch self {
        case .newPost: return "New Post"
        case .reply: return "Reply"
        case .quote: return "Quote"
        }
    }

    /// Label on the confirm button.
    public var actionTitle: String {
        switch self {
        case .newPost: return "Post"
        case .reply: return "Reply"
        case .quote: return "Post"
        }
    }
}

/// How other modules open the composer without importing it.
///
/// ``AppRouter`` conforms, so Feed, Explore and any later phase can start a
/// composition through the coordinator they already hold.
@MainActor
public protocol ComposerLaunching: AnyObject {
    /// Presents the composer for a context.
    func openComposer(_ context: ComposerContext)
}
