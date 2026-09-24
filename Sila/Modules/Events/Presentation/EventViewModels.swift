import Foundation
import Observation

/// The Events section of the Rooms tab: this week, then later.
@MainActor
@Observable
public final class EventsViewModel {
    public private(set) var upcoming: [SilaEvent] = []
    public private(set) var isLoading = false
    public private(set) var hasLoaded = false
    public private(set) var error: String?
    private let service: EventsServiceProtocol

    public init(service: EventsServiceProtocol) {
        self.service = service
    }

    public var thisWeek: [SilaEvent] {
        let limit = Date().addingTimeInterval(7 * 86_400)
        return upcoming.filter { $0.startsAt <= limit }
    }

    public var later: [SilaEvent] {
        let limit = Date().addingTimeInterval(7 * 86_400)
        return upcoming.filter { $0.startsAt > limit }
    }

    public func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false; hasLoaded = true }
        do {
            upcoming = try await service.upcoming(withinDays: 30, topic: nil)
            error = nil
        } catch {
            let wrapped = APIError.wrapping(error)
            if !wrapped.isCancellation { self.error = wrapped.userMessage }
        }
    }

    public func insert(_ event: SilaEvent) {
        upcoming.removeAll { $0.id == event.id }
        upcoming.append(event)
        upcoming.sort { $0.startsAt < $1.startsAt }
    }

    public func merge(_ event: SilaEvent) {
        guard let i = upcoming.firstIndex(where: { $0.id == event.id }) else { return }
        if event.isOver { upcoming.remove(at: i) } else { upcoming[i] = event }
    }
}

/// One event: RSVP, the guest list, and for its hosts edit, cancel, share,
/// invite and co-hosts.
@MainActor
@Observable
public final class EventDetailViewModel {
    public private(set) var event: SilaEvent?
    public private(set) var going: [UserSummary] = []
    public private(set) var interested: [UserSummary] = []
    public private(set) var isLoading = false
    public private(set) var isBusy = false
    public var toast: SLToastMessage?
    public var isConfirmingCancel = false
    public let eventId: UUID
    private let service: EventsServiceProtocol
    private let onChange: @MainActor (SilaEvent) -> Void

    public init(eventId: UUID, initial: SilaEvent? = nil, service: EventsServiceProtocol,
                onChange: @escaping @MainActor (SilaEvent) -> Void = { _ in }) {
        self.eventId = eventId
        self.event = initial
        self.service = service
        self.onChange = onChange
    }

    public func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let loaded = try await service.event(eventId)
            event = loaded
            async let g = service.attendees(eventId, status: .going)
            async let i = service.attendees(eventId, status: .interested)
            going = (try? await g) ?? []
            interested = (try? await i) ?? []
        } catch {
            toast = .error(for: error)
        }
    }

    /// Tapping the answer already given clears it.
    public func answer(_ status: RSVPStatus) async {
        guard let event, !event.isOver, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let updated = try await service.rsvp(event.viewerRSVP == status ? nil : status, eventId: eventId)
            self.event = updated
            onChange(updated)
            going = (try? await service.attendees(eventId, status: .going)) ?? going
        } catch {
            toast = .error(for: error)
        }
    }

    public func cancel() async {
        guard event?.isHost == true else { return }
        do {
            let updated = try await service.cancel(eventId)
            event = updated
            onChange(updated)
        } catch { toast = .error(for: error) }
    }

    public func share(text: String?) async -> Bool {
        do {
            _ = try await service.share(eventId, text: text)
            toast = .success(L10n.t("events.shared"))
            return true
        } catch {
            toast = .error(for: error)
            return false
        }
    }

    public func invite(_ handles: [String]) async {
        do {
            try await service.invite(handles, eventId: eventId)
            toast = .success(L10n.t("events.invited"))
        } catch { toast = .error(for: error) }
    }

    public func addCohost(_ handle: String) async {
        do { event = try await service.addCohosts([handle], eventId: eventId) } catch { toast = .error(for: error) }
    }

    public func removeCohost(_ handle: String) async {
        do { event = try await service.removeCohost(handle, eventId: eventId) } catch { toast = .error(for: error) }
    }

    public func reschedule(to date: Date) async {
        do {
            let updated = try await service.update(eventId, EventUpdate(startsAt: date))
            event = updated
            onChange(updated)
        } catch { toast = .error(for: error) }
    }
}

/// Creating an event: the create-room pieces plus a venue, an end, a cap.
@MainActor
@Observable
public final class CreateEventViewModel {
    public var title = ""
    public var details = ""
    public var kind: EventKind = .watchParty
    public var venueKind: EventVenueKind = .room
    public var venueLink = ""
    public var venueName = ""
    public var venueAddress = ""
    public var startsAt = Date().addingTimeInterval(24 * 3600)
    public var hasEnd = false
    public var endsAt = Date().addingTimeInterval(26 * 3600)
    public var isInviteOnly = false
    public var hasCap = false
    public var cap = 50
    public var inviteText = ""
    public private(set) var isCreating = false
    public private(set) var error: String?
    public let author: ComposerAuthor
    private let service: EventsServiceProtocol
    private let onCreated: @MainActor (SilaEvent) -> Void

    public init(author: ComposerAuthor, service: EventsServiceProtocol, onCreated: @escaping @MainActor (SilaEvent) -> Void) {
        self.author = author
        self.service = service
        self.onCreated = onCreated
    }

    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Why Create is off, or `nil` when it is on.
    public var problem: String? {
        if !author.isVerified { return L10n.t("events.create.unverified") }
        if trimmedTitle.count < 2 { return L10n.t("events.create.titleShort") }
        if startsAt <= Date() { return L10n.t("events.create.past") }
        if hasEnd, endsAt <= startsAt { return L10n.t("events.create.endBeforeStart") }
        switch venueKind {
        case .link:
            guard let url = URL(string: venueLink.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme == "https" else {
                return L10n.t("events.create.linkHttps")
            }
        case .place:
            if venueName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return L10n.t("events.create.placeName") }
        case .room:
            break
        }
        return nil
    }

    public var canCreate: Bool { problem == nil && !isCreating }

    public var request: CreateEventRequest {
        let scope = ScopePicker.defaultScope(for: author)
        let handles = inviteText.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" })
            .map { Handle.normalised(String($0)) }.filter { !$0.isEmpty }
        return CreateEventRequest(
            title: String(trimmedTitle.prefix(120)),
            description: details.isEmpty ? nil : details,
            kind: kind.rawValue,
            topic: nil,
            venueKind: venueKind.rawValue,
            venueUrl: venueKind == .link ? venueLink.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
            venueName: venueKind == .place ? venueName : nil,
            venueAddress: venueKind == .place && !venueAddress.isEmpty ? venueAddress : nil,
            startsAt: startsAt,
            endsAt: hasEnd ? endsAt : nil,
            timezone: TimeZone.current.identifier,
            scope: scope.wireValue,
            scopeCountry: scope.scopeCountry,
            scopeRegion: scope.scopeRegion,
            isInviteOnly: isInviteOnly,
            maxAttendees: hasCap ? cap : nil,
            inviteHandles: handles,
            cohostHandles: []
        )
    }

    public func create() async -> SilaEvent? {
        guard canCreate else { return nil }
        isCreating = true
        defer { isCreating = false }
        do {
            let event = try await service.create(request)
            onCreated(event)
            return event
        } catch {
            self.error = APIError.wrapping(error).presentableMessage
            return nil
        }
    }
}
