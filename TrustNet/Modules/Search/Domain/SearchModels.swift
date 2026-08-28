import Foundation

// MARK: - Constants

/// Search limits from contract v3.
public enum SearchConstants {

    /// Below this, the server returns an empty list rather than the whole
    /// table — so the client does not spend a request finding that out.
    public static let minimumQueryLength = 2

    /// Default `limit` for `/search/users`.
    public static let defaultUserLimit = 8
    /// Server maximum for `/search/users`.
    public static let maximumUserLimit = 20

    /// Default `limit` for `/explore/trending`.
    public static let defaultTrendingLimit = 10
    /// Server maximum for `/explore/trending`.
    public static let maximumTrendingLimit = 20

    /// How long Explore waits after a keystroke before querying.
    public static let searchDebounce: TimeInterval = 0.3

    /// `true` when a query is worth sending.
    /// - Parameter query: Raw contents of the search field.
    public static func isSearchable(_ query: String) -> Bool {
        query.trimmingCharacters(in: .whitespacesAndNewlines).count >= minimumQueryLength
    }
}

// MARK: - Trending

/// One hashtag on the Explore screen.
///
/// The server counts tags across the most recent 500 posts only, so this is
/// "what is being talked about now" — not an all-time leaderboard. The UI says
/// so rather than implying a global ranking.
public struct TrendingTag: Identifiable, Hashable, Sendable, Decodable {

    /// The tag **without** its `#`, lowercased — exactly as the server sends it.
    public let tag: String
    /// How many recent posts used it.
    public let postCount: Int

    public var id: String { tag }

    /// The tag as it is rendered and as it is searched for.
    public var hashtag: String { "#\(tag)" }

    public init(tag: String, postCount: Int) {
        self.tag = TrendingTag.normalised(tag)
        self.postCount = max(0, postCount)
    }

    private enum CodingKeys: String, CodingKey {
        case tag, postCount
    }

    /// Tolerant decoder: a malformed row must not blank the whole trending list.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tag = TrendingTag.normalised((try? container.decode(String.self, forKey: .tag)) ?? "")
        postCount = max(0, (try? container.decode(Int.self, forKey: .postCount)) ?? 0)
    }

    /// Strips a leading `#` and lowercases.
    ///
    /// The contract promises the server already does both; doing it again costs
    /// nothing and means one stray `#riyadh` cannot render as `##riyadh`.
    static func normalised(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasPrefix("#") { value.removeFirst() }
        return value.lowercased()
    }

    /// `true` when the row carries an actual tag.
    public var isValid: Bool { !tag.isEmpty }
}

// MARK: - Wire shapes

/// `GET /search/users` → `{"users": [UserSummary]}`.
struct UserSearchResponse: Decodable {
    let users: [UserSummary]

    private enum CodingKeys: String, CodingKey {
        case users
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        users = (try? container.decode([UserSummary].self, forKey: .users)) ?? []
    }

    init(users: [UserSummary]) {
        self.users = users
    }
}

/// `GET /explore/trending` → `{"tags": [{"tag": …, "post_count": …}]}`.
struct TrendingResponse: Decodable {
    let tags: [TrendingTag]

    private enum CodingKeys: String, CodingKey {
        case tags
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Rows with no usable tag are dropped rather than rendered as an empty
        // chip the user cannot tap.
        tags = ((try? container.decode([TrendingTag].self, forKey: .tags)) ?? [])
            .filter(\.isValid)
    }

    init(tags: [TrendingTag]) {
        self.tags = tags
    }
}
