import Foundation

/// Why a person is suggested (contract v19): the client says it in words.
public enum SuggestionReason: String, Sendable, Hashable {
    case topic
    case country
    case active

    public var label: String {
        switch self {
        case .topic: return L10n.t("discover.people.reason.topic")
        case .country: return L10n.t("discover.people.reason.country")
        case .active: return L10n.t("discover.people.reason.active")
        }
    }
}

/// One row of `GET /discover/people`.
public struct SuggestedPerson: Identifiable, Equatable, Hashable, Sendable, Decodable {
    public let user: UserSummary
    public let reason: SuggestionReason
    public let recentPosts: Int

    public var id: UUID { user.id }

    public init(user: UserSummary, reason: SuggestionReason, recentPosts: Int = 0) {
        self.user = user
        self.reason = reason
        self.recentPosts = recentPosts
    }

    private enum CodingKeys: String, CodingKey { case user, reason, recentPosts }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        user = try c.decode(UserSummary.self, forKey: .user)
        reason = SuggestionReason(rawValue: (try? c.decode(String.self, forKey: .reason)) ?? "") ?? .active
        recentPosts = (try? c.decode(Int.self, forKey: .recentPosts)) ?? 0
    }
}

struct PeopleResponse: Decodable {
    let people: [SuggestedPerson]
    private enum CodingKeys: String, CodingKey { case people }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        people = (try? c.decode([FailableDecodable<SuggestedPerson>].self, forKey: .people))?.compactMap(\.value) ?? []
    }
}

/// One subject's section of `GET /discover/trending`.
public struct TrendingSection: Identifiable, Equatable, Sendable, Decodable {
    public let topic: String
    public let label: String?
    public let labelAr: String?
    public let posts: [Post]

    public var id: String { topic }

    public init(topic: String, label: String? = nil, labelAr: String? = nil, posts: [Post]) {
        self.topic = topic
        self.label = label
        self.labelAr = labelAr
        self.posts = posts
    }

    /// The subject's name in the reading language.
    public var title: String {
        if L10n.languageCode == "ar", let labelAr, !labelAr.isEmpty { return labelAr }
        return label ?? topic
    }

    private enum CodingKeys: String, CodingKey { case topic, label, labelAr, posts }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        topic = try c.decode(String.self, forKey: .topic)
        label = (try? c.decodeIfPresent(String.self, forKey: .label)) ?? nil
        labelAr = (try? c.decodeIfPresent(String.self, forKey: .labelAr)) ?? nil
        posts = (try? c.decode([FailableDecodable<Post>].self, forKey: .posts))?.compactMap(\.value) ?? []
    }
}

struct TrendingResponseV19: Decodable {
    let sections: [TrendingSection]
    private enum CodingKeys: String, CodingKey { case sections }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sections = (try? c.decode([FailableDecodable<TrendingSection>].self, forKey: .sections))?.compactMap(\.value) ?? []
    }
}

/// A phrase offered above an empty composer (`GET /composer/starters`).
public struct ComposerStarter: Identifiable, Equatable, Hashable, Sendable, Decodable {
    public enum Kind: String, Sendable, Hashable { case text, poll }

    public let id: String
    public let text: String
    public let textAr: String
    public let kind: Kind
    public let hashtag: String?

    public init(id: String, text: String, textAr: String, kind: Kind = .text, hashtag: String? = nil) {
        self.id = id
        self.text = text
        self.textAr = textAr
        self.kind = kind
        self.hashtag = hashtag
    }

    /// The phrase in the interface language.
    public func phrase(languageCode: String = L10n.languageCode) -> String {
        languageCode == "ar" && !textAr.isEmpty ? textAr : text
    }

    private enum CodingKeys: String, CodingKey { case id, text, textAr, kind, hashtag }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        text = (try? c.decode(String.self, forKey: .text)) ?? ""
        textAr = (try? c.decode(String.self, forKey: .textAr)) ?? ""
        kind = Kind(rawValue: (try? c.decode(String.self, forKey: .kind)) ?? "") ?? .text
        hashtag = (try? c.decodeIfPresent(String.self, forKey: .hashtag)) ?? nil
    }
}

struct StartersResponse: Decodable {
    let starters: [ComposerStarter]
    private enum CodingKeys: String, CodingKey { case starters }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        starters = (try? c.decode([FailableDecodable<ComposerStarter>].self, forKey: .starters))?.compactMap(\.value) ?? []
    }
}

/// `POST /me/onboarding/interests`.
public struct OnboardingInterestsRequest: Encodable, Equatable, Sendable {
    public let topics: [String]
    public let skipped: Bool
}

/// Decodes an element or yields `nil`, so one malformed row costs one row.
struct FailableDecodable<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}
