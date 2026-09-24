import Foundation

// MARK: - Contract v22: depth of conversation

/// The four qualitative reactions. A closed vocabulary: it is what lets
/// "Helpful" mean something and a badge be computed.
public enum ReactionKind: String, CaseIterable, Identifiable, Sendable, Hashable {
    case helpful, question, insight, funny

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .helpful: return L10n.t("reaction.helpful")
        case .question: return L10n.t("reaction.question")
        case .insight: return L10n.t("reaction.insight")
        case .funny: return L10n.t("reaction.funny")
        }
    }

    public var icon: String {
        switch self {
        case .helpful: return "hands.clap"
        case .question: return "questionmark.circle"
        case .insight: return "lightbulb"
        case .funny: return "face.smiling"
        }
    }
}

/// `GET /posts/{id}/thread`.
public struct PostThread: Equatable, Sendable, Decodable {
    public let ancestors: [Post]
    public let post: Post
    public let replies: FeedPage

    private enum CodingKeys: String, CodingKey { case ancestors, post, replies }

    public init(ancestors: [Post], post: Post, replies: FeedPage) {
        self.ancestors = ancestors
        self.post = post
        self.replies = replies
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ancestors = (try? c.decode([FailableDecodable<Post>].self, forKey: .ancestors))?.compactMap(\.value) ?? []
        post = try c.decode(Post.self, forKey: .post)
        replies = (try? c.decode(FeedPage.self, forKey: .replies)) ?? .empty
    }
}

/// A question in a room's queue.
public struct RoomQuestion: Identifiable, Equatable, Hashable, Sendable, Decodable {
    public enum Status: String, Sendable { case open, answered, dismissed }

    public let id: UUID
    public let text: String
    public let author: UserSummary?
    public let status: Status
    public let upvoteCount: Int
    public let pinned: Bool
    public let viewerUpvoted: Bool
    public let isAuthor: Bool
    public let createdAt: Date

    public init(id: UUID = UUID(), text: String, author: UserSummary? = nil, status: Status = .open,
                upvoteCount: Int = 0, pinned: Bool = false, viewerUpvoted: Bool = false, isAuthor: Bool = false,
                createdAt: Date = Date()) {
        self.id = id; self.text = text; self.author = author; self.status = status; self.upvoteCount = upvoteCount
        self.pinned = pinned; self.viewerUpvoted = viewerUpvoted; self.isAuthor = isAuthor; self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, text, author, status, upvoteCount, pinned, viewerUpvoted, isAuthor, createdAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        text = (try? c.decode(String.self, forKey: .text)) ?? ""
        author = (try? c.decodeIfPresent(UserSummary.self, forKey: .author)) ?? nil
        status = Status(rawValue: (try? c.decode(String.self, forKey: .status)) ?? "") ?? .open
        upvoteCount = (try? c.decode(Int.self, forKey: .upvoteCount)) ?? 0
        pinned = (try? c.decode(Bool.self, forKey: .pinned)) ?? false
        viewerUpvoted = (try? c.decode(Bool.self, forKey: .viewerUpvoted)) ?? false
        isAuthor = (try? c.decode(Bool.self, forKey: .isAuthor)) ?? false
        createdAt = (try? c.decode(Date.self, forKey: .createdAt)) ?? Date()
    }
}

/// A room's pinned question, as `RoomOut` carries it.
public struct PinnedQuestion: Equatable, Hashable, Sendable, Decodable {
    public let id: UUID
    public let text: String
    public let upvoteCount: Int

    public init(id: UUID, text: String, upvoteCount: Int = 0) {
        self.id = id
        self.text = text
        self.upvoteCount = upvoteCount
    }

    private enum CodingKeys: String, CodingKey { case id, text, upvoteCount }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        text = (try? c.decode(String.self, forKey: .text)) ?? ""
        upvoteCount = (try? c.decode(Int.self, forKey: .upvoteCount)) ?? 0
    }
}

/// A poll inside a room: a ``Poll`` plus its own question.
public struct RoomPoll: Identifiable, Equatable, Sendable, Decodable {
    public let poll: Poll
    public let question: String

    public var id: UUID { poll.id }

    public init(poll: Poll, question: String) {
        self.poll = poll
        self.question = question
    }

    private enum CodingKeys: String, CodingKey { case question }

    public init(from decoder: Decoder) throws {
        poll = try Poll(from: decoder)
        question = (try? decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .question)) ?? ""
    }
}

/// A persisted line of room chat.
public struct RoomMessage: Identifiable, Equatable, Sendable, Decodable {
    public let id: UUID
    public let text: String
    public let author: UserSummary?
    public let createdAt: Date
    public let hidden: Bool

    public init(id: UUID = UUID(), text: String, author: UserSummary? = nil, createdAt: Date = Date(), hidden: Bool = false) {
        self.id = id; self.text = text; self.author = author; self.createdAt = createdAt; self.hidden = hidden
    }

    private enum CodingKeys: String, CodingKey { case id, text, author, createdAt, hidden }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        text = (try? c.decode(String.self, forKey: .text)) ?? ""
        author = (try? c.decodeIfPresent(UserSummary.self, forKey: .author)) ?? nil
        createdAt = (try? c.decode(Date.self, forKey: .createdAt)) ?? Date()
        hidden = (try? c.decode(Bool.self, forKey: .hidden)) ?? false
    }
}

struct QuestionsEnvelope: Decodable { let questions: [RoomQuestion] }
struct RoomPollsEnvelope: Decodable {
    let polls: [RoomPoll]
    private enum CodingKeys: String, CodingKey { case polls }
    init(from decoder: Decoder) throws {
        polls = (try? decoder.container(keyedBy: CodingKeys.self).decode([FailableDecodable<RoomPoll>].self, forKey: .polls))?
            .compactMap(\.value) ?? []
    }
}
struct RoomMessagesEnvelope: Decodable { let messages: [RoomMessage] }
struct CohostsEnvelope: Decodable { let cohosts: [UserSummary] }
struct HandleBody: Encodable { let handle: String }
struct TextBody: Encodable { let text: String }
struct StageActionBody: Encodable { let action: String }
struct CreateRoomPollBody: Encodable { let question: String; let options: [String]; let durationSeconds: Int }

/// A muted word or phrase.
public struct MutedTerm: Identifiable, Equatable, Sendable, Decodable {
    public let id: UUID
    public let term: String
}
struct MutedTermsEnvelope: Decodable { let terms: [MutedTerm] }
struct TermBody: Encodable { let term: String }

/// The community guidelines (contract v22).
public struct Guidelines: Equatable, Sendable, Decodable {
    public struct Section: Identifiable, Equatable, Sendable, Decodable {
        public let id: String
        public let title: String
        public let titleAr: String?
        public let body: String
        public let bodyAr: String?

        public init(id: String, title: String, titleAr: String? = nil, body: String, bodyAr: String? = nil) {
            self.id = id; self.title = title; self.titleAr = titleAr; self.body = body; self.bodyAr = bodyAr
        }

        public func localizedTitle(_ language: String = L10n.languageCode) -> String {
            language == "ar" && titleAr?.isEmpty == false ? titleAr! : title
        }

        public func localizedBody(_ language: String = L10n.languageCode) -> String {
            language == "ar" && bodyAr?.isEmpty == false ? bodyAr! : body
        }
    }

    public let version: String
    public let sections: [Section]

    public init(version: String, sections: [Section]) {
        self.version = version
        self.sections = sections
    }

    private enum CodingKeys: String, CodingKey { case version, sections }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let text = try? c.decode(String.self, forKey: .version) {
            version = text
        } else {
            version = String((try? c.decode(Int.self, forKey: .version)) ?? 0)
        }
        sections = (try? c.decode([Section].self, forKey: .sections)) ?? []
    }
}
struct AcceptGuidelinesBody: Encodable { let version: String }
