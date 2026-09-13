import Foundation

// MARK: - GIF

/// One animated picture from the GIF library, as a post carries it.
///
/// The server stores every GIF anybody shares — with the sharer's verified
/// country — which is what makes "popular in Saudi Arabia" a list of what
/// people from Saudi Arabia actually share rather than a guess. ``url`` is a
/// looping video when the provider has one (cheaper to play than a GIF),
/// ``previewURL`` a small animated rendition for grids, ``stillURL`` one frame
/// for before anything has loaded.
public struct Gif: Equatable, Hashable, Sendable, Decodable {

    /// Sila's own row, once the GIF has been shared here at least once.
    public let id: UUID?
    public let provider: String
    public let providerId: String
    public let url: URL
    public let gifURL: URL?
    public let previewURL: URL?
    public let stillURL: URL?
    public let width: Int
    public let height: Int
    public let title: String?
    /// How many posts on Sila carry it.
    public let shareCount: Int

    public init(
        id: UUID? = nil,
        provider: String = "tenor",
        providerId: String,
        url: URL,
        gifURL: URL? = nil,
        previewURL: URL? = nil,
        stillURL: URL? = nil,
        width: Int = 0,
        height: Int = 0,
        title: String? = nil,
        shareCount: Int = 0
    ) {
        self.id = id
        self.provider = provider
        self.providerId = providerId
        self.url = url
        self.gifURL = gifURL
        self.previewURL = previewURL
        self.stillURL = stillURL
        self.width = width
        self.height = height
        self.title = title
        self.shareCount = shareCount
    }

    private enum CodingKeys: String, CodingKey {
        case id, provider, providerId, url, width, height, title, shareCount
        case gifURL = "gifUrl"
        case previewURL = "previewUrl"
        case stillURL = "stillUrl"
    }

    /// Tolerant everywhere but the one thing a card cannot do without: a URL
    /// to play. A GIF with no playable URL is no GIF, and the post renders
    /// without it rather than not at all.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let raw = try? container.decode(String.self, forKey: .url), let url = URL(string: raw) else {
            throw DecodingError.dataCorruptedError(forKey: .url, in: container, debugDescription: "no url")
        }
        self.url = url
        id = (try? container.decodeIfPresent(UUID.self, forKey: .id)) ?? nil
        provider = (try? container.decode(String.self, forKey: .provider)) ?? "tenor"
        providerId = (try? container.decode(String.self, forKey: .providerId)) ?? ""
        gifURL = Self.url(container, .gifURL)
        previewURL = Self.url(container, .previewURL)
        stillURL = Self.url(container, .stillURL)
        width = (try? container.decode(Int.self, forKey: .width)) ?? 0
        height = (try? container.decode(Int.self, forKey: .height)) ?? 0
        let name = (try? container.decodeIfPresent(String.self, forKey: .title)) ?? nil
        title = (name?.isEmpty == false) ? name : nil
        shareCount = (try? container.decode(Int.self, forKey: .shareCount)) ?? 0
    }

    private static func url(_ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> URL? {
        guard let raw = (try? container.decodeIfPresent(String.self, forKey: key)) ?? nil else { return nil }
        return URL(string: raw)
    }

    /// Width over height, for sizing a frame before the media arrives.
    /// Falls back to a landscape box when the provider sent no dimensions.
    public var aspectRatio: Double {
        width > 0 && height > 0 ? Double(width) / Double(height) : 16.0 / 9.0
    }

    /// Whether ``url`` is a video rendition (mp4) rather than a GIF.
    public var isVideo: Bool { url.pathExtension.lowercased() == "mp4" }

    /// The best small animated rendition for a grid.
    public var thumbnailURL: URL { previewURL ?? gifURL ?? url }

    /// Identity for lists: the provider's id, which is stable before Sila
    /// has a row of its own.
    public var listKey: String { "\(provider):\(providerId)" }
}

// MARK: - Hashtags

/// How a hashtag's page is ordered. Remembered per account on the server.
public enum HashtagSort: String, CaseIterable, Identifiable, Sendable, Decodable {
    case newest
    case top
    case mostViewed = "most_viewed"
    case mostDiscussed = "most_discussed"
    case mostReposted = "most_reposted"

    public var id: String { rawValue }

    /// The wire value, or newest for anything unrecognised.
    public init(wire: String?) {
        self = HashtagSort(rawValue: wire ?? "") ?? .newest
    }

    /// What the picker calls it.
    public var title: String {
        switch self {
        case .newest: return L10n.t("feed.hashtag.sort.newest")
        case .top: return L10n.t("feed.hashtag.sort.top")
        case .mostViewed: return L10n.t("feed.hashtag.sort.mostViewed")
        case .mostDiscussed: return L10n.t("feed.hashtag.sort.mostDiscussed")
        case .mostReposted: return L10n.t("feed.hashtag.sort.mostReposted")
        }
    }

    public var icon: String {
        switch self {
        case .newest: return "clock"
        case .top: return "heart"
        case .mostViewed: return "eye"
        case .mostDiscussed: return "bubble.left.and.bubble.right"
        case .mostReposted: return "arrow.2.squarepath"
        }
    }
}

/// A tag's header: how many visible posts carry it, and the viewer's order.
public struct HashtagHeader: Equatable, Sendable, Decodable {
    public let tag: String
    public let postCount: Int
    public let sort: HashtagSort

    public init(tag: String, postCount: Int, sort: HashtagSort = .newest) {
        self.tag = tag
        self.postCount = postCount
        self.sort = sort
    }

    private enum CodingKeys: String, CodingKey { case tag, postCount, sort }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tag = (try? container.decode(String.self, forKey: .tag)) ?? ""
        postCount = (try? container.decode(Int.self, forKey: .postCount)) ?? 0
        sort = HashtagSort(wire: (try? container.decode(String.self, forKey: .sort)) ?? nil)
    }
}

/// One page of a tag, with the order it was actually served in.
public struct HashtagPage: Equatable, Sendable, Decodable {
    public let posts: [Post]
    public let nextCursor: String?
    public let hasMore: Bool
    public let tag: String
    public let sort: HashtagSort
    public let postCount: Int

    public init(posts: [Post], nextCursor: String? = nil, hasMore: Bool = false, tag: String, sort: HashtagSort = .newest, postCount: Int = 0) {
        self.posts = posts
        self.nextCursor = nextCursor
        self.hasMore = hasMore && nextCursor != nil
        self.tag = tag
        self.sort = sort
        self.postCount = postCount
    }

    private enum CodingKeys: String, CodingKey { case posts, nextCursor, hasMore, tag, sort, postCount }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        posts = (try? container.decode([Post].self, forKey: .posts)) ?? []
        let cursor = (try? container.decodeIfPresent(String.self, forKey: .nextCursor)) ?? nil
        nextCursor = (cursor?.isEmpty == false) ? cursor : nil
        let flag = (try? container.decode(Bool.self, forKey: .hasMore)) ?? (nextCursor != nil)
        hasMore = flag && nextCursor != nil
        tag = (try? container.decode(String.self, forKey: .tag)) ?? ""
        sort = HashtagSort(wire: (try? container.decode(String.self, forKey: .sort)) ?? nil)
        postCount = (try? container.decode(Int.self, forKey: .postCount)) ?? posts.count
    }
}
