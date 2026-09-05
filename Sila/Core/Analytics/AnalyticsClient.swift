import Foundation
import os

/// The mockable seam for product analytics.
///
/// Phase 1 ships the no-op / logging implementation only; a real provider can
/// be dropped in later without touching a single call site.
public protocol AnalyticsClient: Sendable {
    /// Records a named event with optional string properties.
    func track(_ event: AnalyticsEvent, properties: [String: String])
}

extension AnalyticsClient {
    /// Records an event with no properties.
    public func track(_ event: AnalyticsEvent) {
        track(event, properties: [:])
    }
}

/// Events emitted by Phases 1 and 3.
public enum AnalyticsEvent: String, Sendable {
    case appLaunched = "app_launched"
    case registerSubmitted = "register_submitted"
    case otpRequested = "otp_requested"
    case otpVerified = "otp_verified"
    case signInSucceeded = "sign_in_succeeded"
    case signInFailed = "sign_in_failed"
    case biometricSignIn = "biometric_sign_in"
    case signedOut = "signed_out"
    case verificationWallShown = "verification_wall_shown"
    case verificationStarted = "verification_started"
    case appealOpened = "appeal_opened"

    // MARK: Phase 2 — Nafath identity verification
    //
    // None of these events may ever carry the national ID — not as a property,
    // not hashed, not truncated. `NafathPrivacyTests` asserts it.

    /// `POST /verification/nafath/start` succeeded and a request now exists.
    case nafathStarted = "nafath_started"
    /// The poll reached `approved`.
    case nafathApproved = "nafath_approved"
    /// The poll reached `rejected`. Carries no reason text — the reason is the
    /// server's copy about a person's identity, not telemetry.
    case nafathRejected = "nafath_rejected"
    /// The request ran out before Nafath answered.
    case nafathExpired = "nafath_expired"
    /// The start call was refused. Carries `code` — the structured error code
    /// only, never anything the user typed.
    case nafathStartRefused = "nafath_start_refused"

    // MARK: Settings

    /// The in-app language changed. Carries `language`: `system`, `en` or `ar`.
    case languageChanged = "language_changed"

    // MARK: Phase 3 — Feed

    case feedTabSelected = "feed_tab_selected"
    case feedLoaded = "feed_loaded"
    case postOpened = "post_opened"
    case postLiked = "post_liked"
    case postUnliked = "post_unliked"
    case postReposted = "post_reposted"
    case postUnreposted = "post_unreposted"
    case postBookmarked = "post_bookmarked"
    case postUnbookmarked = "post_unbookmarked"
    case postShared = "post_shared"
    case replyBlocked = "reply_blocked"
    /// A screen that belongs to a later phase told the user so.
    case featureStubShown = "feature_stub_shown"

    // MARK: Phase 4 — Composer

    /// The composer sheet was presented.
    case composerOpened = "composer_opened"
    /// A thread segment was added.
    case composerSegmentAdded = "composer_segment_added"
    /// The audience was changed.
    case composerScopeSelected = "composer_scope_selected"
    /// A handle was picked from the mention list.
    case composerMentionInserted = "composer_mention_inserted"
    /// A draft was thrown away.
    case composerDiscarded = "composer_discarded"
    /// One post reached the server (emitted by the service, per post).
    case postCreated = "post_created"
    /// An image was uploaded for a post (emitted by the service). Carries only
    /// its size — never the image, and never who it was of.
    case postImageUploaded = "post_image_uploaded"
    case postDeleted = "post_deleted"
    /// A composition finished, counting every segment that got through.
    case postPublished = "post_published"
    /// A thread stopped partway, leaving real posts behind.
    case postPartiallyFailed = "post_partially_failed"
    /// Nothing was posted.
    case postFailed = "post_failed"

    // MARK: Phase 4 — Search & Explore

    /// A search query ran.
    case searchPerformed = "search_performed"
    /// A trending tag was tapped.
    case trendingTagOpened = "trending_tag_opened"

    // MARK: Contract v4 — feed preferences

    /// The preferences screen was opened.
    case preferencesOpened = "preferences_opened"
    /// The taxonomy and stored preferences arrived.
    case preferencesLoaded = "preferences_loaded"
    /// The server accepted a write (emitted by the service).
    case preferencesSaved = "preferences_saved"
    /// A write was rejected and the edits were kept on screen.
    case preferencesSaveFailed = "preferences_save_failed"
    /// One topic's stance changed in the draft.
    case topicStanceChanged = "topic_stance_changed"

    // MARK: Contract v5 — account management

    /// Account settings were opened.
    case accountOpened = "account_opened"
    /// `GET /me/account` came back.
    case accountLoaded = "account_loaded"
    /// The server accepted a profile write.
    case accountProfileSaved = "account_profile_saved"
    /// A picture was stored.
    case accountAvatarUploaded = "account_avatar_uploaded"
    /// A picture was deleted.
    case accountAvatarRemoved = "account_avatar_removed"
    /// A picture was refused **by the client**, before any upload.
    case accountAvatarRejected = "account_avatar_rejected"
    /// The password was replaced.
    case accountPasswordChanged = "account_password_changed"
    /// A code was sent to a new address.
    case accountEmailChangeRequested = "account_email_change_requested"
    /// A new address was confirmed.
    case accountEmailChanged = "account_email_changed"
    /// The contact number was set or cleared.
    case accountPhoneChanged = "account_phone_changed"
    /// A data export was downloaded.
    case accountExported = "account_exported"
    /// Deletion was scheduled.
    case accountDeletionRequested = "account_deletion_requested"
    /// A pending deletion was called off.
    case accountDeletionCancelled = "account_deletion_cancelled"
    /// The recovery screen was routed to, and why.
    ///
    /// Carries `source`: `403` (a call was refused), `loaded` (the account came
    /// back already pending) or `requested` (the user just asked for deletion).
    /// Worth separating: a spike in `403` means people are hitting the wall
    /// somewhere they should not have been able to.
    case accountDeletionRouted = "account_deletion_routed"

    // MARK: Phase 7 — Profiles

    /// A profile screen was opened and its header arrived.
    case profileOpened = "profile_opened"
    /// `GET /users/{handle}` came back (emitted by the service).
    case profileLoaded = "profile_loaded"
    /// A handle resolved to nothing — an unknown or deactivated account.
    ///
    /// Worth its own event: a rise here usually means stale links or handles
    /// being rendered somewhere the account has already gone.
    case profileUnavailable = "profile_unavailable"
    /// A follow was stored.
    case followAdded = "follow_added"
    /// A follow was removed.
    case followRemoved = "follow_removed"
    /// A follow or unfollow was refused, and the button was put back.
    case followFailed = "follow_failed"

    // MARK: Safety — block, mute, report, suspension

    /// The `…` menu was opened on a post or a profile.
    case safetyMenuOpened = "safety_menu_opened"
    /// The block confirmation was put on screen. **Not** a block: the gap
    /// between this and ``blockAdded`` is how many people read the consequences
    /// and changed their mind, which is the number that says whether the copy
    /// is doing its job.
    case blockConfirmationShown = "block_confirmation_shown"
    /// The block confirmation was dismissed without blocking.
    case blockCancelled = "block_cancelled"
    /// A block was stored (emitted by the service).
    case blockAdded = "block_added"
    /// A block was lifted.
    case blockRemoved = "block_removed"
    /// A mute was stored.
    case muteAdded = "mute_added"
    /// A mute was lifted.
    case muteRemoved = "mute_removed"
    /// A block or mute was refused, and the UI was put back.
    case safetyActionFailed = "safety_action_failed"
    /// The report sheet was opened.
    case reportOpened = "report_opened"
    /// A reason was picked in the report sheet.
    case reportReasonSelected = "report_reason_selected"
    /// A report reached the server (emitted by the service). Carries the reason
    /// and whether support resources came back — never the free text.
    case reportSubmitted = "report_submitted"
    /// A report was refused by the server.
    case reportFailed = "report_failed"
    /// The care-first outcome was shown instead of a receipt.
    ///
    /// Worth its own event: it is the one screen whose absence would be a
    /// product failure nobody would otherwise notice.
    case reportSupportShown = "report_support_shown"
    /// The safety lists were opened from settings.
    case safetyListsOpened = "safety_lists_opened"
    /// The app routed to the suspension screen, and why.
    ///
    /// Carries `source`: `403` (a call was refused) or `loaded`
    /// (`GET /me/suspension` said so). A spike in `403` means people are
    /// reaching the wall somewhere they should already have been routed away
    /// from.
    case suspensionRouted = "suspension_routed"
    /// A suspension was lifted and the app let the user back in.
    case suspensionLifted = "suspension_lifted"
    /// An appeal was sent.
    case appealSubmitted = "appeal_submitted"
    /// A second appeal was refused, and the screen showed the first one instead.
    case appealAlreadyOnFile = "appeal_already_on_file"

    // MARK: Contract v10 — private accounts

    /// The owner of a private account let somebody in.
    case followRequestAccepted = "follow_request_accepted"
    /// The owner said no. Carries nothing about who — the decline is silent
    /// to the requester, and telemetry must not be the place it leaks.
    case followRequestDeclined = "follow_request_declined"

    // MARK: Contract v9 — the verification gate

    /// A call was refused `403 unverified`, and the app went back to `/auth/me`
    /// to find out where the account really stands.
    ///
    /// Carries `source`. Anything but zero of these means sessions are running
    /// on past their verification — which is legitimate (a revocation) but
    /// worth being able to see.
    case verificationGateTripped = "verification_gate_tripped"

    // MARK: Notifications

    /// A page of `GET /notifications` came back (emitted by the service).
    case notificationsLoaded = "notifications_loaded"
    /// A row was tapped. Carries the kind, whether it was already read, and
    /// whether the post behind it had been deleted — the last one is how a rise
    /// in dead-end taps would become visible.
    case notificationOpened = "notification_opened"
    /// Something was marked read (emitted by the service). Carries `scope`:
    /// `all` for the button, `ids` for a single opened row.
    case notificationsMarkedRead = "notifications_marked_read"
    /// One of the five notification switches was changed.
    case notificationPreferenceChanged = "notification_preference_changed"

    // MARK: Messages

    /// A direct message was sent (emitted by the service).
    ///
    /// Deliberately carries nothing about the message or its recipient. A
    /// private conversation whose participants show up in an analytics event is
    /// not private, whatever the body says.
    case messageSent = "message_sent"
    /// A request was accepted, moving a stranger's thread into the inbox.
    case messageRequestAccepted = "message_request_accepted"
    /// The conversation list was opened. Carries `folder`: `inbox` or `requests`.
    case messagesOpened = "messages_opened"

    // MARK: Voice rooms

    /// A page of `GET /rooms` came back (emitted by the service).
    case roomsLoaded = "rooms_loaded"
    /// A room search ran.
    case roomsSearched = "rooms_searched"
    /// A room was opened (emitted by the service).
    case roomCreated = "room_created"
    /// A join succeeded. Carries `role` and `can_speak` — **never the token.**
    case roomJoined = "room_joined"
    /// `POST /leave` succeeded.
    case roomLeft = "room_left"
    /// A host ended their room.
    case roomEnded = "room_ended"
    /// The microphone was turned on. Carries `role`, which is the only thing
    /// that should ever make this possible.
    case roomMicEnabled = "room_mic_enabled"
    /// The microphone was turned off.
    case roomMicDisabled = "room_mic_disabled"
    /// iOS refused microphone access, so the person kept listening instead.
    case roomMicDenied = "room_mic_denied"
    /// Somebody was invited onto the stage.
    case roomSpeakerPromoted = "room_speaker_promoted"
    /// Somebody was moved back to the audience. **Not** a removal.
    case roomSpeakerDemoted = "room_speaker_demoted"
    /// Somebody was removed from one room. Per-room; not a block, and this
    /// event must never be read as one.
    case roomParticipantRemoved = "room_participant_removed"
    /// A join was refused because the viewer had been removed from that room.
    case roomJoinRefusedRemoved = "room_join_refused_removed"
    /// The media connection dropped or failed. Carries `state`.
    case roomMediaFailed = "room_media_failed"
}

/// Default ``AnalyticsClient``: writes to the unified log in debug and does
/// nothing in release. No network, no third party.
public struct ConsoleAnalyticsClient: AnalyticsClient {

    public init() {}

    public func track(_ event: AnalyticsEvent, properties: [String: String]) {
        #if DEBUG
        let logger = Logger(subsystem: "com.socialsa.sila", category: "analytics")
        if properties.isEmpty {
            logger.debug("event=\(event.rawValue, privacy: .public)")
        } else {
            let rendered = properties
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: " ")
            logger.debug("event=\(event.rawValue, privacy: .public) \(rendered, privacy: .public)")
        }
        #endif
    }
}

/// ``AnalyticsClient`` that records events in memory so tests can assert on them.
public final class RecordingAnalyticsClient: AnalyticsClient, @unchecked Sendable {

    private var storage: [(event: AnalyticsEvent, properties: [String: String])] = []
    private let lock = NSLock()

    public init() {}

    /// Every event tracked so far, in order.
    public var events: [AnalyticsEvent] {
        lock.lock(); defer { lock.unlock() }
        return storage.map(\.event)
    }

    /// Every event with its properties, in order — for tests that assert on
    /// what was (or, for PII, was **not**) attached to an event.
    public var recorded: [(event: AnalyticsEvent, properties: [String: String])] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    public func track(_ event: AnalyticsEvent, properties: [String: String]) {
        lock.lock(); defer { lock.unlock() }
        storage.append((event, properties))
    }
}
