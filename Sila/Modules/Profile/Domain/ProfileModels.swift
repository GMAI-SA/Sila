import Foundation

// MARK: - The profile

/// Everything `GET /users/{handle}` holds about a person as seen by one viewer.
///
/// The account itself is a ``UserSummary`` — the *same* value that travels next
/// to every post — rather than a parallel "profile user" type. That is not only
/// deduplication: the checkmark and the country flag are the product's trust
/// signals, and a second type could drift from the one the feed renders and
/// start showing a different answer for the same person on two screens.
///
/// Two counters and two booleans here are **per-viewer**, computed server-side
/// on each request: ``isFollowing`` and ``isMe`` describe the relationship
/// between the caller and this account, not a property of the account.
public struct Profile: Equatable, Sendable, Decodable, Identifiable {

    /// The account, in the shape every other surface already renders.
    public let user: UserSummary
    /// Free text, at most ``AccountLimits/maximumBioLength`` characters, or
    /// `nil` when the person has not written one. An empty string from the wire
    /// is read as "none", because a blank line is not a bio.
    public let bio: String?
    /// How many **top-level** posts the account has.
    ///
    /// Not "how much this person has written": the server counts the same rows
    /// `GET /users/{handle}/posts` returns, and both exclude replies
    /// (`reply_to_post_id IS NULL`). A reply someone spent an afternoon on is in
    /// neither number, which is why nothing in the UI calls this their output.
    public let postCount: Int
    /// Accounts following this one.
    public let followerCount: Int
    /// Accounts this one follows.
    public let followingCount: Int
    /// Whether the **viewer** follows this account.
    public let isFollowing: Bool
    /// Whether this profile is the viewer's own.
    public let isMe: Bool

    /// Identity is the account's id, so a re-fetch of the same person is the
    /// same node in a navigation path.
    public var id: UUID { user.id }

    public init(
        user: UserSummary,
        bio: String? = nil,
        postCount: Int = 0,
        followerCount: Int = 0,
        followingCount: Int = 0,
        isFollowing: Bool = false,
        isMe: Bool = false
    ) {
        self.user = user
        self.bio = (bio?.isEmpty == false) ? bio : nil
        self.postCount = max(0, postCount)
        self.followerCount = max(0, followerCount)
        self.followingCount = max(0, followingCount)
        // Following yourself is impossible server-side (`400 self_follow`), so a
        // response that claimed both is corrected here rather than rendered as a
        // "Following" button the server would refuse.
        self.isFollowing = isMe ? false : isFollowing
        self.isMe = isMe
    }

    /// Explicit keys are mandatory because ``init(from:)`` is custom; the raw
    /// values are the camel-cased forms `.convertFromSnakeCase` produces.
    private enum CodingKeys: String, CodingKey {
        case user, bio, postCount, followerCount, followingCount, isFollowing, isMe
    }

    /// Tolerant decoder for everything **except** ``user``.
    ///
    /// A missing counter renders as zero, which is a worse profile but still a
    /// profile. A missing `user` is not survivable — there would be no name, no
    /// handle and no checkmark to draw — so that one is allowed to throw.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        user = try container.decode(UserSummary.self, forKey: .user)
        let rawBio = (try? container.decodeIfPresent(String.self, forKey: .bio)) ?? nil
        bio = (rawBio?.isEmpty == false) ? rawBio : nil
        postCount = max(0, (try? container.decode(Int.self, forKey: .postCount)) ?? 0)
        followerCount = max(0, (try? container.decode(Int.self, forKey: .followerCount)) ?? 0)
        followingCount = max(0, (try? container.decode(Int.self, forKey: .followingCount)) ?? 0)
        let me = (try? container.decode(Bool.self, forKey: .isMe)) ?? false
        isMe = me
        isFollowing = me ? false : ((try? container.decode(Bool.self, forKey: .isFollowing)) ?? false)
    }

    // MARK: Derived

    /// The account's handle, without the `@`.
    public var handle: String { user.handle }

    /// The handle as it is rendered, with the `@`.
    public var atHandle: String { user.atHandle }

    /// The name shown in the header.
    public var displayName: String { user.displayName }

    /// Whether a Follow / Following control belongs on screen at all.
    ///
    /// The button is *absent* on your own profile rather than disabled: the
    /// server answers `400 self_follow`, so a greyed-out control would be an
    /// affordance for something that cannot happen.
    public var showsFollowControl: Bool { !isMe }

    // MARK: Optimistic follow

    /// The state this client *predicts* after a follow or unfollow.
    ///
    /// Used only to keep the button responsive between the tap and the
    /// response. It is always replaced by ``reconciled(with:)`` — never kept.
    /// - Parameter following: The state the user asked for.
    public func predicting(following: Bool) -> Profile {
        guard !isMe, following != isFollowing else { return self }
        return Profile(
            user: user,
            bio: bio,
            postCount: postCount,
            followerCount: max(0, followerCount + (following ? 1 : -1)),
            followingCount: followingCount,
            isFollowing: following,
            isMe: isMe
        )
    }

    /// Adopts the server's authoritative answer to a follow or unfollow.
    ///
    /// **The count comes from the response, not from arithmetic.** Both verbs
    /// are idempotent, so a second device that already followed this account
    /// makes the local `+1` wrong; the server's number is the only one that
    /// reflects what is actually stored.
    /// - Parameter result: What `POST`/`DELETE /users/{handle}/follow` returned.
    public func reconciled(with result: FollowResult) -> Profile {
        Profile(
            user: user,
            bio: bio,
            postCount: postCount,
            // `nil` means the server did not state a count — the prediction is
            // then the best thing on hand, and inventing a number would be worse.
            followerCount: result.followerCount ?? followerCount,
            followingCount: followingCount,
            isFollowing: result.following,
            isMe: isMe
        )
    }
}

// MARK: - Follow result

/// What `POST` and `DELETE /users/{handle}/follow` answer.
///
/// Both verbs are **idempotent**: following twice succeeds, and unfollowing
/// somebody you do not follow succeeds. Neither is an error, and both report the
/// authoritative follower count afterwards — which is the whole reason this type
/// exists rather than the client counting for itself.
public struct FollowResult: Equatable, Sendable, Decodable {

    /// Whether the viewer follows the account **after** the call.
    public let following: Bool
    /// The account's follower count as the server now holds it, or `nil` when
    /// the response did not carry one.
    ///
    /// Optional on purpose: "the server said 12" and "the server said nothing"
    /// are different facts, and only the first may overwrite what is on screen.
    public let followerCount: Int?

    public init(following: Bool, followerCount: Int? = nil) {
        self.following = following
        self.followerCount = followerCount.map { max(0, $0) }
    }

    private enum CodingKeys: String, CodingKey {
        case following, followerCount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        following = (try? container.decode(Bool.self, forKey: .following)) ?? false
        followerCount = ((try? container.decodeIfPresent(Int.self, forKey: .followerCount)) ?? nil)
            .map { max(0, $0) }
    }
}

// MARK: - Copy

/// The sentences the profile surface uses about what it is showing.
///
/// Kept out of the view so they can be asserted directly. Every one of them
/// exists to stop a specific overclaim: the timeline is **top-level posts
/// only**, and a screen that says "Posts" beside a number and then lists
/// something narrower is quietly wrong about somebody's work.
public enum ProfileCopy {

    /// The note under the timeline heading. Always shown, including when the
    /// list is empty — the exclusion is a fact about the list, not about
    /// whether it happens to have rows today.
    public static let timelineScope =
        "Top-level posts only. Replies stay in the threads they belong to, so "
        + "they are not listed here and are not counted above."

    /// The empty timeline.
    public static let emptyTimelineTitle = "No posts yet"

    /// What an empty timeline means, given the exclusion above.
    /// - Parameter name: The account's display name.
    public static func emptyTimelineSubtitle(for name: String) -> String {
        "\(name) hasn't started a thread yet. Replies aren't shown here, so a "
            + "conversation they only joined won't appear."
    }

    /// The 404 dead end. Deliberately not phrased as a failure, and offered
    /// with no Retry — the handle will not start existing because somebody
    /// pressed a button.
    public static let unavailableTitle = "This account isn't available"

    /// - Parameter handle: The handle that was asked for, without the `@`.
    public static func unavailableSubtitle(for handle: String) -> String {
        let named = handle.isEmpty ? "That handle" : "@\(handle)"
        return "\(named) doesn't belong to an active Sila account. It may have "
            + "been deleted, or the handle may have changed."
    }

    /// Label for the follow control.
    /// - Parameter isFollowing: The current relationship.
    public static func followTitle(isFollowing: Bool) -> String {
        isFollowing ? "Following" : "Follow"
    }

    /// What activating the follow control does.
    /// - Parameters:
    ///   - isFollowing: The current relationship.
    ///   - name: The account's display name.
    public static func followHint(isFollowing: Bool, name: String) -> String {
        isFollowing
            ? "Stops showing \(name)'s posts in your Following feed"
            : "Shows \(name)'s posts in your Following feed"
    }
}

// MARK: - Handle normalisation

extension Handle {

    /// The handle as the server would match it: no `@`, trimmed, lower-cased.
    ///
    /// Case folding is safe because the lookup is `lower(handle) = lower(:h)`
    /// server-side; the `@` is stripped because every place a handle is *typed*
    /// or *tapped* in this app carries one.
    /// - Parameter raw: A handle from a mention, a search row or a post author.
    public static func normalised(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while value.hasPrefix("@") { value.removeFirst() }
        return value
    }

    /// The handle as a single, safe URL path component.
    ///
    /// Everything outside the server's `[a-z0-9_]` alphabet is dropped rather
    /// than percent-encoded. A tapped `@someone/../admin` must not be able to
    /// become a different path, and a handle the server cannot hold is a 404
    /// whichever way it is spelled — so the honest outcome is the profile
    /// screen's "isn't available" state, not a request to a fabricated URL.
    /// - Parameter raw: A handle from anywhere.
    /// - Returns: The safe component, or `""` when nothing usable survives.
    public static func pathComponent(_ raw: String) -> String {
        String(normalised(raw).unicodeScalars.filter { scalar in
            ("a"..."z").contains(String(scalar))
                || ("0"..."9").contains(String(scalar))
                || scalar == "_"
        })
    }
}
