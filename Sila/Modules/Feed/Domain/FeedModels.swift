import Foundation

// MARK: - User

/// The slice of an account that appears next to a post.
///
/// ``countryCode`` is the country-**verified** flag: it is written only by the
/// verification pipeline (Nafath nationality, or the issuing country of a
/// verified ID) and is `nil` until an account is verified. It is never derived
/// from an IP address, a phone prefix or a locale, which is why the UI shows
/// nothing at all rather than a guess when it is absent.
public struct UserSummary: Identifiable, Hashable, Sendable, Decodable {

    public let id: UUID
    /// Unique, lowercase, 3–20 chars of `[a-z0-9_]`. No leading `@`.
    public let handle: String
    /// Human-chosen name. Falls back to the handle when the server sends "".
    public let displayName: String
    /// Remote avatar image, or `nil` for the monogram fallback.
    public let avatarURL: URL?
    /// Whether identity verification has completed.
    public let isVerified: Bool
    /// ISO-3166 alpha-2 from the verified identity — `nil` when unverified.
    public let countryCode: String?
    /// When the checkmark was earned.
    public let verifiedSince: Date?

    public init(
        id: UUID,
        handle: String,
        displayName: String,
        avatarURL: URL? = nil,
        isVerified: Bool,
        countryCode: String? = nil,
        verifiedSince: Date? = nil
    ) {
        self.id = id
        self.handle = handle
        self.displayName = displayName.isEmpty ? handle : displayName
        self.avatarURL = avatarURL
        self.isVerified = isVerified
        self.countryCode = CountryCode.normalised(countryCode)
        self.verifiedSince = verifiedSince
    }

    /// Explicit keys are required because ``init(from:)`` is custom, and the
    /// raw values are the *camel-cased* forms `.convertFromSnakeCase` produces.
    private enum CodingKeys: String, CodingKey {
        case id, handle, displayName, isVerified, countryCode, verifiedSince
        case avatarURL = "avatarUrl"
    }

    /// Tolerant decoder: one malformed optional must not blank a whole feed.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let uuid = try? container.decode(UUID.self, forKey: .id) {
            id = uuid
        } else {
            let raw = (try? container.decode(String.self, forKey: .id)) ?? ""
            id = UUID(uuidString: raw) ?? UUID()
        }
        let decodedHandle = (try? container.decode(String.self, forKey: .handle)) ?? ""
        handle = decodedHandle
        let name = (try? container.decodeIfPresent(String.self, forKey: .displayName)) ?? nil
        displayName = (name?.isEmpty == false ? name : nil) ?? decodedHandle
        // Resolved against the API origin rather than decoded straight into a
        // `URL`. The server sends a root-relative path
        // (`/api/v1/media/avatars/…`), which `URL(string:)` accepts and turns
        // into a relative URL with no host — something `AsyncImage` can never
        // load, and which fails silently as a missing image rather than as an
        // error anybody would see.
        avatarURL = AppConfig.mediaURL(
            (try? container.decodeIfPresent(String.self, forKey: .avatarURL)) ?? nil
        )
        isVerified = (try? container.decode(Bool.self, forKey: .isVerified)) ?? false
        countryCode = CountryCode.normalised(
            (try? container.decodeIfPresent(String.self, forKey: .countryCode)) ?? nil
        )
        verifiedSince = (try? container.decodeIfPresent(Date.self, forKey: .verifiedSince)) ?? nil
    }

    /// Two-letter monogram for ``SLAvatar``.
    public var initials: String {
        let parts = displayName.split(separator: " ")
        let letters = parts.prefix(2).compactMap(\.first)
        if !letters.isEmpty { return String(letters) }
        return String(handle.prefix(2))
    }

    /// The handle as it is rendered, with the `@`.
    public var atHandle: String { "@\(handle)" }
}

// MARK: - Scope

/// Who may **reply** to a thread. Everyone may always read it.
///
/// Unknown future values decode as ``international`` — the baseline with no
/// extra restriction — rather than failing the whole response.
public enum PostScope: String, Codable, Sendable, CaseIterable, Hashable {
    /// Any verified user may reply.
    case international
    /// Only verified users whose country matches `scope_country`.
    case country
    /// Only verified users whose country sits inside `scope_region`.
    case region

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PostScope(rawValue: raw) ?? .international
    }
}

/// Why the viewer cannot reply, as reported by `viewer.reply_block_reason`.
public enum ReplyBlockReason: String, Codable, Sendable, Hashable {
    /// The viewer's verified country differs from the thread's.
    case countryMismatch = "country_mismatch"
    /// The viewer's country is outside the thread's region.
    case regionMismatch = "region_mismatch"
    /// The viewer has not completed identity verification.
    case unverified
    /// A code this build does not recognise.
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ReplyBlockReason(rawValue: raw) ?? .unknown
    }
}

// MARK: - Metrics & viewer state

/// Engagement counters on a post.
public struct PostMetrics: Equatable, Sendable, Decodable, Hashable {

    public let likes: Int
    public let reposts: Int
    public let replies: Int
    public let views: Int
    public let bookmarks: Int

    public init(likes: Int = 0, reposts: Int = 0, replies: Int = 0, views: Int = 0, bookmarks: Int = 0) {
        self.likes = likes
        self.reposts = reposts
        self.replies = replies
        self.views = views
        self.bookmarks = bookmarks
    }

    private enum CodingKeys: String, CodingKey {
        case likes, reposts, replies, views, bookmarks
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        likes = (try? container.decode(Int.self, forKey: .likes)) ?? 0
        reposts = (try? container.decode(Int.self, forKey: .reposts)) ?? 0
        replies = (try? container.decode(Int.self, forKey: .replies)) ?? 0
        views = (try? container.decode(Int.self, forKey: .views)) ?? 0
        bookmarks = (try? container.decode(Int.self, forKey: .bookmarks)) ?? 0
    }

    /// A copy with counters nudged, never below zero.
    ///
    /// Used for optimistic updates, where the client predicts the counter the
    /// server is about to return.
    public func adjusting(likes: Int = 0, reposts: Int = 0, bookmarks: Int = 0) -> PostMetrics {
        PostMetrics(
            likes: max(0, self.likes + likes),
            reposts: max(0, self.reposts + reposts),
            replies: replies,
            views: views,
            bookmarks: max(0, self.bookmarks + bookmarks)
        )
    }
}

/// What *this* viewer has done with a post, and what they are allowed to do.
public struct PostViewerState: Equatable, Sendable, Decodable, Hashable {

    public let liked: Bool
    public let reposted: Bool
    public let bookmarked: Bool
    /// Computed server-side per request from the thread's scope.
    public let canReply: Bool
    /// Populated only when ``canReply`` is `false`.
    public let replyBlockReason: ReplyBlockReason?

    public init(
        liked: Bool = false,
        reposted: Bool = false,
        bookmarked: Bool = false,
        canReply: Bool = true,
        replyBlockReason: ReplyBlockReason? = nil
    ) {
        self.liked = liked
        self.reposted = reposted
        self.bookmarked = bookmarked
        self.canReply = canReply
        self.replyBlockReason = replyBlockReason
    }

    private enum CodingKeys: String, CodingKey {
        case liked, reposted, bookmarked, canReply, replyBlockReason
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        liked = (try? container.decode(Bool.self, forKey: .liked)) ?? false
        reposted = (try? container.decode(Bool.self, forKey: .reposted)) ?? false
        bookmarked = (try? container.decode(Bool.self, forKey: .bookmarked)) ?? false
        let reason = (try? container.decodeIfPresent(ReplyBlockReason.self, forKey: .replyBlockReason)) ?? nil
        replyBlockReason = reason
        // A missing `can_reply` is read as "no stated reason not to" — the
        // server always sends the pair together, and defaulting to `false`
        // would silently kill replies on an older build.
        canReply = (try? container.decode(Bool.self, forKey: .canReply)) ?? (reason == nil)
    }

    /// A copy with one flag flipped.
    public func setting(liked: Bool? = nil, reposted: Bool? = nil, bookmarked: Bool? = nil) -> PostViewerState {
        PostViewerState(
            liked: liked ?? self.liked,
            reposted: reposted ?? self.reposted,
            bookmarked: bookmarked ?? self.bookmarked,
            canReply: canReply,
            replyBlockReason: replyBlockReason
        )
    }
}

// MARK: - Post

/// Lets a ``Post`` hold the post it quotes.
///
/// Swift forbids a struct from storing itself even behind `Optional`, because
/// the layout would be infinite. `indirect` puts the payload behind a pointer.
public indirect enum PostReference: Equatable, Sendable, Hashable {
    case value(Post)

    /// The boxed post.
    public var post: Post {
        switch self {
        case let .value(post): return post
        }
    }
}

/// A post, reply or quote-post.
/// What an author may warn about.
///
/// A closed list, because each is rendered as its own sentence — "Spoiler
/// alert" is a different promise from "Violent content", and a reader deciding
/// whether to open a cover deserves to know which. A category this build does
/// not recognise still covers the post, generically: the author asked for a
/// cover, and a server whose vocabulary grew must not quietly uncover it.
public enum SensitiveKind: String, Sendable, Hashable, Decodable, CaseIterable {
    case spoiler
    case violence
    case other

    /// Unrecognised values become ``other`` rather than throwing — or, worse,
    /// rather than decoding as "no warning".
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SensitiveKind(rawValue: raw) ?? .other
    }

    /// The wire value. Only the three the server accepts; ``other`` covers the
    /// rest, so nothing this client sends is ever outside the list.
    public var wireValue: String { rawValue }
}

public struct Post: Identifiable, Equatable, Sendable, Decodable {

    public let id: UUID
    public let author: UserSummary
    public let text: String
    /// The author's warning, or `nil`. The text is still here — the cover is
    /// the reader's choice, and opening it must not cost a request.
    public let sensitive: SensitiveKind?
    /// The author's own words about what is covered.
    public let sensitiveNote: String?
    /// Images attached to the post, in the order they were added — at most
    /// four. Server-minted paths only; the API refuses anything else, so a post
    /// can never point a reader's device at an arbitrary host.
    public let imageURLs: [URL]
    /// BCP-47 code for the language ``text`` is written in, as detected
    /// server-side at write time — `"ar"`, `"en"`, or `nil` when the server
    /// could not tell (a post that is only numbers and emoji has no language).
    ///
    /// This is what decides which way the post is laid out. The alternative —
    /// laying every post out in the *interface's* direction — mangles exactly
    /// the content this network is made of: an Arabic post read by somebody
    /// whose phone is in English, and the English quote inside it.
    public let language: String?
    public let createdAt: Date
    /// Who may reply to this thread.
    public let scope: PostScope
    /// Set when ``scope`` is ``PostScope/country``.
    public let scopeCountry: String?
    /// Set when ``scope`` is ``PostScope/region`` — e.g. `"GCC"`, `"MENA"`, `"EU"`.
    public let scopeRegion: String?
    /// The post this is a reply to, when it is one.
    public let replyToPostId: UUID?
    /// Direct replies only — not the whole subtree.
    public let replyCountDirect: Int
    /// Engagement counters. `var` so optimistic updates can rewrite them.
    public var metrics: PostMetrics
    /// This viewer's relationship to the post. `var` for the same reason.
    public var viewer: PostViewerState

    private let quoted: PostReference?

    /// The quoted post, if any. Guaranteed one level deep — see ``init(from:)``.
    public var quotedPost: Post? { quoted?.post }

    /// `true` when this post is itself a reply.
    public var isReply: Bool { replyToPostId != nil }

    public init(
        id: UUID,
        author: UserSummary,
        text: String,
        createdAt: Date,
        // Defaulted, so every existing caller and fixture is untouched.
        imageURLs: [URL] = [],
        language: String? = nil,
        scope: PostScope = .international,
        scopeCountry: String? = nil,
        scopeRegion: String? = nil,
        replyToPostId: UUID? = nil,
        replyCountDirect: Int = 0,
        metrics: PostMetrics = PostMetrics(),
        viewer: PostViewerState = PostViewerState(),
        quotedPost: Post? = nil,
        sensitive: SensitiveKind? = nil,
        sensitiveNote: String? = nil
    ) {
        self.id = id
        self.author = author
        self.text = text
        self.sensitive = sensitive
        self.sensitiveNote = sensitive == nil ? nil : ((sensitiveNote?.isEmpty == false) ? sensitiveNote : nil)
        self.imageURLs = imageURLs
        self.language = Post.normalisedLanguage(language)
        self.createdAt = createdAt
        self.scope = scope
        self.scopeCountry = CountryCode.normalised(scopeCountry) ?? scopeCountry
        self.scopeRegion = scopeRegion
        self.replyToPostId = replyToPostId
        self.replyCountDirect = replyCountDirect
        self.metrics = metrics
        self.viewer = viewer
        self.quoted = quotedPost.map { .value($0.strippingQuote()) }
    }

    private enum CodingKeys: String, CodingKey {
        case id, author, text, imageUrls, language, createdAt, scope, scopeCountry, scopeRegion
        case replyToPostId, replyCountDirect, metrics, viewer, quotedPost
        case sensitive, sensitiveNote
    }

    /// Lower-cased, region stripped: the server may send `"ar-SA"`, and
    /// direction is a property of the script, not of the country.
    /// An empty string decodes as `nil` — "the server does not know" and "the
    /// server sent a blank" are the same fact, and both mean *look at the text*.
    static func normalisedLanguage(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let base = String(raw.split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? "")
            .lowercased()
        return base.isEmpty ? nil : base
    }

    /// Tolerant decoder.
    ///
    /// The quoted post is flattened to one level on the way in: the contract
    /// says the server never nests further, and enforcing it here means a
    /// malformed response cannot produce an unbounded render tree.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if let uuid = try? container.decode(UUID.self, forKey: .id) {
            id = uuid
        } else {
            let raw = (try? container.decode(String.self, forKey: .id)) ?? ""
            id = UUID(uuidString: raw) ?? UUID()
        }
        author = try container.decode(UserSummary.self, forKey: .author)
        text = (try? container.decode(String.self, forKey: .text)) ?? ""
        // `null` is no warning; any string is one. A malformed value (a number,
        // say) is read as no warning, which is the one case where being wrong
        // uncovers a post — and it is a case the server cannot produce.
        sensitive = (try? container.decodeIfPresent(SensitiveKind.self, forKey: .sensitive)) ?? nil
        let note = (try? container.decodeIfPresent(String.self, forKey: .sensitiveNote)) ?? nil
        sensitiveNote = sensitive == nil ? nil : ((note?.isEmpty == false) ? note : nil)
        // Relative paths, resolved against the API host. A row whose image list
        // fails to decode still renders its text: losing a picture is a much
        // smaller failure than losing the post.
        imageURLs = ((try? container.decodeIfPresent([String].self, forKey: .imageUrls)) ?? [])?
            .compactMap { AppConfig.mediaURL($0) } ?? []
        language = Post.normalisedLanguage(
            (try? container.decodeIfPresent(String.self, forKey: .language)) ?? nil
        )
        createdAt = (try? container.decode(Date.self, forKey: .createdAt)) ?? Date()
        scope = (try? container.decode(PostScope.self, forKey: .scope)) ?? .international
        let rawScopeCountry = (try? container.decodeIfPresent(String.self, forKey: .scopeCountry)) ?? nil
        scopeCountry = CountryCode.normalised(rawScopeCountry) ?? rawScopeCountry
        scopeRegion = (try? container.decodeIfPresent(String.self, forKey: .scopeRegion)) ?? nil
        if let raw = (try? container.decodeIfPresent(String.self, forKey: .replyToPostId)) ?? nil {
            replyToPostId = UUID(uuidString: raw)
        } else {
            replyToPostId = (try? container.decodeIfPresent(UUID.self, forKey: .replyToPostId)) ?? nil
        }
        replyCountDirect = (try? container.decode(Int.self, forKey: .replyCountDirect)) ?? 0
        metrics = (try? container.decode(PostMetrics.self, forKey: .metrics)) ?? PostMetrics()
        viewer = (try? container.decode(PostViewerState.self, forKey: .viewer)) ?? PostViewerState()

        let decodedQuote = (try? container.decodeIfPresent(Post.self, forKey: .quotedPost)) ?? nil
        quoted = decodedQuote.map { .value($0.strippingQuote()) }
    }

    /// A copy with no quoted post — the flattening step for the one-level rule.
    func strippingQuote() -> Post {
        Post(
            id: id,
            author: author,
            text: text,
            createdAt: createdAt,
            language: language,
            scope: scope,
            scopeCountry: scopeCountry,
            scopeRegion: scopeRegion,
            replyToPostId: replyToPostId,
            replyCountDirect: replyCountDirect,
            metrics: metrics,
            viewer: viewer,
            quotedPost: nil,
            sensitive: sensitive,
            sensitiveNote: sensitiveNote
        )
    }
}

extension Post: Hashable {
    /// Identity is the id — two renders of the same post are the same node in a
    /// navigation path even after an optimistic counter bump.
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: - Page

/// One page of a cursor-paginated feed.
///
/// Cursors are opaque (`base64(created_at|id)` server-side) and must never be
/// constructed on the client — the only legal value is one the server returned.
public struct FeedPage: Equatable, Sendable, Decodable {

    public let posts: [Post]
    /// Pass back as `?cursor=` to fetch the next page. `nil` at the end.
    public let nextCursor: String?
    /// Whether another page exists.
    public let hasMore: Bool

    public init(posts: [Post], nextCursor: String? = nil, hasMore: Bool = false) {
        self.posts = posts
        self.nextCursor = nextCursor
        self.hasMore = hasMore
    }

    private enum CodingKeys: String, CodingKey {
        case posts, nextCursor, hasMore
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        posts = (try? container.decode([Post].self, forKey: .posts)) ?? []
        let cursor = (try? container.decodeIfPresent(String.self, forKey: .nextCursor)) ?? nil
        nextCursor = (cursor?.isEmpty == false) ? cursor : nil
        // A server that says `has_more` but sends no cursor would strand the
        // pager, so the cursor is the tie-breaker.
        let flag = (try? container.decode(Bool.self, forKey: .hasMore)) ?? (nextCursor != nil)
        hasMore = flag && nextCursor != nil
    }

    /// The end-of-feed page.
    public static let empty = FeedPage(posts: [], nextCursor: nil, hasMore: false)
}

// MARK: - Feed tabs

/// The four feeds on the home screen.
///
/// "My Country" is the v4 product's signature surface: content by verified
/// compatriots, with membership decided by verified identity rather than by
/// where a request appears to come from.
public enum FeedTab: String, CaseIterable, Identifiable, Sendable, Hashable {
    /// Ranked (recency + engagement).
    case forYou
    /// Chronological, authors the viewer follows.
    case following
    /// Posts by the viewer's verified compatriots.
    case myCountry
    /// `scope = international` only.
    case international

    public var id: String { rawValue }

    /// Segmented-control label.
    public var title: String {
        switch self {
        case .forYou: return L10n.t("feed.tab.forYou")
        case .following: return L10n.t("feed.tab.following")
        case .myCountry: return L10n.t("feed.tab.myCountry")
        case .international: return L10n.t("feed.tab.international")
        }
    }

    /// API path under ``AppConfig/apiBaseURL``.
    public var path: String {
        switch self {
        case .forYou: return "/feed/for-you"
        case .following: return "/feed/following"
        case .myCountry: return "/feed/country"
        case .international: return "/feed/international"
        }
    }

    /// Accessibility hint for the segmented control.
    public var accessibilityHint: String {
        switch self {
        case .forYou: return L10n.t("feed.tab.forYou.hint")
        case .following: return L10n.t("feed.tab.following.hint")
        case .myCountry: return L10n.t("feed.tab.myCountry.hint")
        case .international: return L10n.t("feed.tab.international.hint")
        }
    }
}
