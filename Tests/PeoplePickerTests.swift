import XCTest
@testable import Sila

/// The picker: the people you know, first; everybody else by search; ticks.
final class PeoplePickerTests: XCTestCase {

    private struct StubDirectory: PeopleDirectory {
        var known: [UserSummary]
        var found: [UserSummary]
        func knownPeople(of viewerHandle: String) async throws -> [UserSummary] { known }
        func search(_ query: String) async throws -> [UserSummary] { found }
    }

    private static func person(_ handle: String, _ name: String) -> UserSummary {
        UserSummary(id: UUID(), handle: handle, displayName: name, isVerified: true)
    }

    @MainActor
    func testKnownPeopleLoadWithoutThoseAlreadyIn() async {
        let directory = StubDirectory(known: [Self.person("noura", "Noura"), Self.person("faisal", "Faisal")], found: [])
        let viewModel = PeoplePickerViewModel(directory: directory, viewerHandle: "aziz", excluding: ["@Faisal"])
        await viewModel.load()
        XCTAssertEqual(viewModel.visibleKnown.map(\.handle), ["noura"])
    }

    @MainActor
    func testTypingFiltersTheKnownAndSearchesTheRest() async {
        let directory = StubDirectory(
            known: [Self.person("noura", "Noura"), Self.person("faisal", "Faisal")],
            found: [Self.person("noura", "Noura"), Self.person("nawaf", "Nawaf"), Self.person("aziz", "Aziz")]
        )
        let viewModel = PeoplePickerViewModel(directory: directory, viewerHandle: "aziz")
        await viewModel.load()
        viewModel.query = "n"
        await viewModel.search()
        XCTAssertEqual(viewModel.visibleKnown.map(\.handle), ["noura"])
        XCTAssertEqual(viewModel.more, [])  // one character searches nothing

        viewModel.query = "na"
        await viewModel.search()
        // Known people are not repeated under "more", and the viewer never appears.
        XCTAssertEqual(viewModel.more.map(\.handle), ["nawaf"])
    }

    @MainActor
    func testTicksAreKeptAcrossQueriesAndComeBackAsPeople() async {
        let directory = StubDirectory(known: [Self.person("noura", "Noura"), Self.person("faisal", "Faisal")], found: [])
        let viewModel = PeoplePickerViewModel(directory: directory, viewerHandle: "aziz")
        await viewModel.load()
        viewModel.toggle(viewModel.known[0])
        viewModel.toggle(viewModel.known[1])
        viewModel.toggle(viewModel.known[0])
        viewModel.query = "zzz"
        XCTAssertEqual(viewModel.selectedCount, 1)
        XCTAssertEqual(viewModel.selectedPeople.map(\.handle), ["faisal"])
        XCTAssertTrue(viewModel.isSelected(viewModel.known[1]))
    }

    func testTheDirectoryMergesBothListsSortedAndWithoutTheViewer() async throws {
        final class Lists: ProfileServiceProtocol, @unchecked Sendable {
            func fetchProfile(handle: String) async throws -> Profile { throw APIError.transport("no") }
            func fetchPosts(handle: String, cursor: String?, limit: Int) async throws -> FeedPage { .empty }
            func setFollowing(_ following: Bool, handle: String) async throws -> FollowResult { throw APIError.transport("no") }
            func fetchFollowRequests() async throws -> [FollowRequest] { [] }
            func answerFollowRequest(handle: String, accept: Bool) async throws {}
            func fetchFollowers(handle: String, cursor: String?) async throws -> FollowListPage {
                FollowListPage(items: [FollowRow(user: PeoplePickerTests.person("yuki", "Yuki")), FollowRow(user: PeoplePickerTests.person("aziz", "Aziz"))])
            }
            func fetchFollowing(handle: String, cursor: String?) async throws -> FollowListPage {
                FollowListPage(items: [FollowRow(user: PeoplePickerTests.person("noura", "Noura")), FollowRow(user: PeoplePickerTests.person("yuki", "Yuki"))])
            }
        }
        let directory = KnownPeopleDirectory(profile: Lists(), search: SearchServiceMock(scenario: .empty))
        let people = try await directory.knownPeople(of: "@Aziz")
        XCTAssertEqual(people.map(\.handle), ["noura", "yuki"])
    }

    @MainActor
    func testCreatingARoomJoinsTypedAndPickedGuests() {
        let viewModel = CreateRoomViewModel(
            author: ComposerAuthor(handle: "aziz", countryCode: "SA", isVerified: true),
            service: RoomsServiceMock(),
            preferences: PreferencesServiceMock(),
            analytics: RecordingAnalyticsClient()
        )
        viewModel.access = .inviteOnly
        viewModel.inviteHandlesText = "@Noura, faisal"
        viewModel.pick([Self.person("faisal", "Faisal"), Self.person("yuki", "Yuki")])
        XCTAssertEqual(viewModel.inviteHandles, ["noura", "faisal", "yuki"])
        viewModel.removeGuest("yuki")
        XCTAssertEqual(viewModel.inviteHandles, ["noura", "faisal"])
    }
}
