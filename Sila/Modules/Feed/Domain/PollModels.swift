import Foundation

// MARK: - Poll (contract v19)

/// One answer in a poll.
public struct PollOption: Identifiable, Equatable, Hashable, Sendable, Decodable {
    public let id: UUID
    public let position: Int
    public let text: String
    /// `nil` while results are hidden from this viewer — never read as zero.
    public let votes: Int?

    public init(id: UUID = UUID(), position: Int, text: String, votes: Int? = nil) {
        self.id = id
        self.position = position
        self.text = text
        self.votes = votes
    }

    private enum CodingKeys: String, CodingKey { case id, position, text, votes }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        position = (try? c.decode(Int.self, forKey: .position)) ?? 0
        text = (try? c.decode(String.self, forKey: .text)) ?? ""
        votes = (try? c.decodeIfPresent(Int.self, forKey: .votes)) ?? nil
    }
}

/// When a poll's counts become visible.
public enum PollResultsVisibility: String, Sendable, Hashable, CaseIterable, Identifiable {
    case always
    case afterVote = "after_vote"
    case afterClose = "after_close"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .always: return L10n.t("poll.visibility.always")
        case .afterVote: return L10n.t("poll.visibility.afterVote")
        case .afterClose: return L10n.t("poll.visibility.afterClose")
        }
    }
}

/// Why this viewer cannot vote.
public enum PollVoteBlock: String, Sendable, Hashable {
    case closed
    case alreadyVoted = "already_voted"
    case author
    case unverified
    case countryMismatch = "country_mismatch"
    case regionMismatch = "region_mismatch"
    case guest
    case unknown
}

/// A poll as one viewer may see it.
///
/// **Votes are anonymous.** Nothing here says who chose what; the only choice
/// ever known is the viewer's own, told to them alone.
public struct Poll: Identifiable, Equatable, Hashable, Sendable, Decodable {
    public let id: UUID
    public let options: [PollOption]
    public let totalVotes: Int
    public let closesAt: Date
    public let closed: Bool
    public let resultsVisibility: PollResultsVisibility
    public let resultsVisible: Bool
    public let viewerOptionId: UUID?
    public let canVote: Bool
    public let voteBlockReason: PollVoteBlock?

    public init(
        id: UUID = UUID(),
        options: [PollOption],
        totalVotes: Int = 0,
        closesAt: Date,
        closed: Bool = false,
        resultsVisibility: PollResultsVisibility = .afterVote,
        resultsVisible: Bool = false,
        viewerOptionId: UUID? = nil,
        canVote: Bool = true,
        voteBlockReason: PollVoteBlock? = nil
    ) {
        self.id = id
        self.options = options.sorted { $0.position < $1.position }
        self.totalVotes = totalVotes
        self.closesAt = closesAt
        self.closed = closed
        self.resultsVisibility = resultsVisibility
        self.resultsVisible = resultsVisible
        self.viewerOptionId = viewerOptionId
        self.canVote = canVote
        self.voteBlockReason = voteBlockReason
    }

    private enum CodingKeys: String, CodingKey {
        case id, options, totalVotes, closesAt, closed, resultsVisibility, resultsVisible
        case viewerOptionId, canVote, voteBlockReason
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        options = ((try? c.decode([PollOption].self, forKey: .options)) ?? []).sorted { $0.position < $1.position }
        totalVotes = (try? c.decode(Int.self, forKey: .totalVotes)) ?? 0
        closesAt = (try? c.decode(Date.self, forKey: .closesAt)) ?? Date()
        closed = (try? c.decode(Bool.self, forKey: .closed)) ?? false
        let rawVisibility = (try? c.decode(String.self, forKey: .resultsVisibility)) ?? ""
        resultsVisibility = PollResultsVisibility(rawValue: rawVisibility) ?? .afterVote
        resultsVisible = (try? c.decode(Bool.self, forKey: .resultsVisible)) ?? false
        viewerOptionId = (try? c.decodeIfPresent(UUID.self, forKey: .viewerOptionId)) ?? nil
        canVote = (try? c.decode(Bool.self, forKey: .canVote)) ?? false
        let rawReason = (try? c.decodeIfPresent(String.self, forKey: .voteBlockReason)) ?? nil
        voteBlockReason = rawReason.map { PollVoteBlock(rawValue: $0) ?? .unknown }
    }

    /// Closed by the clock even if the last fetch said open.
    public func isClosed(now: Date = Date()) -> Bool { closed || closesAt <= now }

    /// The share of one option, 0…1, or `nil` when counts are hidden.
    public func share(of option: PollOption) -> Double? {
        guard resultsVisible, let votes = option.votes else { return nil }
        guard totalVotes > 0 else { return 0 }
        return Double(votes) / Double(totalVotes)
    }
}

/// An `@name` in a post that is a real account (contract v19).
public struct PostMention: Equatable, Hashable, Sendable, Decodable {
    public let handle: String
    public let userId: UUID

    public init(handle: String, userId: UUID) {
        self.handle = handle.lowercased()
        self.userId = userId
    }

    private enum CodingKeys: String, CodingKey { case handle, userId }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        handle = try c.decode(String.self, forKey: .handle).lowercased()
        userId = try c.decode(UUID.self, forKey: .userId)
    }
}

// MARK: - Drafting a poll

/// The composer's poll, before it is sent.
public struct PollDraft: Equatable, Sendable {

    public static let minOptions = 2
    public static let maxOptions = 4
    public static let maxOptionLength = 40

    /// The durations the composer offers, in minutes.
    public enum Duration: Int, CaseIterable, Identifiable, Sendable {
        case oneHour = 60
        case sixHours = 360
        case oneDay = 1_440
        case threeDays = 4_320
        case sevenDays = 10_080

        public var id: Int { rawValue }

        public var title: String {
            switch self {
            case .oneHour: return L10n.t("poll.duration.1h")
            case .sixHours: return L10n.t("poll.duration.6h")
            case .oneDay: return L10n.t("poll.duration.24h")
            case .threeDays: return L10n.t("poll.duration.3d")
            case .sevenDays: return L10n.t("poll.duration.7d")
            }
        }
    }

    public var options: [String]
    public var duration: Duration
    public var visibility: PollResultsVisibility

    public init(options: [String] = ["", ""], duration: Duration = .oneDay, visibility: PollResultsVisibility = .afterVote) {
        self.options = options
        self.duration = duration
        self.visibility = visibility
    }

    public var canAddOption: Bool { options.count < Self.maxOptions }
    public var canRemoveOption: Bool { options.count > Self.minOptions }

    public var trimmed: [String] { options.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } }

    /// Why the poll cannot be sent yet, or `nil`.
    public var problem: String? {
        let values = trimmed
        if values.count < Self.minOptions || values.count > Self.maxOptions { return L10n.t("poll.error.count") }
        if values.contains(where: \.isEmpty) { return L10n.t("poll.error.empty") }
        if values.contains(where: { $0.count > Self.maxOptionLength }) { return L10n.t("poll.error.tooLong") }
        if Set(values.map { $0.lowercased() }).count != values.count { return L10n.t("poll.error.duplicate") }
        return nil
    }

    public var isValid: Bool { problem == nil }

    public var payload: PollPayload {
        PollPayload(options: trimmed, durationMinutes: duration.rawValue, resultsVisibility: visibility.rawValue)
    }
}

/// The `poll` object of `POST /posts`.
public struct PollPayload: Encodable, Equatable, Sendable {
    public let options: [String]
    public let durationMinutes: Int
    public let resultsVisibility: String
}

/// `POST /posts/{id}/poll/votes`.
public struct PollVoteRequest: Encodable, Equatable, Sendable {
    public let optionId: UUID
}
