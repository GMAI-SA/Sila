import XCTest
@testable import Sila

/// GIFs in posts (contract v17): decoded off a post, encoded onto a draft,
/// and picked from a library that knows the viewer's country.
final class GifTests: XCTestCase {

    private func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        try JSONCoding.decoder.decode(T.self, from: Data(json.utf8))
    }

    private static let gifJSON = """
    {"id": "6c1b1f7e-5a3d-4b2a-9d21-0c1f2a3b4c5d", "provider": "tenor", "provider_id": "123",
     "url": "https://media.tenor.com/a/clip.mp4", "gif_url": "https://media.tenor.com/a/clip.gif",
     "preview_url": "https://media.tenor.com/a/tiny.gif", "still_url": "https://media.tenor.com/a/still.png",
     "width": 498, "height": 280, "title": "happy cat", "share_count": 4}
    """

    private static let postJSON = """
    {"id": "11111111-1111-4111-8111-111111111111",
     "author": {"id": "22222222-2222-4222-8222-222222222222", "handle": "noura", "display_name": "Noura",
                "avatar_url": null, "is_verified": true, "country_code": "SA", "verified_since": null},
     "text": "", "created_at": "2026-09-09T10:00:00Z", "scope": "international", "scope_country": null,
     "scope_region": null, "reply_to_post_id": null, "reply_count_direct": 0, "quoted_post": null,
     "metrics": {"likes": 0, "reposts": 0, "replies": 0, "views": 0, "bookmarks": 0},
     "viewer": {"liked": false, "reposted": false, "bookmarked": false, "can_reply": true, "reply_block_reason": null},
     "gif": GIF}
    """

    func testAPostDecodesItsGif() throws {
        let post = try decode(Post.self, from: Self.postJSON.replacingOccurrences(of: "GIF", with: Self.gifJSON))
        let gif = try XCTUnwrap(post.gif)
        XCTAssertEqual(gif.providerId, "123")
        XCTAssertEqual(gif.url.absoluteString, "https://media.tenor.com/a/clip.mp4")
        XCTAssertEqual(gif.previewURL?.absoluteString, "https://media.tenor.com/a/tiny.gif")
        XCTAssertEqual(gif.width, 498)
        XCTAssertEqual(gif.title, "happy cat")
        XCTAssertEqual(gif.shareCount, 4)
        XCTAssertTrue(gif.isVideo)
        XCTAssertEqual(gif.aspectRatio, 498.0 / 280.0, accuracy: 0.001)
        XCTAssertEqual(gif.thumbnailURL, gif.previewURL)
        XCTAssertEqual(post.text, "", "a GIF can stand alone")
    }

    func testABrokenGifCostsThePictureNotThePost() throws {
        let post = try decode(Post.self, from: Self.postJSON.replacingOccurrences(of: "GIF", with: #"{"provider": "tenor"}"#))
        XCTAssertNil(post.gif)
        let none = try decode(Post.self, from: Self.postJSON.replacingOccurrences(of: "GIF", with: "null"))
        XCTAssertNil(none.gif)
    }

    func testTheDraftSendsTheGifBackExactlyAsItCame() throws {
        let gif = try decode(Gif.self, from: Self.gifJSON)
        let draft = PostDraft(text: "", scope: .international, gif: gif)
        XCTAssertTrue(draft.isPostable, "a GIF with no words is a post")
        XCTAssertFalse(PostDraft(text: "", scope: .international).isPostable)

        let body = try JSONCoding.encoder.encode(CreatePostBody(draft: draft))
        // Read back rather than matched against the text: `JSONEncoder`
        // escapes forward slashes, so every URL in the raw string is
        // `https:\/\/…` and a substring assertion tests the encoder's
        // escaping rather than the field it meant to check.
        let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let wire = try XCTUnwrap(sent["gif"] as? [String: Any])
        XCTAssertEqual(wire["provider_id"] as? String, "123")
        XCTAssertEqual(wire["provider"] as? String, "tenor")
        XCTAssertEqual(wire["url"] as? String, "https://media.tenor.com/a/clip.mp4")
        XCTAssertEqual(wire["gif_url"] as? String, "https://media.tenor.com/a/clip.gif")
        XCTAssertEqual(wire["preview_url"] as? String, "https://media.tenor.com/a/tiny.gif")
        XCTAssertEqual(wire["still_url"] as? String, "https://media.tenor.com/a/still.png")
        XCTAssertEqual(wire["width"] as? Int, 498)
        XCTAssertEqual(wire["id"] as? String, "6c1b1f7e-5a3d-4b2a-9d21-0c1f2a3b4c5d")
        XCTAssertEqual(sent["text"] as? String, "")

        let plain = try JSONCoding.encoder.encode(CreatePostBody(draft: PostDraft(text: "hi", scope: .international)))
        let withoutGif = try XCTUnwrap(JSONSerialization.jsonObject(with: plain) as? [String: Any])
        XCTAssertNil(withoutGif["gif"], "omitted when there is none")
    }

    func testAThreadCarriesTheGifOnItsOpeningSegmentOnlyAndAGifAloneIsOneSegment() async throws {
        let gif = try decode(Gif.self, from: Self.gifJSON)
        let service = ScriptedComposerService()
        let report = await service.createThread(segments: ["one", "two"], scope: .international, gif: gif)
        XCTAssertTrue(report.isCompleteSuccess)
        XCTAssertEqual(service.drafts.map { $0.gif != nil }, [true, false])

        let alone = ScriptedComposerService()
        let report2 = await alone.createThread(segments: ["", "   "], scope: .international, gif: gif)
        XCTAssertEqual(report2.posted.count, 1, "no words, one GIF: one post")
        XCTAssertEqual(alone.drafts.first?.trimmedText, "")
        XCTAssertNotNil(alone.drafts.first?.gif)

        let nothing = ScriptedComposerService()
        let report3 = await nothing.createThread(segments: [""], scope: .international)
        XCTAssertTrue(report3.posted.isEmpty, "nothing at all is nothing")
    }

    @MainActor
    func testTheComposerCanPostAGifWithNoWordsAndKnowsItHasContent() throws {
        let gif = try decode(Gif.self, from: Self.gifJSON)
        let viewModel = ComposerViewModel(
            context: .newPost,
            author: ComposerAuthor(countryCode: "SA", isVerified: true),
            composer: ScriptedComposerService(),
            gifs: GifServiceMock(),
            analytics: RecordingAnalyticsClient()
        )
        XCTAssertFalse(viewModel.canPost)
        XCTAssertFalse(viewModel.hasContent)
        viewModel.openGifPicker()
        XCTAssertTrue(viewModel.isShowingGifPicker)
        viewModel.attach(gif: gif)
        XCTAssertFalse(viewModel.isShowingGifPicker, "picking closes the picker")
        XCTAssertTrue(viewModel.canPost)
        XCTAssertTrue(viewModel.hasContent, "a GIF is something to lose")
        viewModel.removeGif()
        XCTAssertFalse(viewModel.canPost)
    }

    @MainActor
    func testWithoutALibraryTheComposerOffersNoPicker() {
        let viewModel = ComposerViewModel(
            context: .newPost,
            author: ComposerAuthor(isVerified: true),
            composer: ScriptedComposerService(),
            analytics: RecordingAnalyticsClient(),
            openGifPicker: true
        )
        XCTAssertNil(viewModel.gifs)
        XCTAssertFalse(viewModel.isShowingGifPicker, "no library, nothing to open onto")
        viewModel.openGifPicker()
        XCTAssertFalse(viewModel.isShowingGifPicker)
    }

    // MARK: Picker

    @MainActor
    func testThePickerOpensOnTrendingWithWhatPeopleHereShare() async {
        let viewModel = GifPickerViewModel(service: GifServiceMock(), country: "SA", debounce: 0)
        await viewModel.load()
        XCTAssertEqual(viewModel.loadState, .loaded)
        XCTAssertEqual(viewModel.gifs.count, 4)
        XCTAssertTrue(viewModel.isFromProvider)
        XCTAssertEqual(viewModel.sharedHere.map(\.title), ["happy cat", "thumbs up", "dancing camel"])
        XCTAssertTrue(viewModel.hasMore)
        XCTAssertEqual(viewModel.countryName, Locale.current.localizedString(forRegionCode: "SA"))
    }

    @MainActor
    func testTypingSearchesAndClearingRestoresTrending() async throws {
        let service = GifServiceMock()
        let viewModel = GifPickerViewModel(service: service, country: "SA", debounce: 0)
        await viewModel.load()
        viewModel.updateQuery("clap", immediately: true)
        for _ in 0..<50 where viewModel.gifs.map(\.title) != ["slow clap"] {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(viewModel.gifs.map(\.title), ["slow clap"])
        XCTAssertTrue(viewModel.sharedHere.isEmpty, "a search is a search, not the country's list")
        let searched = await service.recordedCalls
        XCTAssertTrue(searched.contains("search:clap:SA"))

        viewModel.clear()
        XCTAssertEqual(viewModel.gifs.count, 4, "trending comes back without a request")
        let afterClearing = await service.recordedCalls
        XCTAssertEqual(afterClearing.filter { $0.hasPrefix("trending") }.count, 1)
    }

    @MainActor
    func testAnEmptyLibraryWithNoProviderSaysSoAndAnOutageIsAFailure() async {
        let empty = GifPickerViewModel(service: GifServiceMock(scenario: .empty), country: "SA", debounce: 0)
        await empty.load()
        XCTAssertTrue(empty.isLibraryEmpty)
        XCTAssertFalse(empty.isFromProvider)

        let offline = GifPickerViewModel(service: GifServiceMock(scenario: .offline), country: nil, debounce: 0)
        await offline.load()
        if case .failed = offline.loadState {} else { XCTFail("expected a failure, got \(offline.loadState)") }
    }

    func testTheGifServiceAsksForTheCountryAndTheQuery() async throws {
        let network = StubNetworkClient(responses: [#"{"gifs": [], "source": "library", "country": "SA", "provider_configured": false}"#])
        let service = GifService(network: network, tokens: StaticAccessTokenProvider(token: "t"))
        let list = try await service.search("cat", country: "SA", cursor: "9")
        XCTAssertEqual(list.source, "library")
        XCTAssertFalse(list.providerConfigured)
        let request = try XCTUnwrap(network.lastRequest)
        XCTAssertEqual(request.path, "/gifs/search")
        XCTAssertEqual(request.queryValue("q"), "cat")
        XCTAssertEqual(request.queryValue("country"), "SA")
        XCTAssertEqual(request.queryValue("cursor"), "9")
    }
}

/// A room on a timeline (contract v18): the card a post carries.
final class RoomCardTests: XCTestCase {

    private static let json = """
    {"id": "11111111-1111-4111-8111-111111111111",
     "author": {"id": "22222222-2222-4222-8222-222222222222", "handle": "noura", "display_name": "Noura",
                "avatar_url": null, "is_verified": true, "country_code": "SA", "verified_since": null},
     "text": "listen to this", "created_at": "2026-09-13T10:00:00Z", "scope": "international",
     "scope_country": null, "scope_region": null, "reply_to_post_id": null, "reply_count_direct": 0,
     "quoted_post": null, "metrics": {"likes": 0, "reposts": 0, "replies": 0, "views": 0, "bookmarks": 0},
     "viewer": {"liked": false, "reposted": false, "bookmarked": false, "can_reply": true, "reply_block_reason": null},
     "room": ROOM}
    """

    private static let room = """
    {"id": "33333333-3333-4333-8333-333333333333", "title": "What verification changes",
     "topic": "technology", "status": "live", "scope": "international", "scope_country": null,
     "scope_region": null,
     "host": {"id": "44444444-4444-4444-8444-444444444444", "handle": "aziz", "display_name": "Aziz",
              "avatar_url": null, "is_verified": true, "country_code": "SA", "verified_since": null},
     "participant_count": 12, "scheduled_for": null, "started_at": "2026-09-13T09:00:00Z",
     "metrics": {"likes": 4, "shares": 1, "views": 30, "listeners": 12}, "viewer_liked": true}
    """

    private func post(_ room: String) throws -> Post {
        try JSONCoding.decoder.decode(Post.self, from: Data(Self.json.replacingOccurrences(of: "ROOM", with: room).utf8))
    }

    func testAPostCarriesTheRoomItIsAbout() throws {
        let card = try XCTUnwrap(post(Self.room).room)
        XCTAssertEqual(card.title, "What verification changes")
        XCTAssertEqual(card.status, .live)
        XCTAssertTrue(card.isJoinable)
        XCTAssertEqual(card.host.handle, "aziz")
        XCTAssertEqual(card.participantCount, 12)
        XCTAssertEqual(card.metrics.likes, 4)
        XCTAssertEqual(card.metrics.views, 30)
        XCTAssertTrue(card.viewerLiked)
    }

    func testAnEndedRoomKeepsItsCardAndOffersNoDoor() throws {
        let ended = Self.room.replacingOccurrences(of: "\"status\": \"live\"", with: "\"status\": \"ended\"")
        let card = try XCTUnwrap(post(ended).room)
        XCTAssertEqual(card.status, .ended)
        XCTAssertFalse(card.isJoinable, "there is nothing to walk into")
        XCTAssertEqual(card.title, "What verification changes", "but the trace survives")
    }

    func testAPostWithNoRoomOrABrokenOneStillReads() throws {
        XCTAssertNil(try post("null").room)
        XCTAssertNil(try post(#"{"title": "no id"}"#).room)
        XCTAssertEqual(try post("null").text, "listen to this")
    }

    func testMetricsDefaultToNothingRatherThanFailing() throws {
        let bare = Self.room.replacingOccurrences(of: #""metrics": {"likes": 4, "shares": 1, "views": 30, "listeners": 12}, "#, with: "")
        let card = try XCTUnwrap(post(bare).room)
        XCTAssertEqual(card.metrics.likes, 0)
        XCTAssertEqual(card.metrics.listeners, 0)
    }
}
