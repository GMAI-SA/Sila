import Foundation
import Observation

/// Why the rooms list is showing nothing.
///
/// Four different situations get four different sentences. A single generic
/// empty state would leave somebody unable to tell "nobody is talking right
/// now" from "your connection is down", which are opposite problems.
public enum RoomsEmptyKind: Equatable, Sendable {
    /// There is something on screen.
    case none
    /// Nothing is live and nothing is scheduled.
    case noRooms
    /// A search ran and matched nothing.
    case noMatches(String)
    /// One character typed; the server wants two.
    case queryTooShort
    /// The request failed; the message is already user-safe.
    case failed(String)
}

/// Drives ``RoomsScreen``: the live list, the scheduled list, and search.
///
/// Two rules shape it.
///
/// **Nothing about who may speak is decided here.** A row shows the server's
/// ``VoiceRoom/canSpeak`` and, when it is `false`, the server's own
/// ``VoiceRoom/speakRefusal`` — verbatim. This type never inspects a scope
/// against a country to work out an answer it was already given, because two
/// implementations of the scope rule is one of them being wrong.
///
/// **The list is never filtered by whether somebody may speak.** Every room is
/// open to every listener, so a room the viewer cannot speak in still belongs
/// on the list exactly as prominently as one they can. Hiding it would turn a
/// speaking rule into a visibility rule, which is a different product.
@MainActor
@Observable
public final class RoomsViewModel {

    /// Rooms that are live now, newest first.
    public private(set) var live: [VoiceRoom] = []
    /// Rooms with a start time in the future, soonest first.
    public private(set) var scheduled: [VoiceRoom] = []
    /// Search results, when a query is running.
    public private(set) var results: [VoiceRoom] = []
    /// What is in the search field.
    public private(set) var query = ""
    /// `true` during the first load.
    public private(set) var isLoading = false
    /// `true` during pull-to-refresh.
    public private(set) var isRefreshing = false
    /// `true` while a search is in flight.
    public private(set) var isSearching = false
    /// `true` once a load has finished, successfully or not.
    public private(set) var hasLoaded = false
    /// Why the list could not load. Already user-safe.
    public private(set) var loadError: String?
    /// The room whose join is in flight, if any.
    public private(set) var openingId: UUID?
    /// Banner message.
    public var toast: SLToastMessage?

    private let service: RoomsServiceProtocol
    private let analytics: AnalyticsClient
    private let suspension: SuspensionMonitor?
    private let debounce: TimeInterval
    private var searchTask: Task<Void, Never>?

    /// - Parameters:
    ///   - service: Rooms backend.
    ///   - analytics: Event sink.
    ///   - suspension: Where `403 account_suspended` goes.
    ///   - debounce: Seconds to wait after a keystroke. Tests pass a tiny value.
    public init(
        service: RoomsServiceProtocol,
        analytics: AnalyticsClient,
        suspension: SuspensionMonitor? = nil,
        debounce: TimeInterval = RoomConstants.searchDebounce
    ) {
        self.service = service
        self.analytics = analytics
        self.suspension = suspension
        self.debounce = debounce
    }

    // MARK: - Derived state

    /// `true` when the search field has something worth showing results for.
    public var isSearchActive: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The rows currently on screen — results while searching, live otherwise.
    public var visibleLive: [VoiceRoom] { isSearchActive ? results : live }

    /// The scheduled section, which search folds into its single result list.
    public var visibleScheduled: [VoiceRoom] { isSearchActive ? [] : scheduled }

    /// Why there is nothing on screen, when there is nothing.
    public var emptyKind: RoomsEmptyKind {
        if let loadError { return .failed(loadError) }
        guard hasLoaded || isSearchActive else { return .none }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if isSearchActive {
            guard RoomConstants.isSearchable(trimmed) else { return .queryTooShort }
            guard !isSearching else { return .none }
            return results.isEmpty ? .noMatches(trimmed) : .none
        }
        return live.isEmpty && scheduled.isEmpty ? .noRooms : .none
    }

    /// Whether a specific room's join is in flight.
    public func isOpening(_ room: VoiceRoom) -> Bool { openingId == room.id }

    // MARK: - Loading

    /// Loads both sections. Safe on every appearance — it does nothing once
    /// loaded, which is what stops a tab switch from refetching over somebody's
    /// place in the list.
    public func load() async {
        guard !hasLoaded, !isLoading else { return }
        await reload()
    }

    /// Loads unconditionally — the retry and pull-to-refresh path.
    public func reload(isRefresh: Bool = false) async {
        if isRefresh { isRefreshing = true } else { isLoading = true }
        loadError = nil
        defer {
            isLoading = false
            isRefreshing = false
            hasLoaded = true
        }

        do {
            // Two calls rather than one unfiltered fetch: `status` is the
            // server's own predicate, and splitting a mixed page on the client
            // would show "the scheduled ones out of the thirty I happen to
            // have" while calling it Scheduled.
            async let liveRooms = service.fetchRooms(status: .live, topic: nil, limit: RoomConstants.defaultLimit)
            async let scheduledRooms = service.fetchRooms(
                status: .scheduled, topic: nil, limit: RoomConstants.defaultLimit
            )
            live = try await liveRooms
            scheduled = try await scheduledRooms.sorted { lhs, rhs in
                // Soonest first. A scheduled room with no time sorts last:
                // there is nothing to count down to.
                switch (lhs.scheduledFor, rhs.scheduledFor) {
                case let (left?, right?): return left < right
                case (nil, _?): return false
                case (_?, nil): return true
                case (nil, nil): return lhs.createdAt > rhs.createdAt
                }
            }
        } catch {
            guard suspension?.notice(error) != true else { return }
            live = []
            scheduled = []
            loadError = APIError.wrapping(error).userMessage
        }
    }

    // MARK: - Search

    /// Handles a keystroke, debouncing the network call.
    /// - Parameters:
    ///   - query: The field's new contents.
    ///   - immediately: Skips the debounce (a submit).
    public func updateQuery(_ query: String, immediately: Bool = false) {
        self.query = query
        searchTask?.cancel()

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = []
            isSearching = false
            return
        }
        guard RoomConstants.isSearchable(trimmed) else {
            results = []
            isSearching = false
            return
        }

        isSearching = true
        searchTask = Task { [weak self, debounce] in
            if !immediately, debounce > 0 {
                try? await Task.sleep(nanoseconds: UInt64(debounce * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }
            await self?.performSearch(trimmed)
        }
    }

    /// Empties the field and returns to the two lists.
    public func clearSearch() {
        updateQuery("")
    }

    private func performSearch(_ trimmed: String) async {
        defer { isSearching = false }
        do {
            let found = try await service.searchRooms(query: trimmed, limit: RoomConstants.searchLimit)
            guard !Task.isCancelled else { return }
            results = found
        } catch {
            guard !Task.isCancelled else { return }
            guard suspension?.notice(error) != true else { return }
            results = []
            toast = .error(APIError.wrapping(error).userMessage)
        }
    }

    // MARK: - Opening a room

    /// Joins a room and hands back everything the room screen needs.
    ///
    /// The join happens **here**, before the screen is pushed, for one reason:
    /// the two refusals — removed from this room, and the room has ended — are
    /// facts about entering, and a room screen that appeared and then explained
    /// it could not connect would be a worse way to say the same thing. Both
    /// come back as a toast against the row that was tapped.
    ///
    /// - Returns: The join, or `nil` when there is nothing to open.
    public func open(_ room: VoiceRoom) async -> RoomJoin? {
        guard openingId == nil else { return nil }

        // A scheduled room is not joinable yet, and the server would say so.
        // Saying it here costs nothing and is faster than a round trip.
        guard room.status.isJoinable else {
            toast = .info(
                room.status == .scheduled ? RoomCopy.notLiveYet(room) : RoomCopy.roomEnded
            )
            return nil
        }

        openingId = room.id
        defer { openingId = nil }

        do {
            return try await service.join(roomId: room.id)
        } catch {
            guard suspension?.notice(error) != true else { return nil }
            let wrapped = APIError.wrapping(error)
            if wrapped.code == .removedFromRoom {
                analytics.track(.roomJoinRefusedRemoved)
                // The removal sentence, which is deliberately not a block's.
                toast = .warning(RoomCopy.removedFromRoom)
            } else if wrapped.code == .roomEnded || wrapped.code == .notFound {
                toast = .info(RoomCopy.roomEnded)
                // The row is stale by definition, so it goes rather than
                // sitting there inviting a second identical failure.
                remove(room.id)
            } else {
                toast = .error(wrapped.userMessage)
            }
            return nil
        }
    }

    /// Puts a freshly-created room at the top of the live list.
    ///
    /// Called by the create sheet so a room somebody just opened is on screen
    /// before any refresh — and lands in the right section, because a scheduled
    /// room is not live however recently it was made.
    public func insert(_ room: VoiceRoom) {
        remove(room.id)
        switch room.status {
        case .live:
            live.insert(room, at: 0)
        case .scheduled:
            scheduled.insert(room, at: 0)
        case .ended, .unknown:
            break
        }
    }

    /// Replaces a room wherever it is held, and moves it between sections when
    /// its status changed — which is what an ended room does.
    public func merge(_ room: VoiceRoom) {
        remove(room.id)
        insert(room)
    }

    /// Drops a room from both lists.
    public func remove(_ id: UUID) {
        live.removeAll { $0.id == id }
        scheduled.removeAll { $0.id == id }
        results.removeAll { $0.id == id }
    }
}
