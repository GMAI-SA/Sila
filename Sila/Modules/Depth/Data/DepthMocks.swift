import Foundation

/// An in-memory room: questions, polls, chat and co-hosts.
public final class RoomDepthServiceMock: RoomDepthServiceProtocol, @unchecked Sendable {
    private let lock = NSLock()
    public private(set) var questionList: [RoomQuestion] = [
        RoomQuestion(text: "What changed your mind about verification?", upvoteCount: 4),
        RoomQuestion(text: "Will rooms ever be recorded?", upvoteCount: 9)
    ]
    public private(set) var pollList: [RoomPoll] = []
    public private(set) var messageList: [RoomMessage] = [RoomMessage(text: "Evening all", author: FeedServiceMock.noor)]
    public private(set) var cohostList: [UserSummary] = []
    public private(set) var stageCalls: [String] = []

    public init() {}

    public func addCohost(_ handle: String, roomId: UUID) async throws -> [UserSummary] {
        lock.withLock {
            if cohostList.count >= 3 { return cohostList }
            cohostList.append(UserSummary(id: UUID(), handle: handle, displayName: handle, isVerified: true))
            return cohostList
        }
    }

    public func removeCohost(_ handle: String, roomId: UUID) async throws -> [UserSummary] {
        lock.withLock {
            cohostList.removeAll { $0.handle == handle }
            return cohostList
        }
    }

    public func questions(roomId: UUID, status: RoomQuestion.Status) async throws -> [RoomQuestion] {
        lock.withLock {
            questionList.filter { $0.status == status }
                .sorted { ($0.pinned ? 1 : 0, $0.upvoteCount) > ($1.pinned ? 1 : 0, $1.upvoteCount) }
        }
    }

    public func ask(_ text: String, roomId: UUID) async throws -> RoomQuestion {
        lock.withLock {
            let question = RoomQuestion(text: text, isAuthor: true)
            questionList.append(question)
            return question
        }
    }

    public func setUpvote(_ on: Bool, questionId: UUID, roomId: UUID) async throws {
        lock.withLock {
            guard let i = questionList.firstIndex(where: { $0.id == questionId }) else { return }
            let q = questionList[i]
            questionList[i] = RoomQuestion(id: q.id, text: q.text, author: q.author, status: q.status,
                                           upvoteCount: q.upvoteCount + (on ? 1 : -1), pinned: q.pinned,
                                           viewerUpvoted: on, isAuthor: q.isAuthor, createdAt: q.createdAt)
        }
    }

    public func stage(_ action: String, questionId: UUID, roomId: UUID) async throws {
        lock.withLock {
            stageCalls.append(action)
            questionList = questionList.map { q in
                let isTarget = q.id == questionId
                let status: RoomQuestion.Status = isTarget
                    ? (action == "answer" ? .answered : action == "dismiss" ? .dismissed : action == "reopen" ? .open : q.status)
                    : q.status
                let pinned = action == "pin" ? isTarget : (isTarget && action == "unpin" ? false : q.pinned)
                return RoomQuestion(id: q.id, text: q.text, author: q.author, status: status, upvoteCount: q.upvoteCount,
                                    pinned: pinned, viewerUpvoted: q.viewerUpvoted, isAuthor: q.isAuthor, createdAt: q.createdAt)
            }
        }
    }

    public func withdraw(questionId: UUID, roomId: UUID) async throws {
        lock.withLock { questionList.removeAll { $0.id == questionId } }
    }

    public func polls(roomId: UUID) async throws -> [RoomPoll] { lock.withLock { pollList } }

    public func openPoll(question: String, options: [String], durationSeconds: Int, roomId: UUID) async throws -> RoomPoll {
        try lock.withLock {
            if pollList.contains(where: { !$0.poll.closed }) {
                throw APIError.api(code: .pollOpen, message: "A poll is already open", status: 409)
            }
            let poll = RoomPoll(poll: Poll(options: options.enumerated().map { PollOption(position: $0.offset, text: $0.element, votes: 0) },
                                           closesAt: Date().addingTimeInterval(TimeInterval(durationSeconds)),
                                           resultsVisibility: .always, resultsVisible: true, canVote: true),
                                question: question)
            pollList.insert(poll, at: 0)
            return poll
        }
    }

    public func vote(optionId: UUID, pollId: UUID, roomId: UUID) async throws -> RoomPoll {
        try lock.withLock {
            guard let i = pollList.firstIndex(where: { $0.id == pollId }) else { throw APIError.api(code: .pollNotFound, message: "", status: 404) }
            let p = pollList[i].poll
            let options = p.options.map { PollOption(id: $0.id, position: $0.position, text: $0.text, votes: ($0.votes ?? 0) + ($0.id == optionId ? 1 : 0)) }
            let next = RoomPoll(poll: Poll(id: p.id, options: options, totalVotes: p.totalVotes + 1, closesAt: p.closesAt,
                                           resultsVisibility: .always, resultsVisible: true, viewerOptionId: optionId,
                                           canVote: false, voteBlockReason: .alreadyVoted), question: pollList[i].question)
            pollList[i] = next
            return next
        }
    }

    public func closePoll(_ pollId: UUID, roomId: UUID) async throws -> RoomPoll {
        try lock.withLock {
            guard let i = pollList.firstIndex(where: { $0.id == pollId }) else { throw APIError.api(code: .pollNotFound, message: "", status: 404) }
            let p = pollList[i].poll
            let next = RoomPoll(poll: Poll(id: p.id, options: p.options, totalVotes: p.totalVotes, closesAt: Date(), closed: true,
                                           resultsVisibility: .always, resultsVisible: true, viewerOptionId: p.viewerOptionId,
                                           canVote: false, voteBlockReason: .closed), question: pollList[i].question)
            pollList[i] = next
            return next
        }
    }

    public func messages(roomId: UUID) async throws -> [RoomMessage] { lock.withLock { messageList } }

    public func send(_ text: String, roomId: UUID) async throws -> RoomMessage {
        lock.withLock {
            let message = RoomMessage(text: text, author: FeedServiceMock.aziz)
            messageList.append(message)
            return message
        }
    }

    public func hide(messageId: UUID, roomId: UUID) async throws {
        lock.withLock {
            messageList = messageList.map { $0.id == messageId ? RoomMessage(id: $0.id, text: $0.text, author: $0.author, createdAt: $0.createdAt, hidden: true) : $0 }
        }
    }
}

public final class SafetyDepthServiceMock: SafetyDepthServiceProtocol, @unchecked Sendable {
    private let lock = NSLock()
    public private(set) var terms: [MutedTerm] = []
    public private(set) var accepted: [String] = []

    public init() {}

    public func mutedTerms() async throws -> [MutedTerm] { lock.withLock { terms } }

    public func muteTerm(_ term: String) async throws -> MutedTerm {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { throw APIError.api(code: .termTooShort, message: "", status: 400) }
        return lock.withLock {
            let made = MutedTerm(id: UUID(), term: trimmed)
            terms.append(made)
            return made
        }
    }

    public func unmuteTerm(_ id: UUID) async throws {
        lock.withLock { terms.removeAll { $0.id == id } }
    }

    public func guidelines() async throws -> Guidelines {
        Guidelines(version: "2", sections: [
            .init(id: "real", title: "Be who you are", titleAr: "كن أنت", body: "Every account is a verified person.", bodyAr: "كل حساب شخص موثّق."),
            .init(id: "kind", title: "Disagree without harm", titleAr: "اختلف دون أذى", body: "Argue with ideas, not people.", bodyAr: "ناقش الأفكار لا الأشخاص.")
        ])
    }

    public func acceptGuidelines(version: String) async throws {
        lock.withLock { accepted.append(version) }
    }
}
