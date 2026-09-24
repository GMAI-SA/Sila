import Foundation
import Observation

/// A room's questions, polls and co-hosts (contract v22). Owned by the room
/// screen alongside the room itself; refreshed when the room's data channel
/// says something changed (`questions_changed`, `polls_changed`,
/// `cohosts_changed`).
@MainActor
@Observable
public final class RoomDepthViewModel {

    public private(set) var questions: [RoomQuestion] = []
    public private(set) var answered: [RoomQuestion] = []
    public private(set) var polls: [RoomPoll] = []
    public private(set) var cohosts: [UserSummary]
    public var askDraft = ""
    public private(set) var isAsking = false
    public var toast: SLToastMessage?

    public let roomId: UUID
    /// Host or co-host: runs the queue and the polls.
    public private(set) var isStage: Bool
    /// Only the host adds or removes co-hosts.
    public let isHost: Bool
    private let service: RoomDepthServiceProtocol
    private let analytics: AnalyticsClient

    public static let maxQuestionLength = 280
    public static let maxCohosts = 3

    public init(roomId: UUID, isHost: Bool, isStage: Bool, cohosts: [UserSummary],
                service: RoomDepthServiceProtocol, analytics: AnalyticsClient) {
        self.roomId = roomId
        self.isHost = isHost
        self.isStage = isStage
        self.cohosts = cohosts
        self.service = service
        self.analytics = analytics
    }

    public var pinned: RoomQuestion? { questions.first { $0.pinned } }
    public var openPoll: RoomPoll? { polls.first { !$0.poll.isClosed() } }

    public var canAsk: Bool {
        let text = askDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.count >= 2 && text.count <= Self.maxQuestionLength && !isAsking
    }

    public func load() async {
        async let q: Void = loadQuestions()
        async let p: Void = loadPolls()
        _ = await (q, p)
    }

    public func loadQuestions() async {
        if let open = try? await service.questions(roomId: roomId, status: .open) { questions = open }
        if let done = try? await service.questions(roomId: roomId, status: .answered) { answered = done }
    }

    public func loadPolls() async {
        if let list = try? await service.polls(roomId: roomId) { polls = list }
    }

    /// A data-channel event from the room.
    public func handle(event type: String, cohosts updated: [UserSummary]? = nil) async {
        switch type {
        case "questions_changed": await loadQuestions()
        case "polls_changed": await loadPolls()
        case "cohosts_changed": if let updated { cohosts = updated }
        default: break
        }
    }

    public func setStage(_ value: Bool) { isStage = value }
    public func setCohosts(_ value: [UserSummary]) { cohosts = value }

    // MARK: Questions

    public func ask() async {
        guard canAsk else { return }
        let text = askDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        isAsking = true
        defer { isAsking = false }
        do {
            let question = try await service.ask(text, roomId: roomId)
            askDraft = ""
            if !questions.contains(where: { $0.id == question.id }) { questions.append(question) }
            analytics.track(.roomQuestionAsked)
        } catch {
            toast = .error(for: error)
        }
    }

    public func toggleUpvote(_ question: RoomQuestion) async {
        guard !question.isAuthor else { return }
        do {
            try await service.setUpvote(!question.viewerUpvoted, questionId: question.id, roomId: roomId)
            await loadQuestions()
        } catch { toast = .error(for: error) }
    }

    /// `pin | unpin | answer | dismiss | reopen`.
    public func stage(_ action: String, _ question: RoomQuestion) async {
        guard isStage else { return }
        do {
            try await service.stage(action, questionId: question.id, roomId: roomId)
            await loadQuestions()
        } catch { toast = .error(for: error) }
    }

    public func withdraw(_ question: RoomQuestion) async {
        guard question.isAuthor else { return }
        do {
            try await service.withdraw(questionId: question.id, roomId: roomId)
            questions.removeAll { $0.id == question.id }
        } catch { toast = .error(for: error) }
    }

    // MARK: Polls

    public func openPoll(question: String, options: [String], durationSeconds: Int) async -> Bool {
        guard isStage else { return false }
        let cleaned = options.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, (2...4).contains(cleaned.count) else {
            toast = .warning(L10n.t("poll.error.count"))
            return false
        }
        do {
            let poll = try await service.openPoll(question: question, options: cleaned,
                                                  durationSeconds: min(max(durationSeconds, 60), 1_800), roomId: roomId)
            polls.removeAll { $0.id == poll.id }
            polls.insert(poll, at: 0)
            return true
        } catch {
            toast = .error(for: error)
            return false
        }
    }

    public func vote(_ option: PollOption, in poll: RoomPoll) async {
        do {
            let updated = try await service.vote(optionId: option.id, pollId: poll.id, roomId: roomId)
            replace(updated)
        } catch { toast = .error(for: error) }
    }

    public func close(_ poll: RoomPoll) async {
        guard isStage else { return }
        do { replace(try await service.closePoll(poll.id, roomId: roomId)) } catch { toast = .error(for: error) }
    }

    private func replace(_ poll: RoomPoll) {
        if let i = polls.firstIndex(where: { $0.id == poll.id }) { polls[i] = poll } else { polls.insert(poll, at: 0) }
    }

    // MARK: Co-hosts

    public func addCohost(_ handle: String) async {
        guard isHost, cohosts.count < Self.maxCohosts else { return }
        do { cohosts = try await service.addCohost(handle, roomId: roomId) } catch { toast = .error(for: error) }
    }

    public func removeCohost(_ handle: String) async {
        do { cohosts = try await service.removeCohost(handle, roomId: roomId) } catch { toast = .error(for: error) }
    }

    public func isCohost(_ user: UserSummary) -> Bool { cohosts.contains { $0.id == user.id } }
}

/// The guidelines, and whether this account has accepted the current version.
@MainActor
@Observable
public final class GuidelinesGate {
    public private(set) var guidelines: Guidelines?
    public private(set) var acceptedVersion: String?
    public private(set) var currentVersion: String?
    public private(set) var isLoading = false
    public private(set) var error: String?
    private let service: SafetyDepthServiceProtocol

    public init(service: SafetyDepthServiceProtocol, acceptedVersion: String? = nil, currentVersion: String? = nil) {
        self.service = service
        self.acceptedVersion = acceptedVersion
        self.currentVersion = currentVersion
    }

    /// The server says there is a version this account has not accepted.
    public var needsAcceptance: Bool {
        guard let currentVersion, !currentVersion.isEmpty else { return false }
        return acceptedVersion != currentVersion
    }

    public func update(accepted: String?, current: String?) {
        acceptedVersion = accepted
        currentVersion = current
    }

    public func load() async {
        guard guidelines == nil, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let loaded = try await service.guidelines()
            guidelines = loaded
            if currentVersion == nil { currentVersion = loaded.version }
        } catch {
            self.error = APIError.wrapping(error).presentableMessage
        }
    }

    /// Accepts what is on screen.
    public func accept() async -> Bool {
        guard let version = guidelines?.version ?? currentVersion else { return false }
        do {
            try await service.acceptGuidelines(version: version)
            acceptedVersion = version
            currentVersion = version
            return true
        } catch {
            self.error = APIError.wrapping(error).presentableMessage
            return false
        }
    }
}

@MainActor
@Observable
public final class MutedTermsViewModel {
    public private(set) var terms: [MutedTerm] = []
    public var draft = ""
    public private(set) var isLoading = false
    public var toast: SLToastMessage?
    private let service: SafetyDepthServiceProtocol

    public init(service: SafetyDepthServiceProtocol) {
        self.service = service
    }

    public var canAdd: Bool {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.count >= 2 && text.count <= 60
    }

    public func load() async {
        isLoading = true
        defer { isLoading = false }
        do { terms = try await service.mutedTerms() } catch { toast = .error(for: error) }
    }

    public func add() async {
        guard canAdd else { return }
        do {
            let term = try await service.muteTerm(draft.trimmingCharacters(in: .whitespacesAndNewlines))
            terms.append(term)
            draft = ""
        } catch { toast = .error(for: error) }
    }

    public func remove(_ term: MutedTerm) async {
        do {
            try await service.unmuteTerm(term.id)
            terms.removeAll { $0.id == term.id }
        } catch { toast = .error(for: error) }
    }
}
