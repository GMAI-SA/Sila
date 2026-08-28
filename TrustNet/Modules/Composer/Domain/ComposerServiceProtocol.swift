import Foundation

/// Everything the Composer module can ask the backend to do.
///
/// > Note: The Phase-4 spec listed `uploadMedia`, `schedulePost`,
/// > `fetchScheduledPosts` and `cancelScheduledPost`. Contract v3 has no upload,
/// > poll or scheduling endpoint, so those requirements are deliberately absent
/// > rather than declared and stubbed — a protocol requirement no
/// > implementation can honour is a lie the compiler cannot catch.
public protocol ComposerServiceProtocol: Sendable {

    /// Creates one post.
    /// - Parameter draft: Text, scope, and the optional reply/quote targets.
    /// - Returns: The created ``Post`` exactly as the server stored it.
    /// - Throws: ``APIError`` with ``APIErrorCode/unverified`` (403) for an
    ///   account that may read but not speak, ``APIErrorCode/replyNotAllowed``
    ///   (403) when the scope excludes the author, or
    ///   ``APIErrorCode/textTooLong`` / ``APIErrorCode/invalidScope`` (400).
    func createPost(_ draft: PostDraft) async throws -> Post
}

extension ComposerServiceProtocol {

    /// Posts a thread by chaining self-replies, stopping at the first failure.
    ///
    /// There is no thread object on the server: segment 1 is an ordinary post
    /// and every later segment is a reply to the one before it. That means a
    /// failure partway through **cannot be rolled back** — the earlier posts are
    /// already public. The returned ``ThreadPostReport`` therefore names exactly
    /// what got through, and the caller is expected to say so out loud.
    ///
    /// - Parameters:
    ///   - segments: Body text per segment, in order. Empty segments are dropped.
    ///   - scope: Audience for the root. Later segments inherit it server-side.
    ///   - replyToPostId: Set when the whole thread is itself a reply.
    ///   - quotedPostId: Applied to the **first** segment only — a thread quotes
    ///     one post, not the same post five times.
    /// - Returns: What was posted, what was not, and why it stopped.
    public func createThread(
        segments: [String],
        scope: ComposeScope,
        replyToPostId: UUID? = nil,
        quotedPostId: UUID? = nil
    ) async -> ThreadPostReport {
        var queue = segments
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var posted: [Post] = []
        var parentId = replyToPostId

        while !queue.isEmpty {
            let text = queue.removeFirst()
            let draft = PostDraft(
                text: text,
                scope: scope,
                replyToPostId: parentId,
                // Only the opening segment carries the quote.
                quotedPostId: posted.isEmpty ? quotedPostId : nil
            )
            do {
                let post = try await createPost(draft)
                posted.append(post)
                parentId = post.id
            } catch {
                return ThreadPostReport(
                    posted: posted,
                    remaining: [text] + queue,
                    error: APIError.wrapping(error)
                )
            }
        }

        return ThreadPostReport(posted: posted)
    }
}

extension APIError {
    /// Normalises any thrown error into an ``APIError`` so callers always have
    /// a `userMessage` to show.
    /// - Parameter error: Anything a service can throw.
    public static func wrapping(_ error: Error) -> APIError {
        (error as? APIError) ?? .transport(error.localizedDescription)
    }
}
