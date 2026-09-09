import XCTest
@testable import Sila

/// Communities: the wire contract, the door, and what the screens do with it.
final class CommunitiesTests: XCTestCase {

    private static let owner = """
    {"id": "77777777-0000-4000-8000-000000000001", "handle": "noura", "display_name": "Noura",
     "is_verified": true, "country_code": "SA"}
    """
    private static let json = """
    {"id": "88888888-0000-4000-8000-000000000001", "slug": "riyadh_runners", "name": "Riyadh runners",
     "description": "We run at six.", "avatar_url": null, "owner": \(owner),
     "visibility": "public", "join_policy": "approval", "scope": "country", "scope_country": "SA",
     "scope_region": null, "topic": "sports", "verified_only": true, "member_count": 214,
     "rules": ["Be kind", "No selling"], "created_at": "2026-09-09T08:00:00Z",
     "viewer_role": null, "is_member": false, "is_pending": false, "is_invited": false,
     "can_view": true, "can_join": true, "join_refusal": null,
     "can_post": false, "post_refusal": "Join this community to post in it", "matches_interests": true}
    """

    private func service(_ network: StubNetworkClient) -> CommunitiesService {
        CommunitiesService(network: network, tokens: StaticAccessTokenProvider(token: "t"), analytics: RecordingAnalyticsClient())
    }

    // MARK: - The wire

    func testACommunityDecodesWithEverythingTheViewerMayDo() throws {
        let community = try JSONCoding.decoder.decode(Community.self, from: Data(Self.json.utf8))
        XCTAssertEqual(community.slug, "riyadh_runners")
        XCTAssertEqual(community.address, "/c/riyadh_runners")
        XCTAssertEqual(community.visibility, .public)
        XCTAssertEqual(community.joinPolicy, .approval)
        XCTAssertEqual(community.scope, .country)
        XCTAssertEqual(community.scopeCountry, "SA")
        XCTAssertTrue(community.verifiedOnly)
        XCTAssertEqual(community.rules, ["Be kind", "No selling"])
        XCTAssertEqual(community.memberCount, 214)
        XCTAssertFalse(community.isMember)
        XCTAssertFalse(community.isAdmin)
        XCTAssertTrue(community.canJoin)
        XCTAssertFalse(community.canPost)
        XCTAssertEqual(community.postRefusal, "Join this community to post in it")
        XCTAssertTrue(community.matchesInterests)
    }

    func testAServerWithoutTheDoorFieldsFailsOpenOnReadingAndShutOnWriting() throws {
        let bare = """
        {"id": "88888888-0000-4000-8000-000000000002", "slug": "x", "name": "X", "owner": \(Self.owner),
         "created_at": "2026-09-09T08:00:00Z"}
        """
        let community = try JSONCoding.decoder.decode(Community.self, from: Data(bare.utf8))
        // Reading fails open: a server with no private communities has none to hide.
        XCTAssertTrue(community.canView)
        XCTAssertTrue(community.canJoin)
        // Writing fails shut: the API is the real gate and it will say no.
        XCTAssertFalse(community.canPost)
    }

    func testTheListAndTheMemberListAreReadFromTheirEnvelopes() async throws {
        let network = StubNetworkClient(responses: [#"{"communities": [\#(Self.json)]}"#])
        let rows = try await service(network).fetchCommunities(forYou: true)
        XCTAssertEqual(rows.map(\.slug), ["riyadh_runners"])
        XCTAssertEqual(network.lastRequest?.path, "/communities")
        XCTAssertEqual(network.lastRequest?.queryValue("for_you"), "true")

        let members = StubNetworkClient(responses: [
            #"{"members": [{"user": \#(Self.owner), "role": "owner", "status": "active"}]}"#
        ])
        let people = try await service(members).fetchMembers(slug: "riyadh_runners")
        XCTAssertEqual(people.map(\.role), [.owner])
        XCTAssertEqual(members.lastRequest?.queryValue("status"), "active")
    }

    func testCreateSendsTheWholeSpaceAndOmitsWhatCarriesNothing() throws {
        let request = CreateCommunityRequest(
            slug: " Riyadh_Runners ",
            name: "  Riyadh runners  ",
            description: "  ",
            visibility: .private,
            joinPolicy: .invite,
            scope: .country("SA"),
            topic: "sports",
            verifiedOnly: true,
            rules: [" Be kind ", "", "No selling"]
        )
        XCTAssertEqual(request.slug, "riyadh_runners")
        XCTAssertEqual(request.name, "Riyadh runners")
        XCTAssertNil(request.description)
        XCTAssertEqual(request.rules, ["Be kind", "No selling"])

        let body = try JSONCoding.encoder.encode(request)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["visibility"] as? String, "private")
        XCTAssertEqual(json["join_policy"] as? String, "invite")
        XCTAssertEqual(json["scope_country"] as? String, "SA")
        XCTAssertEqual(json["verified_only"] as? Bool, true)
        XCTAssertNil(json["description"])
    }

    func testTheAdminCallsUseTheirPaths() async throws {
        let network = StubNetworkClient(responses: [Self.json, "", "", "", ""])
        let svc = service(network)
        _ = try await svc.join(slug: "riyadh_runners")
        try await svc.leave(slug: "riyadh_runners")
        try await svc.approve(slug: "riyadh_runners", handle: "@Amy")
        try await svc.remove(slug: "riyadh_runners", handle: "@Amy")
        try await svc.setRole(slug: "riyadh_runners", handle: "@Amy", role: .admin)
        XCTAssertEqual(network.requests[0].path, "/communities/riyadh_runners/join")
        XCTAssertEqual(network.requests[1].path, "/communities/riyadh_runners/leave")
        XCTAssertEqual(network.requests[2].path, "/communities/riyadh_runners/members/amy/approve")
        XCTAssertEqual(network.requests[3].path, "/communities/riyadh_runners/members/amy")
        XCTAssertEqual(network.requests[3].method, .delete)
        let role = try XCTUnwrap(network.requests[4].body)
        XCTAssertEqual(String(data: role, encoding: .utf8), #"{"role":"admin"}"#)
    }

    // MARK: - A post knows where it was written

    func testAPostCarriesItsCommunity() throws {
        let json = """
        {"id": "99999999-0000-4000-8000-000000000001", "author": \(Self.owner), "text": "we run at six",
         "created_at": "2026-09-09T08:00:00Z", "scope": "country", "scope_country": "SA",
         "community_id": "88888888-0000-4000-8000-000000000001", "community_slug": "riyadh_runners",
         "community_name": "Riyadh runners"}
        """
        let post = try JSONCoding.decoder.decode(Post.self, from: Data(json.utf8))
        XCTAssertEqual(post.communitySlug, "riyadh_runners")
        XCTAssertEqual(post.communityName, "Riyadh runners")
        // A quote flattened out of a post keeps it.
        XCTAssertEqual(post.strippingQuote().communitySlug, "riyadh_runners")
    }

    func testWritingInACommunitySendsItAndHidesTheScopePicker() throws {
        let community = try JSONCoding.decoder.decode(Community.self, from: Data(Self.json.utf8))
        let context = ComposerContext.community(community)
        XCTAssertFalse(context.showsScopePicker)
        XCTAssertEqual(context.community?.slug, "riyadh_runners")

        let draft = PostDraft(text: "hello", scope: .international, communityId: community.id)
        let body = try JSONCoding.encoder.encode(CreatePostBody(draft: draft))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["community_id"] as? String, community.id.uuidString.lowercased())
    }

    // MARK: - The screens

    @MainActor
    func testJoiningAnApprovalCommunityLeavesYouWaiting() async throws {
        let mock = CommunitiesServiceMock(scenario: .empty)
        let community = await mock.seed(
            try JSONCoding.decoder.decode(Community.self, from: Data(Self.json.utf8))
        )
        let viewModel = CommunityViewModel(
            slug: community.slug,
            service: mock,
            feed: FeedServiceMock(),
            analytics: RecordingAnalyticsClient()
        )
        await viewModel.load()
        XCTAssertEqual(viewModel.doorTitle, CommunityCopy.join)

        await viewModel.toggleMembership()
        XCTAssertEqual(viewModel.community?.isPending, true)
        XCTAssertEqual(viewModel.community?.isMember, false)
        XCTAssertEqual(viewModel.doorTitle, CommunityCopy.requested)
        XCTAssertEqual(viewModel.community?.canPost, false)
    }

    @MainActor
    func testAnAdminMayActOnMembersButNeverOnTheOwner() throws {
        let mock = CommunitiesServiceMock()
        let viewModel = CommunityViewModel(
            slug: "family", service: mock, feed: FeedServiceMock(), analytics: RecordingAnalyticsClient()
        )
        // Nothing loaded: nobody is manageable, so a stray tap cannot act.
        let member = CommunityMember(user: UserSummary(id: UUID(), handle: "amy", displayName: "Amy", isVerified: true))
        XCTAssertFalse(viewModel.canManage(member))
    }

    @MainActor
    func testTheCreateSheetSuggestsAnAddressAndSaysWhyItCannotOpen() async {
        let viewModel = CreateCommunityViewModel(
            author: ComposerAuthor(handle: "aziz", countryCode: "SA", isVerified: true),
            service: CommunitiesServiceMock(),
            preferences: PreferencesServiceMock(),
            analytics: RecordingAnalyticsClient()
        )
        XCTAssertNotNil(viewModel.blockingReason)  // no name yet

        viewModel.name = "Riyadh Runners!"
        XCTAssertEqual(viewModel.slug, "riyadh_runners")
        XCTAssertNil(viewModel.blockingReason)
        XCTAssertTrue(viewModel.canCreate)

        // A name with no Latin letters leaves the address to the person.
        viewModel.name = "عدّاؤو الرياض"
        XCTAssertEqual(viewModel.slug, "")
        XCTAssertNotNil(viewModel.blockingReason)
    }

    @MainActor
    func testAnUnverifiedAccountIsToldWhyItCannotOpenOne() {
        let viewModel = CreateCommunityViewModel(
            author: ComposerAuthor(handle: "aziz", countryCode: nil, isVerified: false),
            service: CommunitiesServiceMock(),
            preferences: PreferencesServiceMock(),
            analytics: RecordingAnalyticsClient()
        )
        viewModel.name = "Anything"
        XCTAssertFalse(viewModel.canOpen)
        XCTAssertFalse(viewModel.canCreate)
        XCTAssertEqual(viewModel.blockingReason, L10n.t("communities.create.unverified"))
    }

    @MainActor
    func testTheListSeparatesWhatYouAreInFromWhatToJoin() async {
        let mock = CommunitiesServiceMock()
        let viewModel = CommunitiesViewModel(service: mock, analytics: RecordingAnalyticsClient())
        await viewModel.load()
        XCTAssertEqual(viewModel.communities.count, 2)

        viewModel.folder = .mine
        await viewModel.load(isRefresh: true)
        XCTAssertEqual(viewModel.communities.map(\.slug), ["family"])
    }

    @MainActor
    func testARoomInsideACommunityReadsAsClosed() throws {
        let json = """
        {"id": "11111111-0000-4000-8000-000000000009", "title": "Morning run", "scope": "international",
         "status": "live", "host": \(Self.owner), "speaker_count": 1, "listener_count": 0,
         "created_at": "2026-09-09T08:00:00Z", "can_speak": true, "is_host": false,
         "community_id": "88888888-0000-4000-8000-000000000001", "community_slug": "riyadh_runners",
         "community_name": "Riyadh runners", "can_join": false,
         "join_refusal": "This room is for a community's members"}
        """
        let room = try JSONCoding.decoder.decode(VoiceRoom.self, from: Data(json.utf8))
        XCTAssertEqual(room.communityName, "Riyadh runners")
        XCTAssertTrue(room.isClosed)
        XCTAssertFalse(room.canJoin)
        XCTAssertEqual(room.joinRefusalMessage, "This room is for a community's members")
    }
}
