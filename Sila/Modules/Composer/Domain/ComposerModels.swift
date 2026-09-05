import Foundation

// MARK: - Constants

/// Composer limits, all mirroring what the server enforces.
public enum ComposerConstants {

    /// Maximum characters in one post. The server answers `text_too_long` above it.
    public static let characterLimit = FeedConstants.maximumPostLength
    /// What the server accepts on one post; more are refused with
    /// `too_many_images` rather than silently dropped.
    public static let maximumImages = 4

    /// How many characters from the limit the counter starts warning.
    public static let warningThreshold = 20

    /// Segments a single thread may hold.
    ///
    /// There is no server-side thread object and therefore no server-side cap;
    /// this is a client guard against a user queueing thirty sequential writes
    /// behind one button press.
    public static let maximumThreadSegments = 10

    /// How long the composer waits after a keystroke before searching for
    /// mention candidates.
    public static let mentionDebounce: TimeInterval = 0.25
}

// MARK: - Draft

/// One post about to be written.
///
/// > Note: The Phase-4 spec's `PostDraft` carried `audienceType`, `scheduledAt`
/// > and media segments. The backend has no upload, poll or scheduling
/// > endpoint, and the product's audience concept is *scope*, not
/// > Everyone/Following/Circle — so this is the draft the API can actually
/// > accept, and nothing more.
public struct PostDraft: Equatable, Sendable {

    /// Body text. Trimmed before it is sent.
    public var text: String
    /// Who may reply. Ignored by the server for replies, which inherit.
    public var scope: ComposeScope
    /// Set when this post is a reply — including the second and later segments
    /// of a thread, which reply to the segment before them.
    public var replyToPostId: UUID?
    /// Set when this post quotes another.
    public var quotedPostId: UUID?
    /// Server paths from ``ComposerServiceProtocol/uploadImage(_:)``, at most
    /// four. Paths rather than bytes: the images are already uploaded by the
    /// time a draft is posted, which is what stops a failed picture from taking
    /// somebody's words down with it.
    public var imageURLs: [String]

    public init(
        text: String,
        scope: ComposeScope,
        replyToPostId: UUID? = nil,
        quotedPostId: UUID? = nil,
        imageURLs: [String] = []
    ) {
        self.text = text
        self.scope = scope
        self.replyToPostId = replyToPostId
        self.imageURLs = imageURLs
        self.quotedPostId = quotedPostId
    }

    /// The text as it goes over the wire.
    public var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `true` when there is something to post that is inside the limit.
    public var isPostable: Bool {
        ComposerTextMetrics.make(text).canPost
    }
}

/// The `POST /posts` request body.
///
/// `JSONCoding.encoder` converts these keys to `snake_case`, and the synthesised
/// encoder omits the `nil` optionals entirely rather than sending explicit
/// nulls — which is what the contract's optional fields expect.
struct CreatePostBody: Encodable, Equatable {
    let text: String
    let scope: String
    let scopeCountry: String?
    let scopeRegion: String?
    /// Lowercased UUID strings: `JSONEncoder` would otherwise emit the
    /// uppercase form, and the server's ids are lowercase everywhere else.
    let replyToPostId: String?
    let quotedPostId: String?
    /// Omitted entirely when there are none, rather than sent as `[]`. The
    /// server treats both the same, but a request body that states its empties
    /// is a body whose logs cannot be read at a glance.
    let imageUrls: [String]?

    init(draft: PostDraft) {
        self.text = draft.trimmedText
        self.scope = draft.scope.wireValue
        self.scopeCountry = draft.scope.scopeCountry
        self.scopeRegion = draft.scope.scopeRegion
        self.replyToPostId = draft.replyToPostId?.uuidString.lowercased()
        self.quotedPostId = draft.quotedPostId?.uuidString.lowercased()
        self.imageUrls = draft.imageURLs.isEmpty ? nil : draft.imageURLs
    }
}

// MARK: - Character counting

/// The state of the character counter for one segment.
///
/// A pure value so the ring, the Post button's enabled-ness and the tests all
/// read the same numbers.
///
/// Characters are counted as Swift `Character`s — grapheme clusters, i.e. what
/// the user sees. A family emoji is one character here and may be several to
/// the server's `len()`, so the client is occasionally *stricter* than the
/// backend. Erring that way costs a character; erring the other way would show
/// a green counter on a post the server rejects.
public struct ComposerTextMetrics: Equatable, Sendable {

    /// Characters typed.
    public let count: Int
    /// Characters left before the limit. Negative once over.
    public let remaining: Int
    /// `true` when the field holds nothing but whitespace.
    public let isEmpty: Bool
    /// `true` past ``ComposerConstants/characterLimit``.
    public let isOverLimit: Bool
    /// `true` inside the warning band, before the limit is breached.
    public let isNearLimit: Bool
    /// `true` when this segment could be sent as-is.
    public let canPost: Bool
    /// Fill fraction for the ring, clamped to `0...1`.
    public let progress: Double

    /// Measures a draft's text.
    /// - Parameter text: Raw contents of the editor, untrimmed.
    public static func make(_ text: String) -> ComposerTextMetrics {
        let limit = ComposerConstants.characterLimit
        let count = text.count
        let remaining = limit - count
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let isOver = count > limit
        return ComposerTextMetrics(
            count: count,
            remaining: remaining,
            isEmpty: trimmed.isEmpty,
            isOverLimit: isOver,
            isNearLimit: !isOver && remaining <= ComposerConstants.warningThreshold,
            canPost: !trimmed.isEmpty && !isOver,
            progress: min(max(Double(count) / Double(limit), 0), 1)
        )
    }

    /// What the counter shows: only the remaining count, and only once it
    /// matters. A permanent "280" is noise.
    public var counterText: String? {
        guard isNearLimit || isOverLimit else { return nil }
        // A budget, not a quantity of anything: it reads left-to-right in both
        // languages, which is why the view pins its direction.
        return SLFormat.number(remaining)
    }

    /// What VoiceOver reads for the counter.
    public var accessibilityValue: String {
        if isOverLimit {
            return L10n.t(
                "composer.counter.a11yOver",
                L10n.plural("composer.counter.a11yOverCount", -remaining),
                SLFormat.number(ComposerConstants.characterLimit)
            )
        }
        return L10n.plural("composer.counter.a11yRemaining", remaining)
    }
}

// MARK: - Mention autocomplete

/// Finds and replaces the `@mention` the user is currently typing.
///
/// > Note: SwiftUI's `TextEditor` exposes no selection on iOS 17, so the active
/// > mention is the one the text *ends* with. Typing a mention into the middle
/// > of an existing sentence still posts fine — it just does not raise the
/// > suggestion list. That limitation is honest and contained here; nothing
/// > else in the composer assumes a cursor exists.
public enum MentionDetector {

    /// Shortest prefix worth sending to `/search/users`, matching the contract's
    /// own floor — below it the server returns an empty list anyway.
    public static let minimumQueryLength = 2

    /// The handle prefix being typed, if the text ends inside a mention.
    /// - Parameter text: The editor's contents.
    /// - Returns: The characters after the `@` (possibly empty), or `nil` when
    ///   the caret is not inside a mention.
    public static func activeQuery(in text: String) -> String? {
        guard let sigil = text.lastIndex(of: "@") else { return nil }

        // A mention only starts at a word boundary, so an email address never
        // opens the suggestion list.
        if sigil != text.startIndex {
            let previous = text[text.index(before: sigil)]
            guard previous.isWhitespace || previous.isNewline else { return nil }
        }

        let body = text[text.index(after: sigil)...]
        guard body.allSatisfy(isHandleCharacter) else { return nil }
        return String(body)
    }

    /// Replaces the mention being typed with a chosen handle, plus a trailing
    /// space so the user can keep writing.
    /// - Parameters:
    ///   - handle: The chosen handle, with or without a leading `@`.
    ///   - text: The editor's current contents.
    /// - Returns: The new contents. Unchanged when no mention is in progress.
    public static func inserting(handle: String, into text: String) -> String {
        guard activeQuery(in: text) != nil, let sigil = text.lastIndex(of: "@") else { return text }
        let clean = handle.hasPrefix("@") ? String(handle.dropFirst()) : handle
        return String(text[text.startIndex..<sigil]) + "@" + clean + " "
    }

    /// `true` when a prefix is long enough to search for.
    public static func isSearchable(_ query: String?) -> Bool {
        guard let query else { return false }
        return query.count >= minimumQueryLength
    }

    private static func isHandleCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }
}

// MARK: - Thread result

/// What happened when a thread was posted.
///
/// Threads are a client-side loop over `POST /posts` — there is no thread object
/// on the server — so a failure halfway leaves real posts behind. This type
/// exists so that fact reaches the user instead of being smoothed over: the
/// composer says "posted 2 of 5" and keeps the rest of the text.
public struct ThreadPostReport: Sendable, Equatable {

    /// The segments that were accepted, in order.
    public let posted: [Post]
    /// The segments that never left the device, in order.
    public let remaining: [String]
    /// Why the run stopped, when it did.
    public let error: APIError?

    public init(posted: [Post], remaining: [String] = [], error: APIError? = nil) {
        self.posted = posted
        self.remaining = remaining
        self.error = error
    }

    /// How many segments were attempted in total.
    public var totalSegments: Int { posted.count + remaining.count }

    /// `true` when every segment made it.
    public var isCompleteSuccess: Bool { error == nil && remaining.isEmpty }

    /// `true` when some posts exist and some do not — the case that must never
    /// be reported as a plain failure, because the earlier posts are live.
    public var isPartialFailure: Bool { !posted.isEmpty && error != nil }

    /// The id later segments must reply to when the user retries.
    public var continuationId: UUID? { posted.last?.id }

    /// The sentence shown to the user. `nil` on a clean single-post success,
    /// where the composer simply closes.
    public var summary: String? {
        guard let error else {
            return posted.count > 1 ? L10n.plural("composer.thread.posted", posted.count) : nil
        }
        guard !posted.isEmpty else { return error.userMessage }
        return L10n.t(
            "composer.thread.partialSummary",
            SLFormat.number(posted.count),
            SLFormat.number(totalSegments),
            error.userMessage
        )
    }
}
