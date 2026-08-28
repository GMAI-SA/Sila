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

    public func track(_ event: AnalyticsEvent, properties: [String: String]) {
        lock.lock(); defer { lock.unlock() }
        storage.append((event, properties))
    }
}
