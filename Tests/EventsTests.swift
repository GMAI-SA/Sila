import XCTest
@testable import Sila

private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try JSONCoding.decoder.decode(T.self, from: Data(json.utf8))
}

final class EventModelTests: XCTestCase {

    func testAnEventDecodes() throws {
        let event = try decode(SilaEvent.self, """
        {"id": "00000000-0000-4000-8000-000000000e01", "title": "Derby night", "kind": "watch_party",
         "venue_kind": "place", "venue_name": "Café Nour", "venue_address": "Olaya St", "starts_at": "2026-10-01T18:00:00Z",
         "status": "scheduled", "going_count": 3, "interested_count": 5, "max_attendees": 10, "viewer_rsvp": "going",
         "can_edit": true, "is_host": true, "cohosts": []}
        """)
        XCTAssertEqual(event.kind, .watchParty)
        XCTAssertEqual(event.whereLine, "Café Nour · Olaya St")
        XCTAssertEqual(event.viewerRSVP, .going)
        XCTAssertTrue(event.isHost)
    }

    func testAPostCarriesAnEventCardAndBadges() throws {
        let post = try decode(Post.self, """
        {"id": "00000000-0000-4000-8000-000000000001",
         "author": {"id": "00000000-0000-4000-8000-000000000101", "handle": "aziz", "display_name": "Aziz", "is_verified": true},
         "text": "", "created_at": "2026-09-23T10:00:00Z", "scope": "international",
         "author_badges": ["top_helper", "made_up"],
         "event": {"id": "00000000-0000-4000-8000-000000000e01", "title": "Derby night", "kind": "watch_party",
                   "starts_at": "2026-10-01T18:00:00Z", "status": "scheduled", "venue_kind": "room", "going_count": 4}}
        """)
        XCTAssertEqual(post.event?.goingCount, 4)
        XCTAssertEqual(RecognitionBadge.parse(post.authorBadges), [.topHelper], "unknown badges are dropped")
    }

    func testBadgeCopyNeverSaysVerified() {
        for badge in RecognitionBadge.allCases {
            XCTAssertFalse(badge.title.lowercased().contains("verified"), badge.rawValue)
            XCTAssertFalse(badge.icon.contains("checkmark"), "a badge must never look like the seal")
        }
    }

    func testEventLinksOpenInTheApp() {
        let id = UUID()
        XCTAssertEqual(DeepLink.parse(Permalink.event(id)), .event(id: id))
    }

    func testARecapDecodes() throws {
        let recap = try decode(RoomRecap.self, """
        {"room_id": "00000000-0000-4000-8000-000000000c01", "title": "AMA", "speakers": [], "duration_minutes": 48,
         "peak_listeners": 61, "total_listeners": 140, "questions_answered": 7,
         "polls": [{"question": "Again?", "total_votes": 20, "options": [{"text": "Yes", "votes": 15}, {"text": "No", "votes": 5}]}]}
        """)
        XCTAssertEqual(recap.polls.first?.options.first?.votes, 15)
        XCTAssertEqual(recap.durationMinutes, 48)
    }

    func testEventNotificationsOpenTheEvent() throws {
        let row = try decode(UserNotification.self, """
        {"id": "00000000-0000-4000-8000-000000000a01", "kind": "event_invite",
         "actor": {"id": "00000000-0000-4000-8000-000000000101", "handle": "noura", "display_name": "Noura", "is_verified": true},
         "event_id": "00000000-0000-4000-8000-000000000e01", "read": false, "created_at": "2026-09-23T10:00:00Z"}
        """)
        XCTAssertEqual(row.kind, .eventInvite)
        XCTAssertNotNil(row.eventId)
        XCTAssertTrue(row.sentence.contains("Noura"))
    }
}

@MainActor
final class EventViewModelTests: XCTestCase {

    func testCreatingNeedsATitleAFutureTimeAndAValidVenue() async {
        var created: SilaEvent?
        let verified = ComposerAuthor(handle: "aziz", countryCode: "SA", isVerified: true)
        let viewModel = CreateEventViewModel(author: verified, service: EventsServiceMock(seeded: false),
                                             onCreated: { created = $0 })
        XCTAssertNotNil(viewModel.problem, "no title yet")
        viewModel.title = "Derby night"
        viewModel.venueKind = .link
        viewModel.venueLink = "http://insecure.example"
        XCTAssertEqual(viewModel.problem, L10n.t("events.create.linkHttps"))
        viewModel.venueKind = .place
        XCTAssertEqual(viewModel.problem, L10n.t("events.create.placeName"))
        viewModel.venueName = "Café Nour"
        viewModel.hasEnd = true
        viewModel.endsAt = viewModel.startsAt.addingTimeInterval(-60)
        XCTAssertEqual(viewModel.problem, L10n.t("events.create.endBeforeStart"))
        viewModel.hasEnd = false
        XCTAssertNil(viewModel.problem)
        XCTAssertNil(viewModel.request.venueUrl, "a place carries no link")
        _ = await viewModel.create()
        XCTAssertEqual(created?.venueName, "Café Nour")
    }

    func testAnUnverifiedAccountCannotCreate() {
        let viewModel = CreateEventViewModel(author: ComposerAuthor(user: nil), service: EventsServiceMock(), onCreated: { _ in })
        viewModel.title = "Anything"
        XCTAssertEqual(viewModel.problem, L10n.t("events.create.unverified"))
    }

    func testRSVPTogglesAndTheListKeepsUp() async throws {
        let service = EventsServiceMock()
        let list = EventsViewModel(service: service)
        await list.load()
        let event = try XCTUnwrap(list.thisWeek.first)
        let detail = EventDetailViewModel(eventId: event.id, service: service, onChange: { list.merge($0) })
        await detail.load()
        await detail.answer(.going)
        XCTAssertEqual(detail.event?.viewerRSVP, .going)
        XCTAssertEqual(detail.event?.goingCount, event.goingCount + 1)
        XCTAssertEqual(list.upcoming.first?.viewerRSVP, .going)
        await detail.answer(.going)
        XCTAssertNil(detail.event?.viewerRSVP, "tapping the same answer clears it")
    }

    func testAHostCancelsAndTheEventLeavesTheList() async throws {
        let service = EventsServiceMock(seeded: false)
        let made = try await service.create(CreateEventViewModel(author: ComposerAuthor(handle: "aziz", countryCode: "SA", isVerified: true),
                                                                 service: service, onCreated: { _ in }).requestWith(title: "Game night"))
        let list = EventsViewModel(service: service)
        await list.load()
        XCTAssertEqual(list.upcoming.count, 1)
        let detail = EventDetailViewModel(eventId: made.id, service: service, onChange: { list.merge($0) })
        await detail.load()
        await detail.cancel()
        XCTAssertEqual(detail.event?.status, .cancelled)
        XCTAssertTrue(list.upcoming.isEmpty)
    }
}

extension CreateEventViewModel {
    fileprivate func requestWith(title: String) -> CreateEventRequest {
        self.title = title
        return request
    }
}
