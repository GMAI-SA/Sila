import Foundation

/// Machine-readable error codes the SocialSA backend returns inside
/// `{"detail": {"code": ..., "message": ...}}`.
public enum APIErrorCode: String, Sendable, Equatable {
    /// Registration attempted with an address that already has an account.
    case emailTaken = "email_taken"
    /// Wrong email/password pair on sign-in.
    case invalidCredentials = "invalid_credentials"
    /// The submitted OTP does not match.
    case otpInvalid = "otp_invalid"
    /// The submitted OTP is past its lifetime.
    case otpExpired = "otp_expired"
    /// Too many wrong OTP guesses — a fresh code must be requested.
    case otpAttemptsExceeded = "otp_attempts_exceeded"
    /// Credentials were correct but the address has never been confirmed.
    case emailUnverified = "email_unverified"
    /// The caller is being throttled.
    case rateLimited = "rate_limited"
    /// No usable bearer token reached the server.
    ///
    /// Undocumented in either contract, but what the deployed backend actually
    /// answers on an unauthenticated request — without this the raw
    /// "Missing bearer token" would be shown to the user.
    case unauthorized = "unauthorized"

    // MARK: Phase 2 — Nafath identity verification

    /// `POST /verification/nafath/start` from an account that is already
    /// verified (HTTP 409). Not a failure — the wall just needs refreshing.
    case alreadyVerified = "already_verified"
    /// The submitted number is not a plausible National ID / Iqama (HTTP 400).
    case invalidNationalId = "invalid_national_id"
    /// This identity is already attached to a *different* Sila account
    /// (HTTP 409). One person, one account — the answer is signing in to the
    /// account that exists, and the copy has to say so rather than read as an
    /// error to retry.
    case identityAlreadyUsed = "identity_already_used"
    /// The Nafath integration is down (HTTP 503). Try later; nothing was lost.
    case verificationUnavailable = "verification_unavailable"
    /// The verified identity is under Sila's minimum age (HTTP 403). There is
    /// nothing to retry and nothing to correct — the server's message is shown
    /// as-is.
    case underMinimumAge = "under_minimum_age"

    // MARK: Contract v12 — document + selfie verification

    /// A check digit in the machine-readable zone failed server-side
    /// (HTTP 400). The answer is a better photograph, never a typed value.
    case invalidMrz = "invalid_mrz"
    /// The zone's expiry date is in the past (HTTP 400).
    case documentExpired = "document_expired"
    /// A submission is already waiting for a reviewer (HTTP 409).
    case reviewPending = "review_pending"
    /// Not a passport, national ID or residence permit (HTTP 400).
    case invalidDocumentType = "invalid_document_type"
    /// The document is Saudi — a Saudi nationality or a Saudi-issued permit
    /// (HTTP 409). Not a failure: this person has an identity Nafath proves
    /// in a minute, and one person is one account, so the document route
    /// hands them to Nafath rather than open a second account.
    case useNafath = "use_nafath"
    /// The proven nationality differs from the declared one (HTTP 403). The
    /// account is now `rejected`; the wall and the email say why.
    case nationalityMismatch = "nationality_mismatch"

    // MARK: Contract v2 — feed & social

    /// The requested post id does not exist (or is no longer visible).
    case postNotFound = "post_not_found"
    /// The thread's scope excludes this viewer — see `viewer.reply_block_reason`.
    case replyNotAllowed = "reply_not_allowed"
    /// `GET /feed/country` from an account with no verified country.
    case noCountry = "no_country"
    /// A post body longer than ``FeedConstants/maximumPostLength``.
    case textTooLong = "text_too_long"
    /// The request body failed a field rule (HTTP 422) — a name too short, a
    /// note too long. The message on the error is already a sentence for
    /// the person, built from the field that failed, never the server's own
    /// wording.
    case validationError = "validation_error"
    /// A guest reached for something that acts (HTTP 401).
    ///
    /// Distinct from ``unauthorized``, which is a session that went bad: this
    /// one is an invitation, and every client answers it with one rather than
    /// with an error.
    case signInRequired = "sign_in_required"
    /// A subject was pinned in the strip that this account has hidden (HTTP
    /// 409). The strip does not offer one, so this only reaches a client
    /// holding a stale choice — which it answers by clearing it.
    case topicMuted = "topic_muted"
    /// Delete or edit attempted on someone else's post.
    case notPostAuthor = "not_post_author"
    /// The requested handle is already in use.
    case handleTaken = "handle_taken"
    /// The requested handle breaks the `[a-z0-9_]{3,20}` rule.
    case invalidHandle = "invalid_handle"
    /// An account tried to follow itself.
    case selfFollow = "self_follow"
    /// No active account has that handle.
    ///
    /// Returned by every `/users/{handle}` route for an unknown handle **and**
    /// for a deactivated one — the lookup filters `deactivated == False`, so the
    /// two are deliberately indistinguishable. An error that admitted the second
    /// case would leak the existence of an account that asked to be gone.
    case userNotFound = "user_not_found"

    // MARK: Contract v3 — compose & search

    /// `POST /posts` from an account that has not completed identity
    /// verification. Reading is open to everyone; speaking is not.
    case unverified
    /// The `scope` / `scope_country` / `scope_region` combination was rejected —
    /// e.g. a country thread opened for a country the author is not verified in.
    case invalidScope = "invalid_scope"
    /// A search query shorter than ``SearchConstants/minimumQueryLength``.
    case queryTooShort = "query_too_short"

    // MARK: Contract v4 — interests & preferences

    /// `PUT /me/preferences` carried a topic id outside the server's taxonomy.
    case unknownTopic = "unknown_topic"
    /// `PUT /me/preferences` carried something that is not an ISO-3166 alpha-2 code.
    case invalidCountry = "invalid_country"

    // MARK: Contract v5 — account management

    /// The uploaded file could not be decoded as an image (HTTP 400).
    case invalidImage = "invalid_image"
    /// The upload is over 5 MB, or over 50 megapixels (HTTP 413).
    case imageTooLarge = "image_too_large"
    /// `PUT /me/phone` was given something that is not E.164 (HTTP 400).
    case invalidPhone = "invalid_phone"
    /// The new password is the same as the current one (HTTP 400).
    case passwordUnchanged = "password_unchanged"
    /// The requested address is the one already on the account (HTTP 400).
    case emailUnchanged = "email_unchanged"
    /// `POST /me/delete` arrived without `confirm: "DELETE"` (HTTP 400).
    case confirmationRequired = "confirmation_required"
    /// `POST /me/delete/cancel` on an account with nothing to cancel (HTTP 400).
    case notPendingDeletion = "not_pending_deletion"
    /// The account is scheduled for deletion (HTTP 403).
    ///
    /// Not a 401: the credentials are perfectly good. Every authenticated call
    /// answers this until the deletion is cancelled, which is why the client
    /// routes it to the recovery screen rather than showing it as an error.
    case accountDeactivated = "account_deactivated"

    // MARK: Safety — block, mute, report, suspension

    /// An account tried to block itself (HTTP 400).
    case selfBlock = "self_block"
    /// An account tried to mute itself (HTTP 400).
    case selfMute = "self_mute"
    /// An account tried to report itself (HTTP 400).
    case selfReport = "self_report"
    /// `POST /reports` carried a reason outside the server's list (HTTP 400).
    ///
    /// Unreachable from the picker, which is built out of ``ReportReason`` — it
    /// exists for a build talking to a server whose vocabulary has moved on.
    case invalidReason = "invalid_reason"
    /// There is a block between the viewer and this thread (HTTP 403).
    ///
    /// Deliberately says nothing about **which** direction. Whether somebody
    /// blocked you or you blocked them, the outcome is the same and the client
    /// has no business turning a safety tool into a notification.
    case blocked
    /// The account is suspended (HTTP 403).
    ///
    /// Not a 401: the credentials are good. Every authenticated call answers
    /// this except `GET /me/suspension` and `POST /me/appeal`, which is why the
    /// client routes it to the suspension screen rather than showing it as an
    /// error with a Retry button that can only produce it again.
    case accountSuspended = "account_suspended"
    /// A second appeal against the same suspension (HTTP 409).
    case alreadyAppealed = "already_appealed"

    // MARK: Contract v9 — the verification gate & identity challenges

    /// Enough verified people have said this account is presenting itself as
    /// somebody it is not, so posting is paused while a moderator looks
    /// (HTTP 403).
    ///
    /// Deliberately **not** an account state like ``accountSuspended``. A hold
    /// stops writing and nothing else: reading, feeds and messages all still
    /// work, and the account's existing posts stay up. Putting it on a wall
    /// would tell somebody they had been judged when nothing has been decided,
    /// which is exactly what a hold is careful not to do — so it surfaces at
    /// the refused write and nowhere else.
    case identityHold = "identity_hold"

    // MARK: Voice rooms

    /// The room's scope excludes this account from **speaking**.
    ///
    /// Never from listening: there is no code for that, because there is no
    /// such refusal. Anyone may enter any room.
    case scopeNotAllowed = "scope_not_allowed"
    /// The host removed this account from **this room**.
    ///
    /// Per-room and nothing more. It is not a block, it changes nothing about
    /// the account, and it does not follow anybody into another room — which is
    /// why it has its own code and its own sentence rather than borrowing
    /// ``blocked``'s.
    case removedFromRoom = "removed_from_room"
    /// The room is over. Nothing was recorded, so there is nothing to rejoin.
    case roomEnded = "room_ended"
    /// A host-only call from somebody who is not the host.
    case notRoomHost = "not_room_host"
    /// The stage has as many speakers as it will hold.
    case stageFull = "stage_full"
    /// A host tried to move themselves off their own stage.
    case cannotDemoteHost = "cannot_demote_host"
    /// The room id does not exist.
    case notFound = "not_found"
    /// The room is closed and this account holds no invitation (HTTP 403).
    /// Not a removal: nobody decided anything about this person, the room was
    /// never open to them.
    case notInvited = "not_invited"
    /// A following-only room the host does not follow the viewer into.
    case notFollowed = "not_followed"
    /// A group room the viewer is not a member of.
    case notInGroup = "not_in_group"
    /// A room inside a community the viewer has not joined.
    case notInCommunity = "not_in_community"
    /// A community address somebody else holds.
    case slugTaken = "slug_taken"
    case slugReserved = "slug_reserved"
    case invalidSlug = "invalid_slug"
    /// Writing where you are not a member, or where the scope shuts you out.
    case cannotPostHere = "cannot_post_here"
    /// Reading a private community from outside it.
    case notAMember = "not_a_member"
    case notAnAdmin = "not_an_admin"
    case alreadyMember = "already_member"
    case removedFromCommunity = "removed_from_community"
    case communityClosed = "community_closed"
    case tooManyCommunities = "too_many_communities"
    /// A room asked for two kinds of door at once.
    case oneDoor = "one_door"
    /// A room opened for a group the host does not own.
    case groupNotFound = "group_not_found"
    /// A second group with the same name.
    case groupExists = "group_exists"
    /// The group cap.
    case tooManyGroups = "too_many_groups"
    /// A group with no name.
    case invalidName = "invalid_name"
    /// The member cap.
    case groupFull = "group_full"
    /// A hand raised from the stage: they already hold the microphone.
    case alreadySpeaking = "already_speaking"
    /// A hand raised before joining.
    case notInRoom = "not_in_room"
    /// A mute aimed at somebody who is not on the stage.
    case notSpeaking = "not_speaking"
    /// A readmit for somebody who was never removed.
    case notRemoved = "not_removed"
    /// The host cannot mute themselves through this path.
    case cannotMuteHost = "cannot_mute_host"
    /// The declared birthdate and the document disagree. Terminal, like the
    /// nationality mismatch, and for the same reason.
    case dateOfBirthMismatch = "date_of_birth_mismatch"
    /// The document route was started before the birthdate was declared.
    case dateOfBirthRequired = "date_of_birth_required"
    /// A birthdate in the future, or an impossible age.
    case invalidDateOfBirth = "invalid_date_of_birth"
    /// More head-turn frames than the ring has sectors.
    case tooManyFrames = "too_many_frames"
    /// The frames and the trace do not agree.
    case livenessMismatch = "liveness_mismatch"
    /// Invitations were sent for a room anybody may enter (HTTP 400).
    case notInviteOnly = "not_invite_only"

    // MARK: Contract v19 — polls
    /// A poll broke a rule (HTTP 400); the client validates first.
    case invalidPoll = "invalid_poll"
    /// A poll on a reply (HTTP 400).
    case pollOnReply = "poll_on_reply"
    /// A poll beside images, a GIF or a quote (HTTP 400).
    case pollWithMedia = "poll_with_media"
    /// Voting and replying are one right, and this viewer has neither (HTTP 403).
    case voteNotAllowed = "vote_not_allowed"
    /// The poll has closed (HTTP 409).
    case pollClosed = "poll_closed"
    /// A vote is final (HTTP 409).
    case alreadyVoted = "already_voted"
    /// Not an option in this poll (HTTP 400).
    case invalidOption = "invalid_option"
    /// The post carries no poll (HTTP 404).
    case pollNotFound = "poll_not_found"

    /// Anything the client does not recognise.
    case unknown

    /// Maps a raw server code to a case, defaulting to ``unknown``.
    public init(serverCode: String) {
        self = APIErrorCode(rawValue: serverCode) ?? .unknown
    }
}

/// Every failure the networking layer can produce.
public enum APIError: Error, Equatable, Sendable {
    /// A structured `detail` object came back from the API.
    case api(code: APIErrorCode, message: String, status: Int)
    /// A non-2xx response we could not parse into ``api(code:message:status:)``.
    case http(status: Int, message: String)
    /// The response body did not match the expected shape.
    case decoding(String)
    /// URLSession failed (offline, DNS, TLS, timeout…).
    case transport(String)
    /// The request was cancelled — almost always by the app itself, when a
    /// screen went away or a newer request replaced this one. Never the
    /// person's problem, and never worth a message.
    case cancelled
    /// No credentials available for a call that requires them.
    case unauthenticated
    /// The device refused or failed the biometric prompt.
    case biometricFailed(String)

    /// The structured code when one is available.
    public var code: APIErrorCode? {
        if case let .api(code, _, _) = self { return code }
        return nil
    }

    /// A sentence safe to put in front of a user.
    public var userMessage: String {
        switch self {
        case let .api(code, message, _):
            switch code {
            case .signInRequired:
                return L10n.t("guest.join.post.title")
            case .topicMuted:
                return L10n.t("feed.subject.muted")
            case .validationError:
                return message.isEmpty ? L10n.t("error.validation") : message
            case .emailTaken:
                return L10n.t("error.emailTaken")
            case .invalidCredentials:
                return L10n.t("error.invalidCredentials")
            case .otpInvalid:
                return L10n.t("error.otpInvalid")
            case .otpExpired:
                return L10n.t("error.otpExpired")
            case .otpAttemptsExceeded:
                return L10n.t("error.otpAttemptsExceeded")
            case .emailUnverified:
                return L10n.t("error.emailUnverified")
            case .rateLimited:
                return L10n.t("error.rateLimited")
            case .unauthorized:
                return L10n.t("error.sessionEnded")
            case .alreadyVerified:
                return L10n.t("error.alreadyVerified")
            case .invalidNationalId:
                return L10n.t("error.invalidNationalId")
            case .identityAlreadyUsed:
                return L10n.t("error.identityAlreadyUsed")
            case .verificationUnavailable:
                return L10n.t("error.verificationUnavailable")
            case .underMinimumAge:
                // The server's sentence when it sent one: the age rule and its
                // wording are policy, and policy copy comes from the server.
                return message.isEmpty ? L10n.t("error.underMinimumAge") : message
            case .invalidMrz:
                return L10n.t("error.invalidMrz")
            case .documentExpired:
                return L10n.t("error.documentExpired")
            case .reviewPending:
                return L10n.t("error.reviewPending")
            case .invalidDocumentType:
                return L10n.t("error.invalidDocumentType")
            case .useNafath:
                return L10n.t("error.useNafath")
            case .nationalityMismatch:
                return L10n.t("error.nationalityMismatch")
            case .postNotFound:
                return L10n.t("error.postNotFound")
            case .replyNotAllowed:
                // The card and the detail screen show the specific
                // `reply_block_reason`; this is the fallback if one slips past.
                return L10n.t("error.replyNotAllowed")
            case .noCountry:
                return L10n.t("error.noCountry")
            case .textTooLong:
                return L10n.plural("error.textTooLong", FeedConstants.maximumPostLength)
            case .notPostAuthor:
                return L10n.t("error.notPostAuthor")
            case .handleTaken:
                return L10n.t("error.handleTaken")
            case .invalidHandle:
                return L10n.t("error.invalidHandle")
            case .selfFollow:
                return L10n.t("error.selfFollow")
            case .userNotFound:
                // Phrased as a fact about the handle, not as a failure of the
                // request: there is nothing to retry, and the profile screen
                // shows this without a Try Again button for that reason.
                return L10n.t("error.userNotFound")
            case .unverified:
                return L10n.t("error.unverified")
            case .invalidScope:
                return L10n.t("error.invalidScope")
            case .queryTooShort:
                return L10n.plural("error.queryTooShort", SearchConstants.minimumQueryLength)
            case .unknownTopic:
                // The whole PUT is rejected, so nothing was stored — say that
                // rather than leaving the user unsure what got through.
                return L10n.t("error.unknownTopic")
            case .invalidCountry:
                return L10n.t("error.invalidCountry")
            case .invalidImage:
                return L10n.t("error.invalidImage")
            case .imageTooLarge:
                return L10n.t("error.imageTooLarge")
            case .invalidPhone:
                return L10n.t("error.invalidPhone")
            case .passwordUnchanged:
                return L10n.t("error.passwordUnchanged")
            case .emailUnchanged:
                return L10n.t("error.emailUnchanged")
            case .confirmationRequired:
                return L10n.t("error.confirmationRequired")
            case .notPendingDeletion:
                return L10n.t("error.notPendingDeletion")
            case .accountDeactivated:
                // Shown only if this ever reaches a screen: the deactivation
                // monitor is meant to route it to the recovery screen first.
                return L10n.t("error.accountDeactivated")
            case .selfBlock:
                return L10n.t("error.selfBlock")
            case .selfMute:
                return L10n.t("error.selfMute")
            case .selfReport:
                return L10n.t("error.selfReport")
            case .invalidReason:
                return L10n.t("error.invalidReason")
            case .blocked:
                // Says a block exists, never who made it. Turning a safety tool
                // into a notification is exactly what nobody signed up for.
                return L10n.t("error.blocked")
            case .accountSuspended:
                // Shown only if this ever reaches a screen: the suspension
                // monitor is meant to route it to the suspension screen first.
                return L10n.t("error.accountSuspended")
            case .alreadyAppealed:
                return L10n.t("error.alreadyAppealed")
            case .identityHold:
                // Says what is paused, what is not, and that nothing has been
                // decided. Never "your account is under review for
                // impersonation": the claim is unproven and repeating it to the
                // person accused is how a hold becomes an accusation.
                return L10n.t("error.identityHold")
            case .scopeNotAllowed:
                // Says exactly what is refused. The room itself is still open —
                // scope governs the microphone, never the door.
                return L10n.t("error.scopeNotAllowed")
            case .removedFromRoom:
                return RoomCopy.removedFromRoom
            case .roomEnded:
                return RoomCopy.roomEnded
            case .notRoomHost:
                return L10n.t("error.notRoomHost")
            case .stageFull:
                return RoomCopy.stageFull
            case .cannotDemoteHost:
                return RoomCopy.cannotDemoteHost
            case .notFound:
                return L10n.t("error.roomNotFound")
            case .notInvited:
                return L10n.t("rooms.inviteOnly.refusal")
            case .notFollowed:
                return L10n.t("rooms.followingOnly.refusal")
            case .notInGroup:
                return L10n.t("rooms.groupOnly.refusal")
            case .notInCommunity:
                return L10n.t("rooms.communityOnly.refusal")
            case .slugTaken:
                return L10n.t("error.slugTaken")
            case .slugReserved:
                return L10n.t("error.slugReserved")
            case .invalidSlug:
                return L10n.t("error.invalidSlug")
            case .cannotPostHere:
                return L10n.t("error.cannotPostHere")
            case .notAMember:
                return L10n.t("error.notAMember")
            case .notAnAdmin:
                return L10n.t("error.notAnAdmin")
            case .alreadyMember:
                return L10n.t("error.alreadyMember")
            case .removedFromCommunity:
                return L10n.t("error.removedFromCommunity")
            case .communityClosed:
                return L10n.t("error.communityClosed")
            case .tooManyCommunities:
                return L10n.t("error.tooManyCommunities")
            case .oneDoor:
                return L10n.t("error.oneDoor")
            case .groupNotFound:
                return L10n.t("error.groupNotFound")
            case .groupExists:
                return L10n.t("error.groupExists")
            case .tooManyGroups:
                return L10n.t("error.tooManyGroups")
            case .invalidName:
                return L10n.t("error.invalidName")
            case .groupFull:
                return L10n.t("error.groupFull")
            case .alreadySpeaking:
                return L10n.t("error.alreadySpeaking")
            case .notInRoom:
                return L10n.t("error.notInRoom")
            case .notSpeaking:
                return L10n.t("error.notSpeaking")
            case .notRemoved:
                return L10n.t("error.notRemoved")
            case .cannotMuteHost:
                return L10n.t("error.cannotMuteHost")
            case .dateOfBirthMismatch:
                return L10n.t("error.dateOfBirthMismatch")
            case .dateOfBirthRequired:
                return L10n.t("error.dateOfBirthRequired")
            case .invalidDateOfBirth:
                return L10n.t("error.invalidDateOfBirth")
            case .tooManyFrames, .livenessMismatch:
                return L10n.t("error.livenessMismatch")
            case .notInviteOnly:
                return L10n.t("error.notInviteOnly")
            case .invalidPoll:
                return L10n.t("poll.error.invalid")
            case .pollOnReply:
                return L10n.t("poll.error.onReply")
            case .pollWithMedia:
                return L10n.t("poll.error.withMedia")
            case .voteNotAllowed:
                return L10n.t("poll.error.notAllowed")
            case .pollClosed:
                return L10n.t("poll.error.closed")
            case .alreadyVoted:
                return L10n.t("poll.error.alreadyVoted")
            case .invalidOption, .pollNotFound:
                return L10n.t("poll.error.gone")
            case .unknown:
                return message.isEmpty ? L10n.t("common.somethingWentWrong") : message
            }
        case let .http(status, message):
            return message.isEmpty ? L10n.t("error.httpStatus", SLFormat.number(status)) : message
        case .decoding:
            return L10n.t("error.decoding")
        case .cancelled:
            // Nothing went wrong that anybody can act on. Callers check
            // `isCancellation` and say nothing; this exists so a stray path
            // that ignores that still says something harmless.
            return L10n.t("feed.error.pullToRefresh")
        case let .transport(message):
            return L10n.t("error.transport", message)
        case .unauthenticated:
            return L10n.t("error.sessionEnded")
        case let .biometricFailed(message):
            return message
        }
    }
}

/// The `detail` payload shape used by the backend for structured errors.
struct APIErrorEnvelope: Decodable {
    let detail: Detail

    struct Detail: Decodable {
        let code: String
        let message: String
        /// Present on `validation_error`: what was wrong with which field.
        let fields: [ValidationField]?
    }
}

/// One field the server refused, in either envelope the server sends.
struct ValidationField: Decodable {
    /// The pydantic rule that failed: `string_too_short`, `string_too_long`, …
    let type: String
    /// The rule's parameters — `min_length`, `max_length` — when it has any.
    let limits: [String: Int]

    private enum CodingKeys: String, CodingKey { case type, ctx }

    init(type: String, limits: [String: Int] = [:]) {
        self.type = type
        self.limits = limits
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = (try? container.decode(String.self, forKey: .type)) ?? ""
        // Only the integer limits are read; a rule's other context is the
        // server's own business and is not shown to anybody.
        limits = ((try? container.decode([String: LenientInt].self, forKey: .ctx)) ?? [:])
            .compactMapValues(\.value)
    }

    /// A sentence for the person who typed into the field — never the
    /// server's own wording, which is for developers.
    var userMessage: String {
        switch type {
        case "string_too_short":
            if let minimum = limits["min_length"] { return L10n.plural("error.validation.tooShort", minimum) }
        case "string_too_long":
            if let maximum = limits["max_length"] { return L10n.plural("error.validation.tooLong", maximum) }
        default:
            break
        }
        return L10n.t("error.validation")
    }
}

/// An integer that may arrive as a number or as a string, or be something
/// else entirely — in which case it is nothing rather than a decode failure.
struct LenientInt: Decodable {
    let value: Int?

    init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if let number = try? single.decode(Int.self) {
            value = number
        } else if let text = try? single.decode(String.self) {
            value = Int(text)
        } else {
            value = nil
        }
    }
}

/// FastAPI's own 422: a bare list of `{loc, msg, type, ctx}`.
///
/// The server wraps these itself now, but a client must never depend on
/// that — a reply in this shape was what put raw JSON on somebody's screen.
struct APIValidationListEnvelope: Decodable {
    let detail: [ValidationField]
}

/// Fallback shape for FastAPI's plain-string `detail`.
struct APIErrorStringEnvelope: Decodable {
    let detail: String
}

extension APIError {
    /// Whether this is the app cancelling its own request.
    ///
    /// A SwiftUI `.task` is cancelled whenever its view goes away, a
    /// `refreshable` can be interrupted, and a search supersedes the request
    /// before it. All three arrive here as a cancellation, and showing
    /// "Network problem: cancelled" for any of them tells somebody their
    /// connection failed when nothing did.
    /// ``userMessage``, or `nil` for a cancellation — for the screens that
    /// keep an error as optional state rather than showing a toast.
    public var presentableMessage: String? {
        isCancellation ? nil : userMessage
    }

    /// The error a guest's client raises for an action it will not even try.
    public static let signInRequired = APIError.api(
        code: .signInRequired, message: "Join Sila to do that", status: 401
    )

    /// Whether this is the app asking somebody to join rather than a failure.
    public var isSignInRequired: Bool { code == .signInRequired }

    public var isCancellation: Bool {
        if case .cancelled = self { return true }
        if case let .transport(message) = self {
            return message.lowercased() == "cancelled"
        }
        return false
    }
}

