import Foundation
import Observation

/// Drives ``GuestRoomsScreen``: the Rooms tab for somebody without an account
/// (contract v31) — live now, then coming up, only rooms a guest may open.
///
/// The search is local: a guest's list is short, and `/search/rooms` is an
/// account's route.
@MainActor
@Observable
public final class GuestRoomsViewModel {

    /// Live rooms, once they have loaded.
    public private(set) var live: [RoomCard]?
    /// Scheduled rooms, soonest first. A failure here leaves it empty rather
    /// than failing the tab: what is live is what a guest came for.
    public private(set) var later: [RoomCard] = []
    /// Why the list could not load, in words.
    public private(set) var error: String?
    public private(set) var isLoading = false
    /// What is typed into the search field.
    public var query = ""

    private let service: GuestRoomsServiceProtocol
    private let analytics: AnalyticsClient

    public init(service: GuestRoomsServiceProtocol, analytics: AnalyticsClient) {
        self.service = service
        self.analytics = analytics
    }

    /// Loads both lists. Safe on every appearance; a refresh re-reads.
    public func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        error = nil
        async let now = service.fetchRooms(status: .live, limit: RoomConstants.defaultLimit)
        async let coming = service.fetchRooms(status: .scheduled, limit: RoomConstants.defaultLimit)
        do {
            let rooms = try await now
            live = rooms
            later = (try? await coming) ?? []
        } catch {
            _ = try? await coming
            let wrapped = APIError.wrapping(error)
            guard !wrapped.isCancellation else { return }
            self.error = wrapped.userMessage
        }
    }

    /// Loads once, on the tab's first appearance.
    public func loadIfNeeded() async {
        guard live == nil, error == nil else { return }
        await load()
    }

    // MARK: - What the tab shows

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    public var isSearching: Bool { !trimmedQuery.isEmpty }

    public var visibleLive: [RoomCard] { (live ?? []).filter(matches) }
    public var visibleLater: [RoomCard] { later.filter(matches) }

    public enum EmptyKind: Equatable {
        case none
        /// Nothing open to guests right now.
        case noRooms
        /// The search found nothing.
        case noMatches(String)
        /// One letter is not a search.
        case queryTooShort
        case failed(String)
    }

    public var emptyKind: EmptyKind {
        if let error { return .failed(error) }
        guard live != nil else { return .none }
        if isSearching {
            if !RoomConstants.isSearchable(trimmedQuery) { return .queryTooShort }
            if visibleLive.isEmpty && visibleLater.isEmpty { return .noMatches(trimmedQuery) }
            return .none
        }
        return visibleLive.isEmpty && visibleLater.isEmpty ? .noRooms : .none
    }

    private func matches(_ room: RoomCard) -> Bool {
        let needle = trimmedQuery
        guard RoomConstants.isSearchable(needle) else { return true }
        let fields = [room.title, room.topicLabel ?? "", room.host.handle, room.host.displayName, room.starterQuestion ?? ""]
        return fields.contains { $0.localizedCaseInsensitiveContains(needle) }
    }
}
