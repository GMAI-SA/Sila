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
    /// A vouched listener reads the questions and polls but cannot ask,
    /// upvote or vote (contract v24 §4): each waits for their own
    /// verification, and the panel says so where the field would be.
    public let viewerIsVouched: Bool
    private let service: RoomDepthServiceProtocol
    private let analytics: AnalyticsClient

    public static let maxQuestionLength = 280
    public static let maxCohosts = 3

    public init(roomId: UUID, isHost: Bool, isStage: Bool, cohosts: [UserSummary],
                service: RoomDepthServiceProtocol, analytics: AnalyticsClient, viewerIsVouched: Bool = false) {
        self.viewerIsVouched = viewerIsVouched
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
        return !viewerIsVouched && text.count >= 2 && text.count <= Self.maxQuestionLength && !isAsking
    }

    /// Whether this viewer may push a question up the queue or vote in a
    /// room poll.
    public var canTakePart: Bool { !viewerIsVouched }

    // MARK: Feedback

    /// Bumped when something this person did landed (a question in the
    /// queue, a vote counted). The screen turns each bump into a haptic.
    public private(set) var successBeats = 0
    /// Bumped when it did not.
    public private(set) var failureBeats = 0
    /// Bumped the moment a vote is tapped, before the server answers.
    public private(set) var selectionBeats = 0

    public func load() async {
        async let q: Void = loadQuestions()
        async let p: Void = loadPolls()
        _ = await (q, p)
    }

    public func loadQuestions() async {
        if let open = try? await service.questions(roomId: roomId, status: .open) {
            questions = open
            settlePending(against: open)
        }
        if let done = try? await service.questions(roomId: roomId, status: .answered) { answered = done }
    }

    public func loadPolls() async {
        if let list = try? await service.polls(roomId: roomId) { adopt(polls: list) }
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

    // MARK: Live tally

    private var tallyTask: Task<Void, Never>?
    /// Seconds between tally reads while a poll is open.
    public static let tallyInterval: TimeInterval = 4

    /// Re-reads the polls every few seconds while one is open, so the bars
    /// move as the room votes even when the room's data message is late or
    /// lost (the message is a nudge; the database is the truth). Between
    /// polls it looks less often. ``stopLiveTally()`` ends it.
    public func startLiveTally(interval: TimeInterval = RoomDepthViewModel.tallyInterval) {
        guard tallyTask == nil, interval > 0 else { return }
        tallyTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                tick += 1
                // Every tick while a poll runs; every third otherwise, so a
                // poll the stage opens turns up even without the nudge.
                if self.openPoll != nil || tick % 3 == 0 { await self.loadPolls() }
            }
        }
    }

    public func stopLiveTally() {
        tallyTask?.cancel()
        tallyTask = nil
    }

    // MARK: Questions

    /// A question on its way to the queue: on screen the moment Send is
    /// tapped, "Sending…" until the server has it, and "Not sent · Retry"
    /// if it did not get there.
    public struct PendingQuestion: Identifiable, Equatable, Sendable {
        public enum State: Equatable, Sendable { case sending, failed(String) }
        public let id: UUID
        public let text: String
        public var state: State
    }

    /// The viewer's own questions that the queue does not show yet.
    public private(set) var pendingQuestions: [PendingQuestion] = []

    public func ask() async {
        guard canAsk else { return }
        let text = askDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        // A second tap on the same words while the first is in flight.
        guard !pendingQuestions.contains(where: { $0.text == text && $0.state == .sending }) else { return }
        askDraft = ""
        let pending = PendingQuestion(id: UUID(), text: text, state: .sending)
        pendingQuestions.append(pending)
        await send(pending.id)
    }

    /// Sends a question that did not get through, again — unless the queue
    /// shows it arrived after all (a timeout after the server had it).
    public func retry(_ pending: PendingQuestion) async {
        guard let i = pendingQuestions.firstIndex(where: { $0.id == pending.id }),
              pendingQuestions[i].state != .sending else { return }
        pendingQuestions[i].state = .sending
        await loadQuestions()
        guard pendingQuestions.contains(where: { $0.id == pending.id }) else {
            successBeats += 1
            return
        }
        await send(pending.id)
    }

    /// Gives up on a question that did not get through.
    public func discard(_ pending: PendingQuestion) {
        pendingQuestions.removeAll { $0.id == pending.id }
    }

    private func send(_ pendingId: UUID) async {
        guard let pending = pendingQuestions.first(where: { $0.id == pendingId }) else { return }
        isAsking = true
        defer { isAsking = false }
        do {
            let queue = try await service.ask(pending.text, roomId: roomId)
            pendingQuestions.removeAll { $0.id == pendingId }
            adopt(queue: queue)
            analytics.track(.roomQuestionAsked)
            successBeats += 1
        } catch {
            let wrapped = APIError.wrapping(error)
            guard let i = pendingQuestions.firstIndex(where: { $0.id == pendingId }) else { return }
            if wrapped.isCancellation {
                pendingQuestions[i].state = .failed(L10n.t("rooms.questions.notSent"))
                return
            }
            pendingQuestions[i].state = .failed(wrapped.userMessage)
            failureBeats += 1
        }
    }

    /// The queue a write answered with: open and answered together.
    private func adopt(queue: [RoomQuestion]) {
        guard !queue.isEmpty else { return }
        questions = queue.filter { $0.status == .open }
        answered = queue.filter { $0.status == .answered }
        settlePending(against: questions)
    }

    /// A pending question the queue already holds — the server had it, and
    /// only the answer was lost — is no longer pending.
    private func settlePending(against open: [RoomQuestion]) {
        guard !pendingQuestions.isEmpty else { return }
        pendingQuestions.removeAll { pending in
            open.contains { $0.isAuthor && $0.text == pending.text }
        }
    }

    public func toggleUpvote(_ question: RoomQuestion) async {
        guard !question.isAuthor, canTakePart else { return }
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

    /// `true` while a poll is being opened: the button waits, and a second
    /// tap cannot open a second poll (or earn a "close the running poll"
    /// refusal for the first).
    public private(set) var isOpeningPoll = false
    /// The option this viewer just tapped, per poll, while the vote is in
    /// flight: drawn as chosen at once.
    public private(set) var pendingVotes: [UUID: UUID] = [:]

    /// The option this viewer chose in a poll — the server's word, or the
    /// tap still on its way.
    public func chosenOption(in poll: RoomPoll) -> UUID? {
        poll.poll.viewerOptionId ?? pendingVotes[poll.id]
    }

    public func openPoll(question: String, options: [String], durationSeconds: Int) async -> Bool {
        guard isStage, !isOpeningPoll else { return false }
        let cleaned = options.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let asked = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !asked.isEmpty, (2...4).contains(cleaned.count) else {
            toast = .warning(L10n.t("poll.error.count"))
            return false
        }
        isOpeningPoll = true
        defer { isOpeningPoll = false }
        do {
            let list = try await service.openPoll(question: asked, options: cleaned,
                                                  durationSeconds: min(max(durationSeconds, 60), 1_800), roomId: roomId)
            adopt(polls: list)
            if openPoll == nil { await loadPolls() }
            successBeats += 1
            return true
        } catch {
            let wrapped = APIError.wrapping(error)
            if wrapped.isCancellation { return false }
            // The answer may be lost while the poll went in — a timeout, a
            // dropped connection — or a running poll may already be the
            // one this person meant. The room's polls say which.
            await loadPolls()
            let landed = openPoll.map { $0.question == asked } ?? false
            if landed || (wrapped.code == .pollOpen && openPoll != nil) {
                successBeats += 1
                return true
            }
            toast = .error(wrapped.userMessage)
            failureBeats += 1
            return false
        }
    }

    public func vote(_ option: PollOption, in poll: RoomPoll) async {
        guard canTakePart, poll.poll.canVote, !poll.poll.isClosed(),
              chosenOption(in: poll) == nil else { return }
        pendingVotes[poll.id] = option.id
        selectionBeats += 1
        do {
            let list = try await service.vote(optionId: option.id, pollId: poll.id, roomId: roomId)
            adopt(polls: list)
            pendingVotes[poll.id] = nil
            successBeats += 1
        } catch {
            let wrapped = APIError.wrapping(error)
            pendingVotes[poll.id] = nil
            await loadPolls()
            // Counted after all (the answer was lost), or counted before:
            // nothing to tell anybody.
            if let fresh = polls.first(where: { $0.id == poll.id }), fresh.poll.viewerOptionId != nil {
                successBeats += 1
                return
            }
            if wrapped.isCancellation { return }
            toast = .error(wrapped.userMessage)
            failureBeats += 1
        }
    }

    public func close(_ poll: RoomPoll) async {
        guard isStage else { return }
        do { adopt(polls: try await service.closePoll(poll.id, roomId: roomId)) } catch {
            await loadPolls()
            if polls.first(where: { $0.id == poll.id })?.poll.isClosed() == true { return }
            toast = .error(for: error)
        }
    }

    /// The room's polls as a read or a write returned them, newest first.
    private func adopt(polls list: [RoomPoll]) {
        guard !list.isEmpty || polls.isEmpty else {
            // An empty answer to a write is not "every poll is gone".
            return
        }
        polls = list
        for (pollId, _) in pendingVotes where list.first(where: { $0.id == pollId })?.poll.viewerOptionId != nil {
            pendingVotes[pollId] = nil
        }
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
