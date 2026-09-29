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
    /// The upload is over 40 MB, or over what the server will decode
    /// (260 MP declared, 120 MP decoded; contract v27 §1) (HTTP 413).
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

    // MARK: Contract v26 — sessions and credentials

    /// A new password over the 72 bytes bcrypt reads — about 72 Latin or 36
    /// Arabic characters (HTTP 400): at registration, a reset, a password
    /// change, and a password sent with a code.
    case passwordTooLong = "password_too_long"
    /// A credential change on an account with no password, sent without the
    /// texted code that stands in for one (HTTP 403).
    case reauthRequired = "reauth_required"
    /// Neither a password nor a confirmed phone to prove the change with
    /// (HTTP 409). "Forgot password" sets one.
    case reauthUnavailable = "reauth_unavailable"
    /// A texted code asked for on an account that has a password (HTTP 409).
    case hasPassword = "has_password"
    /// A number another account holds (HTTP 409).
    case phoneUnavailable = "phone_unavailable"
    /// The number this account signs in with, which it cannot give up while
    /// it has no other way in (HTTP 409).
    case phoneIsSignIn = "phone_is_sign_in"
    /// An email change that would leave or take an admin's address (HTTP 403),
    /// at `/me/email/request` or `/me/email/confirm`. Admin rights follow the
    /// address, so it is never moved from the app. Nothing changed.
    case emailChangeRefused = "email_change_refused"

    // MARK: Contract v28 — production without dev mode

    /// No SMS provider: every texted code is refused, before anything is
    /// counted (HTTP 503).
    case smsUnavailable = "sms_unavailable"

    // MARK: Contract v27 — uploads and media

    /// A post's picture that is not one this server minted for this author,
    /// or the same one twice (HTTP 400).
    case invalidImageURL = "invalid_image_url"
    /// A post's picture that is gone, already on another post, or never
    /// arrived (HTTP 400). Upload it again.
    case imageUnavailable = "image_unavailable"
    /// A request body larger than its route could need (HTTP 413).
    case requestTooLarge = "request_too_large"
    /// A GIF the library could not look up: the provider is down (HTTP 503).
    case gifUnavailable = "gif_unavailable"
    /// A GIF the library does not hold and no provider could vouch for
    /// (HTTP 400) — with no provider key, any GIF not already in the library.
    case invalidGif = "invalid_gif"

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

    // MARK: Contract v20 — voice
    case invalidAudio = "invalid_audio"
    case audioTooShort = "audio_too_short"
    case audioTooLong = "audio_too_long"
    case invalidKind = "invalid_kind"
    case audioTooLarge = "audio_too_large"
    case audioProcessingUnavailable = "audio_processing_unavailable"
    case voiceWithMedia = "voice_with_media"
    case invalidVoiceClip = "invalid_voice_clip"
    case voiceClipUsed = "voice_clip_used"
    case captionRedoLimit = "caption_redo_limit"
    case ownHotTake = "own_hot_take"
    case notAHotTake = "not_a_hot_take"
    // MARK: Contract v21 — reach
    case roomNotScheduled = "room_not_scheduled"
    case tooManySeries = "too_many_series"
    case invalidTimezone = "invalid_timezone"
    case invalidQuietHours = "invalid_quiet_hours"
    // MARK: Contract v22 — depth
    case unknownReaction = "unknown_reaction"
    case ownPost = "own_post"
    case tooManyCohosts = "too_many_cohosts"
    case alreadyHost = "already_host"
    case ownQuestion = "own_question"
    case pollOpen = "poll_open"
    case roomNotLive = "room_not_live"
    case termTooShort = "term_too_short"
    case tooManyTerms = "too_many_terms"
    case guidelinesChanged = "guidelines_changed"
    // MARK: Contract v23 — events
    case invalidTime = "invalid_time"
    case invalidVenue = "invalid_venue"
    case tooManyUpcoming = "too_many_upcoming"
    case eventFull = "event_full"
    case eventOver = "event_over"
    case eventNotShareable = "event_not_shareable"

    /// Nafath is not open yet ("coming soon"): verify with a document (HTTP 503).
    case nafathUnavailable = "nafath_unavailable"
    // MARK: Contract v25 — withdrawing a document submission
    /// Nothing is waiting to be withdrawn: never sent, already withdrawn, or
    /// already decided — by a moderator or the pre-screen (HTTP 409).
    case nothingToWithdraw = "nothing_to_withdraw"

    // MARK: Contract v24 — vouching
    /// A vouched account reached something only a verified one may do (HTTP
    /// 403). Answered with "verify your identity to do this" and the
    /// verification flow — never with the wall, which is for ``unverified``.
    case selfVerificationRequired = "self_verification_required"
    /// Messaging a vouched account, which cannot use messages (HTTP 403).
    case recipientCannotMessage = "recipient_cannot_message"
    /// A vouched account's post names more than three people (HTTP 400).
    case tooManyMentions = "too_many_mentions"
    /// Making a vouched member a community admin (HTTP 409).
    case notVerified = "not_verified"
    /// Minting a link while the server's flag is off (HTTP 403).
    case vouchingNotOpen = "vouching_not_open"
    /// Minting refused — a hold or a flag, deliberately one code (HTTP 403).
    case vouchUnavailable = "vouch_unavailable"
    case vouchPrivilegeRevoked = "vouch_privilege_revoked"
    case vouchTooNew = "vouch_too_new"
    case vouchSlotsFull = "vouch_slots_full"
    case vouchRateLimited = "vouch_rate_limited"
    /// A promise left unticked (HTTP 400).
    case attestationsRequired = "attestations_required"
    /// Any link that cannot be used — one answer for all of them (HTTP 404).
    case inviteUnavailable = "invite_unavailable"
    case inviteNotFound = "invite_not_found"
    case inviteClaimed = "invite_claimed"
    case alreadyVouched = "already_vouched"
    case vouchLifetimeReached = "vouch_lifetime_reached"
    case vouchTooSoon = "vouch_too_soon"
    /// An account a verification decision closed (HTTP 403).
    case vouchNotEligible = "vouch_not_eligible"
    case vouchNotFound = "vouch_not_found"
    case notPending = "not_pending"
    case notLive = "not_live"
    /// Confirming after the 48 hours (HTTP 410).
    case confirmWindowPassed = "confirm_window_passed"
    case voucheeGone = "vouchee_gone"
    case noSummons = "no_summons"
    case summonsClosed = "summons_closed"
    case invalidAction = "invalid_action"
    /// A detail missing, or one that cannot be right (HTTP 400, §11).
    case detailsRequired = "details_required"
    case invalidFullName = "invalid_full_name"
    /// Under 18: nobody that age can be vouched for (400 minting, 403 claiming).
    case vouchUnderAge = "vouch_under_age"
    /// The claim's details differ from the voucher's (HTTP 409). Arrives as
    /// ``APIError/detailsMismatch(fields:attemptsLeft:message:)``, which
    /// carries which fields.
    case detailsMismatch = "details_mismatch"
    /// The third mismatch closed the link for good (HTTP 409).
    case inviteClosed = "invite_closed"

    // MARK: Contract v28 — video

    /// Video is off on this server (`reason: not_available`) or the account
    /// is not verified (`reason: not_verified`) (HTTP 403). The reason decides
    /// the words; see ``URLSessionNetworkClient/makeError(status:data:)``.
    case videoNotAllowed = "video_not_allowed"
    /// Longer than three minutes, declared or measured (HTTP 400).
    case videoTooLong = "video_too_long"
    /// Over 300 MB (HTTP 413).
    case videoTooLarge = "video_too_large"
    /// Twenty finished (or forty started) uploads in a day (HTTP 429).
    case videoRateLimited = "video_rate_limited"
    /// The upload has gone: a day old, or superseded (HTTP 410). The client
    /// starts a new plan with the same file without saying anything.
    case uploadExpired = "upload_expired"
    /// Complete called with something missing (HTTP 409). The client sends
    /// what is missing and completes again.
    case uploadIncomplete = "upload_incomplete"
    /// A chunk that does not fit the plan — a client bug (HTTP 400).
    case uploadChunkInvalid = "upload_chunk_invalid"
    /// A chunk for a `parts` plan, or the reverse, or the upload is complete
    /// (HTTP 409).
    case uploadTypeMismatch = "upload_type_mismatch"
    /// Storage failed for a moment (HTTP 503). Retried with a backoff.
    case videoUploadUnavailable = "video_upload_unavailable"
    /// Not yours, or no such video (HTTP 404).
    case videoNotFound = "video_not_found"
    /// Posting somebody else's video (HTTP 400).
    case invalidVideo = "invalid_video"
    /// The video is on a post already (HTTP 409).
    case videoUsed = "video_used"
    /// Posting before the upload completed (HTTP 409).
    case videoNotUploaded = "video_not_uploaded"
    /// Posting a video that failed (HTTP 409); `failure_code` says why, and
    /// the words are the failure's.
    case videoProcessingFailed = "video_processing_failed"
    /// Posting a removed video (HTTP 409).
    case videoRemoved = "video_removed"
    /// A video beside pictures, a GIF, a poll or a voice clip (HTTP 400).
    case videoWithMedia = "video_with_media"

    // MARK: Contract v31 — guest listening

    /// A guest reached a room whose door is not open to everybody —
    /// invite-only, following-only, a group's or a community's (HTTP 403);
    /// or a host tried to let guests into such a room (HTTP 409).
    case roomClosed = "room_closed"
    /// The host turned guests off, the host is a private account, or guest
    /// listening is off for the whole platform (HTTP 403).
    case guestsNotAllowed = "guests_not_allowed"
    /// Every guest seat in the room is taken (HTTP 409).
    case guestsFull = "guests_full"
    /// Turning guests on in a private host's room (HTTP 409).
    case privateHost = "private_host"

    // MARK: Contract v32 — App Attest (read by `AppAttestor`, never shown)

    /// The server refused the attestation itself (HTTP 400): Apple's
    /// certificate chain, the nonce, the key — the two sides disagree about
    /// the device. The only answer that pauses attestation on the install.
    case attestationInvalid = "attestation_invalid"
    /// The attestation's challenge was not one to answer (HTTP 400):
    /// replaced by a newer one, already spent, or past its five minutes.
    /// Nothing was said about the device; the app asks for a fresh one.
    case challengeStale = "challenge_stale"
    /// `POST /device/assert/challenge {"key_id"}` for a key this account does
    /// not hold, or no longer holds (HTTP 404). The app attests a new one.
    case keyUnknown = "key_unknown"
    /// The attested key is already on file (HTTP 409): an earlier answer
    /// that never arrived.
    case keyExists = "key_exists"

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
    /// `409 details_mismatch` on a vouch claim (contract v24 §11): which of
    /// the person's own details differ from what the voucher wrote — the
    /// fields' names only, never the voucher's values — and how many tries
    /// the link has left. Its own case because ``api(code:message:status:)``
    /// has nowhere to put the fields.
    case detailsMismatch(fields: [String], attemptsLeft: Int, message: String)

    /// The structured code when one is available.
    public var code: APIErrorCode? {
        if case let .api(code, _, _) = self { return code }
        if case .detailsMismatch = self { return .detailsMismatch }
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
            case .passwordTooLong:
                return L10n.t("error.passwordTooLong")
            case .reauthRequired:
                return L10n.t("error.reauthRequired")
            case .reauthUnavailable:
                return L10n.t("error.reauthUnavailable")
            case .hasPassword:
                return L10n.t("error.hasPassword")
            case .phoneUnavailable:
                return L10n.t("error.phoneUnavailable")
            case .phoneIsSignIn:
                return L10n.t("error.phoneIsSignIn")
            case .emailChangeRefused:
                return L10n.t("error.emailChangeRefused")
            case .smsUnavailable:
                return L10n.t("error.smsUnavailable")
            case .invalidImageURL:
                return L10n.t("error.invalidImageUrl")
            case .imageUnavailable:
                return L10n.t("error.imageUnavailable")
            case .requestTooLarge:
                return L10n.t("error.requestTooLarge")
            case .gifUnavailable:
                return L10n.t("error.gifUnavailable")
            case .invalidGif:
                return L10n.t("error.invalidGif")
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
            case .invalidAudio: return L10n.t("voice.error.invalid")
            case .audioTooShort: return L10n.t("voice.error.tooShort")
            case .audioTooLong: return message.isEmpty ? L10n.t("voice.error.tooLong") : message
            case .invalidKind: return L10n.t("voice.error.invalid")
            case .audioTooLarge: return L10n.t("voice.error.tooLarge")
            case .audioProcessingUnavailable: return L10n.t("voice.error.unavailable")
            case .voiceWithMedia: return L10n.t("voice.error.withMedia")
            case .invalidVoiceClip, .voiceClipUsed: return L10n.t("voice.error.clipGone")
            case .captionRedoLimit: return L10n.t("voice.error.redoLimit")
            case .ownHotTake: return L10n.t("voice.error.ownHotTake")
            case .notAHotTake: return L10n.t("voice.error.notHotTake")
            case .roomNotScheduled: return L10n.t("rooms.remind.error.notScheduled")
            case .tooManySeries: return L10n.t("rooms.series.error.tooMany")
            case .invalidTimezone: return L10n.t("rooms.series.error.timezone")
            case .invalidQuietHours: return L10n.t("notifications.quiet.error")
            case .nafathUnavailable:
                return L10n.t("error.nafathUnavailable")
            case .nothingToWithdraw:
                return L10n.t("error.nothingToWithdraw")
            case .unknownReaction: return L10n.t("reaction.error.unknown")
            case .ownPost: return L10n.t("reaction.error.ownPost")
            case .tooManyCohosts: return L10n.t("rooms.cohosts.error.tooMany")
            case .alreadyHost: return L10n.t("rooms.cohosts.error.alreadyHost")
            case .ownQuestion: return L10n.t("rooms.questions.error.own")
            case .pollOpen: return L10n.t("rooms.polls.error.open")
            case .roomNotLive: return L10n.t("rooms.chat.error.notLive")
            case .termTooShort: return L10n.t("mutedTerms.error.tooShort")
            case .tooManyTerms: return L10n.t("mutedTerms.error.tooMany")
            case .guidelinesChanged: return L10n.t("guidelines.error.changed")
            case .invalidTime: return L10n.t("events.error.time")
            case .invalidVenue: return L10n.t("events.error.venue")
            case .tooManyUpcoming: return L10n.t("events.error.tooMany")
            case .eventFull: return L10n.t("events.full")
            case .eventOver: return L10n.t("events.error.over")
            case .eventNotShareable: return L10n.t("events.error.notShareable")
            case .selfVerificationRequired: return L10n.t("vouch.error.selfVerificationRequired")
            case .recipientCannotMessage: return L10n.t("vouch.error.recipientCannotMessage")
            case .tooManyMentions: return L10n.t("vouch.error.tooManyMentions")
            case .notVerified: return L10n.t("vouch.error.notVerified")
            case .vouchingNotOpen: return L10n.t("vouch.refusal.notOpen")
            case .vouchUnavailable: return L10n.t("vouch.refusal.unavailable")
            case .vouchPrivilegeRevoked: return L10n.t("vouch.refusal.revoked")
            case .vouchTooNew: return L10n.t("vouch.refusal.tooNew.plain", SLFormat.number(30))
            case .vouchSlotsFull: return L10n.t("vouch.error.slotsFull")
            case .vouchRateLimited: return L10n.t("vouch.refusal.rateLimited")
            case .attestationsRequired: return L10n.t("vouch.error.attestationsRequired")
            case .inviteUnavailable: return L10n.t("vouch.claim.unavailable.title")
            case .inviteNotFound: return L10n.t("vouch.error.inviteNotFound")
            case .inviteClaimed: return L10n.t("vouch.error.inviteClaimed")
            case .alreadyVouched: return L10n.t("vouch.error.alreadyVouched")
            case .vouchLifetimeReached: return L10n.t("vouch.error.lifetimeReached")
            case .vouchTooSoon: return L10n.t("vouch.error.tooSoon")
            case .vouchNotEligible: return L10n.t("vouch.error.notEligible")
            case .vouchNotFound: return L10n.t("vouch.error.notFound")
            case .notPending: return L10n.t("vouch.error.notPending")
            case .notLive: return L10n.t("vouch.error.notLive")
            case .confirmWindowPassed: return L10n.t("vouch.error.confirmWindowPassed")
            case .voucheeGone: return L10n.t("vouch.error.voucheeGone")
            case .noSummons: return L10n.t("vouch.error.noSummons")
            case .summonsClosed: return L10n.t("vouch.error.summonsClosed")
            case .invalidAction: return L10n.t("common.somethingWentWrong")
            case .detailsRequired: return L10n.t("vouch.error.detailsRequired")
            case .invalidFullName: return L10n.t("vouch.error.invalidFullName")
            case .vouchUnderAge: return L10n.t("vouch.error.underAge")
            case .detailsMismatch: return L10n.t("vouch.error.detailsMismatch")
            case .inviteClosed: return L10n.t("vouch.error.inviteClosed")
            case .videoNotAllowed, .videoProcessingFailed:
                // Worded from `reason` / `failure_code` as the error was read
                // off the wire; the fallback is the likelier of the two.
                if code == .videoNotAllowed {
                    return message.isEmpty ? L10n.t("video.error.notVerified") : message
                }
                return message.isEmpty ? L10n.t("video.error.processingFailed") : message
            case .videoTooLong: return L10n.t("video.error.tooLong")
            case .videoTooLarge: return L10n.t("video.error.tooLarge")
            case .videoRateLimited: return L10n.t("video.error.rateLimited")
            case .uploadExpired: return L10n.t("video.error.uploadExpired")
            case .uploadIncomplete: return L10n.t("video.error.uploadIncomplete")
            case .uploadChunkInvalid, .uploadTypeMismatch: return L10n.t("video.error.uploadFailed")
            case .videoUploadUnavailable: return L10n.t("video.error.unavailable")
            case .videoNotFound: return L10n.t("video.error.notFound")
            case .invalidVideo: return L10n.t("video.error.notYours")
            case .videoUsed: return L10n.t("video.error.used")
            case .videoNotUploaded: return L10n.t("video.error.notUploaded")
            case .videoRemoved: return L10n.t("video.error.removed")
            case .videoWithMedia: return L10n.t("video.error.withMedia")
            case .roomClosed: return L10n.t("rooms.guests.allow.closed")
            case .guestsNotAllowed: return L10n.t("guest.room.refusal.guestsNotAllowed.title")
            case .guestsFull: return L10n.t("guest.room.refusal.guestsFull.title")
            case .privateHost: return L10n.t("rooms.guests.allow.private")
            case .attestationInvalid, .challengeStale, .keyUnknown, .keyExists:
                // App Attest's answers stay inside `AppAttestor`: a submission
                // goes with or without the device's signature, never stopped.
                return L10n.t("common.somethingWentWrong")
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
        case .detailsMismatch:
            return L10n.t("vouch.error.detailsMismatch")
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
        /// Present on `details_mismatch` (contract v24 §11): the *names* of
        /// the fields that differ — the same key, carrying strings.
        let mismatchedFields: [String]?
        /// Present on `details_mismatch`: tries the link has left.
        let attemptsLeft: Int?
        /// Present on `video_not_allowed` (contract v28): `not_available` or
        /// `not_verified`.
        let reason: String?
        /// Present on `video_processing_failed`: why the video failed.
        let failureCode: String?

        /// Decoded with a plain decoder (see `makeError`), so the wire's
        /// snake case is spelled out.
        private enum CodingKeys: String, CodingKey {
            case code, message, fields, reason
            case attemptsLeft = "attempts_left"
            case failureCode = "failure_code"
        }

        /// `fields` is objects on a validation error and strings on a
        /// mismatch; whichever it is, the other reading is simply empty, and
        /// neither can fail the envelope — which used to put raw JSON on
        /// screen as an HTTP error.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            code = try container.decode(String.self, forKey: .code)
            message = (try? container.decode(String.self, forKey: .message)) ?? ""
            fields = (try? container.decodeIfPresent([ValidationField].self, forKey: .fields)) ?? nil
            mismatchedFields = (try? container.decodeIfPresent([String].self, forKey: .fields)) ?? nil
            attemptsLeft = (try? container.decodeIfPresent(Int.self, forKey: .attemptsLeft)) ?? nil
            reason = (try? container.decodeIfPresent(String.self, forKey: .reason)) ?? nil
            failureCode = (try? container.decodeIfPresent(String.self, forKey: .failureCode)) ?? nil
        }
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

