import Foundation
import Observation

/// Drives ``CreateRoomSheet``.
///
/// Two things it deliberately does not own.
///
/// **The scope rules.** ``ScopePicker`` already decides which audiences an
/// author may open, and it decides it the same way for a post and for a room:
/// International is always available, "My Country" may only ever name the
/// author's *own* verified country, and a region needs a badge from inside it.
/// Reusing it is not code-sharing for its own sake — the alternative is two
/// implementations of one rule, drifting.
///
/// **The topic list.** The taxonomy comes from `GET /topics` through
/// ``PreferencesServiceProtocol``, the same twenty the feed preferences screen
/// shows. A hard-coded copy would go stale the day the server's list moves, and
/// the failure mode is `unknown_topic` on a room somebody just spent a minute
/// naming.
@MainActor
@Observable
public final class CreateRoomViewModel {

    /// The room's title.
    public var title = "" {
        didSet { if titleError != nil { titleError = nil } }
    }
    /// The chosen topic id, or `nil` for none.
    public private(set) var topic: String?
    /// The chosen audience — who may **speak**.
    public private(set) var scope: ComposeScope
    /// Whether the room is being scheduled rather than opened now.
    public var isScheduled = false
    /// When a scheduled room starts.
    public var scheduledFor = Date().addingTimeInterval(60 * 60)
    /// How many people fit on the stage.
    public var maxSpeakers = RoomConstants.defaultSpeakerLimit

    /// The taxonomy, once it has arrived.
    public private(set) var topics: [TopicOption] = []
    /// `true` while the taxonomy is loading.
    public private(set) var isLoadingTopics = false
    /// `true` while the room is being created.
    public private(set) var isCreating = false
    /// What is wrong with the title, when something is.
    public private(set) var titleError: String?
    /// Why creation failed. Already user-safe.
    public private(set) var createError: String?
    /// Banner message.
    public var toast: SLToastMessage?

    /// Who is opening the room. Drives the scope picker's availability.
    public let author: ComposerAuthor

    private let service: RoomsServiceProtocol
    private let preferences: PreferencesServiceProtocol
    private let analytics: AnalyticsClient
    private let suspension: SuspensionMonitor?
    private let onCreated: (@MainActor (VoiceRoom) -> Void)?

    /// - Parameters:
    ///   - author: The signed-in account, as the scope picker understands it.
    ///   - service: Rooms backend.
    ///   - preferences: Supplies the topic taxonomy — the same `GET /topics`
    ///     the feed preferences screen reads.
    ///   - analytics: Event sink.
    ///   - suspension: Where `403 account_suspended` goes.
    ///   - onCreated: Called with the created room, so the list behind the
    ///     sheet shows it without waiting for a refresh.
    public init(
        author: ComposerAuthor,
        service: RoomsServiceProtocol,
        preferences: PreferencesServiceProtocol,
        analytics: AnalyticsClient,
        suspension: SuspensionMonitor? = nil,
        onCreated: (@MainActor (VoiceRoom) -> Void)? = nil
    ) {
        self.author = author
        self.service = service
        self.preferences = preferences
        self.analytics = analytics
        self.suspension = suspension
        self.onCreated = onCreated
        self.scope = ScopePicker.defaultScope(for: author)
    }

    // MARK: - Derived state

    /// The audience rows, unavailable ones included and explained.
    public var scopeOptions: [ScopeOption] { ScopePicker.options(for: author) }

    /// `true` when the account may open a room at all.
    ///
    /// Reading is open to everyone and so is *listening*; hosting is not.
    public var canHost: Bool { author.isVerified }

    /// How many characters are left in the title.
    public var remainingTitleCharacters: Int {
        RoomConstants.maximumTitleLength - trimmedTitle.count
    }

    /// `true` when the create button should be live.
    public var canCreate: Bool {
        canHost
            && !isCreating
            && !trimmedTitle.isEmpty
            && remainingTitleCharacters >= 0
            && ScopePicker.isAvailable(scope, for: author)
    }

    /// The chosen topic as a readable label, or `nil`.
    public var topicLabel: String? {
        guard let topic else { return nil }
        return topics.first { $0.id == topic }?.label ?? TopicOption.makeLabel(from: topic)
    }

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Loading

    /// Fetches the taxonomy. Safe on every appearance.
    ///
    /// A failure is quiet and leaves the picker empty rather than blocking the
    /// sheet: a room with no topic is a perfectly good room, and refusing to
    /// let somebody open one because a list of labels did not arrive would be
    /// the client inventing a requirement the server does not have.
    public func loadTopics() async {
        guard topics.isEmpty, !isLoadingTopics else { return }
        isLoadingTopics = true
        defer { isLoadingTopics = false }
        topics = (try? await preferences.fetchTopics()) ?? []
    }

    // MARK: - Editing

    /// Picks a topic, or clears it by picking the same one again.
    public func select(topic id: String?) {
        topic = (topic == id) ? nil : id
    }

    /// Picks an audience, or explains why one is not available.
    ///
    /// An unavailable row is **selectable** — tapping it says why. Silently
    /// ignoring the tap would leave somebody unsure whether the app registered
    /// it, and the reason is the whole argument for verifying an identity.
    public func select(_ option: ScopeOption) {
        guard option.isAvailable else {
            toast = .info(option.unavailableReason ?? L10n.t("rooms.create.audienceUnavailable"))
            return
        }
        scope = option.scope
        analytics.track(.composerScopeSelected, properties: [
            "surface": "room",
            "scope": option.scope.wireValue
        ])
    }

    // MARK: - Creating

    /// Opens the room.
    ///
    /// - Returns: The created room, or `nil` when nothing was created.
    public func create() async -> VoiceRoom? {
        guard canHost else {
            createError = RoomCopy.unverifiedCannotOpen
            return nil
        }
        guard !trimmedTitle.isEmpty else {
            titleError = RoomCopy.titleMissing
            return nil
        }
        guard remainingTitleCharacters >= 0 else {
            titleError = RoomCopy.titleTooLong(trimmedTitle.count)
            return nil
        }
        guard !isCreating else { return nil }

        isCreating = true
        createError = nil
        defer { isCreating = false }

        do {
            let room = try await service.createRoom(
                CreateRoomRequest(
                    title: trimmedTitle,
                    topic: topic,
                    scope: scope,
                    // Only sent when the switch is on. A `scheduled_for` in the
                    // past would be the client asking the server to open a room
                    // retroactively, which is not a thing.
                    scheduledFor: isScheduled ? scheduledFor : nil,
                    maxSpeakers: maxSpeakers
                )
            )
            onCreated?(room)
            return room
        } catch {
            guard suspension?.notice(error) != true else { return nil }
            createError = APIError.wrapping(error).userMessage
            return nil
        }
    }
}
