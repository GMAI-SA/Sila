import Foundation

/// A room's depth (contract v22): co-hosts, the question queue, polls, chat.
public protocol RoomDepthServiceProtocol: Sendable {
    func addCohost(_ handle: String, roomId: UUID) async throws -> [UserSummary]
    func removeCohost(_ handle: String, roomId: UUID) async throws -> [UserSummary]
    func questions(roomId: UUID, status: RoomQuestion.Status) async throws -> [RoomQuestion]
    func ask(_ text: String, roomId: UUID) async throws -> RoomQuestion
    func setUpvote(_ on: Bool, questionId: UUID, roomId: UUID) async throws
    /// `pin | unpin | answer | dismiss | reopen` — the stage's verbs.
    func stage(_ action: String, questionId: UUID, roomId: UUID) async throws
    func withdraw(questionId: UUID, roomId: UUID) async throws
    func polls(roomId: UUID) async throws -> [RoomPoll]
    func openPoll(question: String, options: [String], durationSeconds: Int, roomId: UUID) async throws -> RoomPoll
    func vote(optionId: UUID, pollId: UUID, roomId: UUID) async throws -> RoomPoll
    func closePoll(_ pollId: UUID, roomId: UUID) async throws -> RoomPoll
    func messages(roomId: UUID) async throws -> [RoomMessage]
    func send(_ text: String, roomId: UUID) async throws -> RoomMessage
    func hide(messageId: UUID, roomId: UUID) async throws
}

/// Keyword mute and the community guidelines (contract v22).
public protocol SafetyDepthServiceProtocol: Sendable {
    func mutedTerms() async throws -> [MutedTerm]
    func muteTerm(_ term: String) async throws -> MutedTerm
    func unmuteTerm(_ id: UUID) async throws
    func guidelines() async throws -> Guidelines
    func acceptGuidelines(version: String) async throws
}

public final class RoomDepthService: RoomDepthServiceProtocol {
    private let network: NetworkClient
    private let tokens: AccessTokenProviding

    public init(network: NetworkClient, tokens: AccessTokenProviding) {
        self.network = network
        self.tokens = tokens
    }

    private func path(_ roomId: UUID, _ rest: String = "") -> String { "/rooms/\(roomId.uuidString.lowercased())\(rest)" }
    private func id(_ uuid: UUID) -> String { uuid.uuidString.lowercased() }

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = [], as type: T.Type) async throws -> T {
        let token = try await tokens.accessToken()
        return try await network.send(APIRequest(path: path, accessToken: token, query: query), as: type)
    }

    private func bare<T: Decodable>(_ path: String, method: HTTPMethod, as type: T.Type) async throws -> T {
        let token = try await tokens.accessToken()
        return try await network.send(APIRequest(path: path, method: method, accessToken: token), as: type)
    }

    private func json<B: Encodable, T: Decodable>(_ path: String, method: HTTPMethod = .post, body: B, as type: T.Type) async throws -> T {
        let token = try await tokens.accessToken()
        return try await network.send(try APIRequest.json(path, method: method, body: body, accessToken: token), as: type)
    }

    private func call(_ path: String, method: HTTPMethod) async throws {
        let token = try await tokens.accessToken()
        try await network.send(APIRequest(path: path, method: method, accessToken: token))
    }

    private func call<B: Encodable>(_ path: String, method: HTTPMethod, body: B) async throws {
        let token = try await tokens.accessToken()
        try await network.send(try APIRequest.json(path, method: method, body: body, accessToken: token))
    }

    public func addCohost(_ handle: String, roomId: UUID) async throws -> [UserSummary] {
        try await json(path(roomId, "/cohosts"), body: HandleBody(handle: handle), as: CohostsEnvelope.self).cohosts
    }

    public func removeCohost(_ handle: String, roomId: UUID) async throws -> [UserSummary] {
        let safe = Handle.pathComponent(handle)
        return try await bare(path(roomId, "/cohosts/\(safe)"), method: .delete, as: CohostsEnvelope.self).cohosts
    }

    public func questions(roomId: UUID, status: RoomQuestion.Status) async throws -> [RoomQuestion] {
        try await get(path(roomId, "/questions"), query: [URLQueryItem(name: "status", value: status.rawValue)],
                       as: QuestionsEnvelope.self).questions
    }

    public func ask(_ text: String, roomId: UUID) async throws -> RoomQuestion {
        try await json(path(roomId, "/questions"), body: TextBody(text: text), as: RoomQuestion.self)
    }

    public func setUpvote(_ on: Bool, questionId: UUID, roomId: UUID) async throws {
        try await call(path(roomId, "/questions/\(id(questionId))/vote"), method: on ? .post : .delete)
    }

    public func stage(_ action: String, questionId: UUID, roomId: UUID) async throws {
        try await call(path(roomId, "/questions/\(id(questionId))/stage"), method: .post, body: StageActionBody(action: action))
    }

    public func withdraw(questionId: UUID, roomId: UUID) async throws {
        try await call(path(roomId, "/questions/\(id(questionId))"), method: .delete)
    }

    public func polls(roomId: UUID) async throws -> [RoomPoll] {
        try await get(path(roomId, "/polls"), as: RoomPollsEnvelope.self).polls
    }

    public func openPoll(question: String, options: [String], durationSeconds: Int, roomId: UUID) async throws -> RoomPoll {
        try await json(path(roomId, "/polls"),
                       body: CreateRoomPollBody(question: question, options: options, durationSeconds: durationSeconds),
                       as: RoomPoll.self)
    }

    public func vote(optionId: UUID, pollId: UUID, roomId: UUID) async throws -> RoomPoll {
        try await json(path(roomId, "/polls/\(id(pollId))/votes"), body: PollVoteRequest(optionId: optionId),
                       as: RoomPoll.self)
    }

    public func closePoll(_ pollId: UUID, roomId: UUID) async throws -> RoomPoll {
        try await bare(path(roomId, "/polls/\(id(pollId))/close"), method: .post, as: RoomPoll.self)
    }

    public func messages(roomId: UUID) async throws -> [RoomMessage] {
        try await get(path(roomId, "/messages"), query: [URLQueryItem(name: "limit", value: "100")],
                       as: RoomMessagesEnvelope.self).messages
    }

    public func send(_ text: String, roomId: UUID) async throws -> RoomMessage {
        try await json(path(roomId, "/messages"), body: TextBody(text: text), as: RoomMessage.self)
    }

    public func hide(messageId: UUID, roomId: UUID) async throws {
        try await call(path(roomId, "/messages/\(id(messageId))/hide"), method: .post)
    }
}

public final class SafetyDepthService: SafetyDepthServiceProtocol {
    private let network: NetworkClient
    private let tokens: AccessTokenProviding

    public init(network: NetworkClient, tokens: AccessTokenProviding) {
        self.network = network
        self.tokens = tokens
    }

    public func mutedTerms() async throws -> [MutedTerm] {
        let token = try await tokens.accessToken()
        return try await network.send(APIRequest(path: "/me/muted-terms", accessToken: token), as: MutedTermsEnvelope.self).terms
    }

    public func muteTerm(_ term: String) async throws -> MutedTerm {
        let token = try await tokens.accessToken()
        return try await network.send(try APIRequest.json("/me/muted-terms", body: TermBody(term: term), accessToken: token),
                                      as: MutedTerm.self)
    }

    public func unmuteTerm(_ id: UUID) async throws {
        let token = try await tokens.accessToken()
        try await network.send(APIRequest(path: "/me/muted-terms/\(id.uuidString.lowercased())", method: .delete, accessToken: token))
    }

    public func guidelines() async throws -> Guidelines {
        try await network.send(APIRequest(path: "/guidelines"), as: Guidelines.self)
    }

    public func acceptGuidelines(version: String) async throws {
        let token = try await tokens.accessToken()
        try await network.send(try APIRequest.json("/me/guidelines/accept", body: AcceptGuidelinesBody(version: version),
                                                   accessToken: token))
    }
}
