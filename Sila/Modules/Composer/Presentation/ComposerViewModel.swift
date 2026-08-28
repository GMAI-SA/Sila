import Foundation
import Observation

/// Drives ``ComposerSheetScreen``, ``ReplyComposerBar`` and the quote composer.
///
/// One view model serves all three because they differ only by
/// ``ComposerContext``: a reply has no scope picker and no thread, a quote
/// renders a card beneath the editor, and a root post gets both.
///
/// The one piece of real logic here is thread posting, which is a **sequential
/// chain of self-replies** — there is no thread object on the server. A failure
/// halfway leaves live posts behind, so the failure path keeps the unsent
/// segments, remembers where to continue from, and tells the user exactly how
/// many made it.
@MainActor
@Observable
public final class ComposerViewModel {

    /// One post in the thread being written.
    public struct Segment: Identifiable, Equatable, Sendable {
        public let id: UUID
        public var text: String

        public init(id: UUID = UUID(), text: String = "") {
            self.id = id
            self.text = text
        }
    }

    // MARK: Published state

    /// Why the composer is open.
    ///
    /// A `var` only so a reply bar can adopt a *refreshed* parent — the detail
    /// screen re-reads the post it is showing, and `viewer.can_reply` is
    /// computed per request.
    public private(set) var context: ComposerContext
    /// Who is writing — the source of truth for which scopes are offered.
    public let author: ComposerAuthor

    /// The thread's segments. Always at least one.
    public private(set) var segments: [Segment]
    /// Index of the segment the editor is focused on.
    public var focusedIndex: Int = 0
    /// The audience for the root post.
    public private(set) var scope: ComposeScope
    /// Every row of the scope picker, available or not.
    public let scopeOptions: [ScopeOption]
    /// `true` while a post (or a thread) is in flight.
    public private(set) var isPosting = false
    /// Mention candidates for the segment being typed.
    public private(set) var mentionSuggestions: [UserSummary] = []
    /// `true` while `/search/users` is in flight for the current prefix.
    public private(set) var isSearchingMentions = false
    /// Set after a partial thread failure: what got posted, and what did not.
    public private(set) var partialFailureMessage: String?
    /// Banner message.
    public var toast: SLToastMessage?
    /// `true` when the discard confirmation should be shown instead of closing.
    public private(set) var isConfirmingDiscard = false

    // MARK: Collaborators

    private let composer: ComposerServiceProtocol
    private let search: SearchServiceProtocol?
    private let analytics: AnalyticsClient
    private let mentionDebounce: TimeInterval
    private let onPosted: @MainActor ([Post]) -> Void
    private let onClose: @MainActor () -> Void

    /// Where a retry continues the chain, after a partial failure.
    private var continuationId: UUID?
    /// The in-flight mention search, cancelled by the next keystroke.
    private var mentionTask: Task<Void, Never>?

    /// - Parameters:
    ///   - context: Root post, reply or quote.
    ///   - author: The signed-in account, for the scope picker.
    ///   - composer: Post backend.
    ///   - search: Backs `@mention` autocomplete. `nil` disables the suggestion
    ///     list without disabling the composer.
    ///   - analytics: Event sink.
    ///   - mentionDebounce: Seconds to wait after a keystroke. Tests pass a
    ///     tiny value; the default matches ``ComposerConstants/mentionDebounce``.
    ///   - onPosted: Called with everything that reached the server — including
    ///     after a *partial* failure, so the feed shows the posts that exist.
    ///   - onClose: Dismisses the sheet.
    public init(
        context: ComposerContext,
        author: ComposerAuthor,
        composer: ComposerServiceProtocol,
        search: SearchServiceProtocol? = nil,
        analytics: AnalyticsClient,
        mentionDebounce: TimeInterval = ComposerConstants.mentionDebounce,
        onPosted: @escaping @MainActor ([Post]) -> Void = { _ in },
        onClose: @escaping @MainActor () -> Void = {}
    ) {
        self.context = context
        self.author = author
        self.composer = composer
        self.search = search
        self.analytics = analytics
        self.mentionDebounce = mentionDebounce
        self.onPosted = onPosted
        self.onClose = onClose
        self.segments = [Segment()]
        self.scopeOptions = ScopePicker.options(for: author)

        // A reply inherits its parent's audience; anything else starts at the
        // widest scope the author is definitely allowed to use.
        if let parent = context.replyTarget {
            self.scope = ComposeScope.inherited(from: parent)
        } else {
            self.scope = ScopePicker.defaultScope(for: author)
        }
    }

    // MARK: - Derived state

    /// Whether the thread affordance is offered. Replies stay single.
    public var allowsThread: Bool {
        context.replyTarget == nil && segments.count < ComposerConstants.maximumThreadSegments
    }

    /// Character counting for the focused segment.
    public var metrics: ComposerTextMetrics {
        ComposerTextMetrics.make(text(at: focusedIndex))
    }

    /// Counting for any segment.
    public func metrics(at index: Int) -> ComposerTextMetrics {
        ComposerTextMetrics.make(text(at: index))
    }

    /// `true` when there is anything the user would be upset to lose.
    public var hasContent: Bool {
        segments.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// `true` when the Post button should be live.
    ///
    /// Every non-empty segment must be inside the limit, at least one segment
    /// must have content, and — for a reply — the server must have said the
    /// viewer may reply at all.
    public var canPost: Bool {
        guard !isPosting, canReplyHere else { return false }
        let filled = segments.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !filled.isEmpty else { return false }
        return filled.allSatisfy { ComposerTextMetrics.make($0.text).canPost }
    }

    /// Whether the viewer is allowed to reply into this thread at all.
    ///
    /// `viewer.can_reply` is computed server-side per request; the composer
    /// never renders an input the server would reject.
    public var canReplyHere: Bool {
        guard let parent = context.replyTarget else { return true }
        return ReplyPermission.make(for: parent).canReply
    }

    /// The sentence to show instead of an input, when the viewer may not reply.
    public var replyBlockedMessage: String? {
        guard let parent = context.replyTarget else { return nil }
        return ReplyPermission.make(for: parent).blockedMessage
    }

    /// A one-line summary of the chosen audience, for the picker's collapsed row.
    public var scopeSummary: ScopeOption {
        scopeOptions.first { $0.scope == scope }
            ?? ScopeOption(
                scope: scope,
                title: "International",
                subtitle: "Any verified account, anywhere, can reply.",
                icon: "globe",
                isAvailable: true
            )
    }

    // MARK: - Text editing

    /// The text of a segment. Out-of-range indices read as empty rather than trapping.
    public func text(at index: Int) -> String {
        segments.indices.contains(index) ? segments[index].text : ""
    }

    /// Writes a segment's text and re-evaluates `@mention` autocomplete.
    /// - Parameters:
    ///   - text: New contents.
    ///   - index: Which segment.
    public func setText(_ text: String, at index: Int) {
        guard segments.indices.contains(index) else { return }
        segments[index].text = text
        focusedIndex = index
        scheduleMentionSearch(for: text)
    }

    /// Adds an empty segment after the last one and focuses it.
    public func addSegment() {
        guard allowsThread else { return }
        segments.append(Segment())
        focusedIndex = segments.count - 1
        clearMentionSuggestions()
        analytics.track(.composerSegmentAdded, properties: ["count": String(segments.count)])
    }

    /// Removes a segment. The composer always keeps at least one.
    public func removeSegment(at index: Int) {
        guard segments.count > 1, segments.indices.contains(index) else { return }
        segments.remove(at: index)
        focusedIndex = min(focusedIndex, segments.count - 1)
        clearMentionSuggestions()
    }

    // MARK: - Reply target

    /// Adopts a re-read copy of the post being replied to.
    ///
    /// Keeps the typed text: only the permission and the inherited scope move.
    /// Ignores anything that is not the same post, so a stray call cannot
    /// redirect a half-written reply at someone else's thread.
    /// - Parameter post: The refreshed parent.
    public func updateReplyTarget(_ post: Post) {
        guard let current = context.replyTarget, current.id == post.id else { return }
        context = .reply(to: post)
        scope = ComposeScope.inherited(from: post)
    }

    // MARK: - Scope

    /// Selects an audience.
    ///
    /// An unavailable option is refused *with its reason*, rather than silently
    /// ignored — a tap that does nothing reads as a broken control.
    /// - Parameter option: The row the user tapped.
    public func select(_ option: ScopeOption) {
        guard option.isAvailable else {
            if let reason = option.unavailableReason {
                toast = .info(reason)
            }
            return
        }
        scope = option.scope
        analytics.track(.composerScopeSelected, properties: ["scope": option.scope.wireValue])
    }

    // MARK: - Mentions

    /// Debounces a `/search/users` call for the mention being typed.
    ///
    /// Every keystroke cancels the previous task, so a fast typist produces one
    /// request rather than one per character.
    private func scheduleMentionSearch(for text: String) {
        mentionTask?.cancel()

        let query = MentionDetector.activeQuery(in: text)
        guard let search, MentionDetector.isSearchable(query), let query else {
            clearMentionSuggestions()
            return
        }

        isSearchingMentions = true
        // The task inherits the main actor, so the assignments below need no hop.
        mentionTask = Task { [weak self, mentionDebounce] in
            if mentionDebounce > 0 {
                try? await Task.sleep(nanoseconds: UInt64(mentionDebounce * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }

            let users = (try? await search.searchUsers(query: query)) ?? []

            guard !Task.isCancelled, let self else { return }
            self.mentionSuggestions = users
            self.isSearchingMentions = false
        }
    }

    /// Replaces the mention in progress with a chosen handle.
    /// - Parameter user: The account the user tapped.
    public func insertMention(_ user: UserSummary) {
        let index = focusedIndex
        guard segments.indices.contains(index) else { return }
        segments[index].text = MentionDetector.inserting(handle: user.handle, into: segments[index].text)
        clearMentionSuggestions()
        analytics.track(.composerMentionInserted)
    }

    private func clearMentionSuggestions() {
        mentionTask?.cancel()
        mentionTask = nil
        mentionSuggestions = []
        isSearchingMentions = false
    }

    // MARK: - Posting

    /// Posts the thread, one segment at a time.
    ///
    /// On a partial failure the posted segments are dropped from the editor,
    /// the rest stay, and the next attempt continues the chain from the last
    /// post that succeeded — the user is never asked to retype what is already
    /// public, and never silently duplicates it either.
    public func post() async {
        guard canPost else { return }
        isPosting = true
        partialFailureMessage = nil
        defer { isPosting = false }

        let texts = segments
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        // A retry after a partial failure continues from the last live post;
        // otherwise the parent is whatever opened the composer.
        let parentId = continuationId ?? context.replyTarget?.id

        let report = await composer.createThread(
            segments: texts,
            scope: scope,
            replyToPostId: parentId,
            // Only a fresh thread carries the quote — a continuation's opening
            // segment is a reply, and quoting again would duplicate the card.
            quotedPostId: continuationId == nil ? context.quotedPost?.id : nil
        )

        if !report.posted.isEmpty {
            onPosted(report.posted)
            analytics.track(.postPublished, properties: [
                "scope": scope.wireValue,
                "segments": String(report.posted.count),
                "kind": analyticsKind
            ])
        }

        if report.isCompleteSuccess {
            onClose()
            return
        }

        if report.isPartialFailure {
            // The earlier posts are live. Keep only what did not make it.
            segments = report.remaining.map { Segment(text: $0) }
            focusedIndex = 0
            continuationId = report.continuationId
            partialFailureMessage = report.summary
            toast = .warning(report.summary ?? "Part of your thread was posted.")
            analytics.track(.postPartiallyFailed, properties: [
                "posted": String(report.posted.count),
                "total": String(report.totalSegments)
            ])
        } else if let error = report.error {
            toast = .error(message(for: error))
            analytics.track(.postFailed, properties: ["code": error.code?.rawValue ?? "transport"])
        }
    }

    // MARK: - Dismissal

    /// Called by Cancel. Asks for confirmation only when there is something to lose.
    public func requestDismiss() {
        if hasContent {
            isConfirmingDiscard = true
        } else {
            onClose()
        }
    }

    /// Confirms the discard.
    public func confirmDiscard() {
        isConfirmingDiscard = false
        analytics.track(.composerDiscarded)
        onClose()
    }

    /// Backs out of the discard confirmation.
    public func cancelDiscard() {
        isConfirmingDiscard = false
    }

    // MARK: - Helpers

    private var analyticsKind: String {
        if context.replyTarget != nil { return "reply" }
        if context.quotedPost != nil { return "quote" }
        return segments.count > 1 ? "thread" : "post"
    }

    /// User-facing copy for a failure, with composer-specific wording for the
    /// two codes the generic mapping cannot phrase well here.
    private func message(for error: APIError) -> String {
        switch error.code {
        case .unverified:
            return "Only verified humans can post. Everyone can read Sila — finish identity verification to speak."
        case .invalidScope:
            return "That audience isn't available for this post. Pick another and try again."
        default:
            return error.userMessage
        }
    }
}
