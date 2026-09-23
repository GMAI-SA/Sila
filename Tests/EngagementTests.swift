import XCTest
@testable import Sila

// Contract v19 — engagement: polls, mentions, hidden replies, starters,
// Needs a reply, people, the first-run flow and telemetry.

private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try JSONCoding.decoder.decode(T.self, from: Data(json.utf8))
}

private let author = #"{"id": "00000000-0000-4000-8000-000000000101", "handle": "aziz", "display_name": "Aziz", "is_verified": true, "country_code": "SA"}"#

private func postJSON(extra: String) -> String {
    """
    {"id": "00000000-0000-4000-8000-000000000001", "author": \(author), "text": "Tea or coffee? @aziz @nobody",
     "created_at": "2026-09-23T10:00:00Z", "scope": "international", "scope_country": null, "scope_region": null,
     "reply_to_post_id": null, "reply_count_direct": 0, "quoted_post": null,
     "metrics": {"likes": 0, "reposts": 0, "replies": 0, "views": 0, "bookmarks": 0},
     "viewer": {"liked": false, "reposted": false, "bookmarked": false, "can_reply": true, "reply_block_reason": null}
     \(extra)}
    """
}

private let pollJSON = """
{"id": "00000000-0000-4000-8000-000000000900",
 "options": [{"id": "00000000-0000-4000-8000-000000000912", "position": 1, "text": "Coffee", "votes": null},
             {"id": "00000000-0000-4000-8000-000000000911", "position": 0, "text": "Tea", "votes": null}],
 "total_votes": 5, "closes_at": "2099-01-01T00:00:00Z", "closed": false,
 "results_visibility": "after_vote", "results_visible": false,
 "viewer_option_id": null, "can_vote": true, "vote_block_reason": null}
"""

// MARK: - Post decoding

final class EngagementPostDecodingTests: XCTestCase {

    func testAPostCarriesItsPollHiddenFlagAndResolvedMentions() throws {
        let post = try decode(Post.self, postJSON(extra: """
        , "poll": \(pollJSON), "hidden_by_author": true,
          "mentions": [{"handle": "Aziz", "user_id": "00000000-0000-4000-8000-000000000101"}]
        """))

        XCTAssertEqual(post.poll?.options.map(\.text), ["Tea", "Coffee"], "options sort by position")
        XCTAssertEqual(post.poll?.totalVotes, 5)
        XCTAssertNil(post.poll?.options.first?.votes, "hidden counts stay nil, never zero")
        XCTAssertTrue(post.hiddenByAuthor)
        XCTAssertEqual(post.mentions?.map(\.handle), ["aziz"])
    }

    func testAnOlderResponseDecodesWithNoneOfTheNewFields() throws {
        let post = try decode(Post.self, postJSON(extra: ""))
        XCTAssertNil(post.poll)
        XCTAssertFalse(post.hiddenByAuthor)
        XCTAssertNil(post.mentions, "absent means 'the server did not say', not 'none resolved'")
    }

    func testAMalformedPollCostsThePollNotThePost() throws {
        let post = try decode(Post.self, postJSON(extra: #", "poll": {"id": 7}"#))
        XCTAssertNil(post.poll)
        XCTAssertEqual(post.text, "Tea or coffee? @aziz @nobody")
    }

    func testOnlyResolvedMentionsAreLinked() {
        let text = PostBodyText.attributed(
            text: "ask @aziz and @nobody",
            fontSize: 17, weight: .regular, textColor: .white, entityColor: .blue,
            direction: .leftToRight, resolvedMentions: ["aziz"]
        )
        var links: [String] = []
        text.enumerateAttribute(.link, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if value != nil { links.append((text.string as NSString).substring(with: range)) }
        }
        XCTAssertEqual(links, ["@aziz"])
    }

    func testWithoutServerMentionsEveryHandleStillLinks() {
        let text = PostBodyText.attributed(
            text: "ask @aziz and @nobody",
            fontSize: 17, weight: .regular, textColor: .white, entityColor: .blue,
            direction: .leftToRight
        )
        var count = 0
        text.enumerateAttribute(.link, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if value != nil { count += 1 }
        }
        XCTAssertEqual(count, 2)
    }
}

// MARK: - Polls

@MainActor
final class PollViewModelTests: XCTestCase {

    private var poll: Poll { try! decode(Poll.self, pollJSON) }

    func testSharesAreHiddenUntilResultsAreVisible() {
        XCTAssertNil(poll.share(of: poll.options[0]))
        XCTAssertNil(PollCopy.percent(poll, option: poll.options[0]))
        let visible = Poll(
            options: [PollOption(position: 0, text: "Tea", votes: 3), PollOption(position: 1, text: "Coffee", votes: 1)],
            totalVotes: 4, closesAt: .distantFuture, resultsVisible: true
        )
        XCTAssertEqual(visible.share(of: visible.options[0]), 0.75)
    }

    func testTheFooterSaysTheTotalAndWhenItCloses() {
        let open = PollCopy.footer(poll)
        XCTAssertTrue(open.contains("5 votes"), open)
        let closed = Poll(options: poll.options, totalVotes: 1, closesAt: Date().addingTimeInterval(-60))
        XCTAssertTrue(PollCopy.footer(closed).contains(L10n.t("poll.closed")))
        XCTAssertTrue(closed.isClosed())
    }

    func testABlockedVoterIsToldWhyInTheReplyWording() throws {
        let post = try decode(Post.self, postJSON(extra: ""))
        let foreign = Poll(options: poll.options, closesAt: .distantFuture, canVote: false, voteBlockReason: .countryMismatch)
        XCTAssertNotNil(PollCopy.blockedLine(foreign, post: post))
        let guest = Poll(options: poll.options, closesAt: .distantFuture, canVote: false, voteBlockReason: .guest)
        XCTAssertEqual(PollCopy.blockedLine(guest, post: post), L10n.t("poll.blocked.guest"))
        let voted = Poll(options: poll.options, closesAt: .distantFuture, viewerOptionId: poll.options[0].id,
                         canVote: false, voteBlockReason: .alreadyVoted)
        XCTAssertNil(PollCopy.blockedLine(voted, post: post), "the bars already say it")
    }

    func testTheDraftEnforcesTheServersRules() {
        var draft = PollDraft()
        XCTAssertFalse(draft.isValid, "two empty options")
        draft.options = ["Tea", "tea"]
        XCTAssertEqual(draft.problem, L10n.t("poll.error.duplicate"))
        draft.options = ["Tea", String(repeating: "x", count: 41)]
        XCTAssertEqual(draft.problem, L10n.t("poll.error.tooLong"))
        draft.options = ["Tea", " Coffee "]
        XCTAssertTrue(draft.isValid)
        XCTAssertEqual(draft.payload.options, ["Tea", "Coffee"])
        draft.options += ["A", "B"]
        XCTAssertFalse(draft.canAddOption)
    }

    func testThePollGoesOnTheWireInSnakeCase() throws {
        var draft = PostDraft(text: "Tea or coffee?", scope: .international)
        draft.poll = PollDraft(options: ["Tea", "Coffee"], duration: .sixHours, visibility: .afterClose)
        let json = String(decoding: try JSONCoding.encoder.encode(CreatePostBody(draft: draft)), as: UTF8.self)
        XCTAssertTrue(json.contains(#""duration_minutes":360"#), json)
        XCTAssertTrue(json.contains(#""results_visibility":"after_close""#), json)
        XCTAssertTrue(draft.isPostable)
        draft.text = ""
        XCTAssertFalse(draft.isPostable, "a poll needs its question")
    }

    func testAPollTravelsAloneInTheComposer() async {
        let composer = ComposerViewModel(
            context: .newPost,
            author: ComposerAuthor(user: nil),
            composer: ComposerServiceMock(scenario: .success),
            analytics: RecordingAnalyticsClient()
        )
        XCTAssertTrue(composer.canAddPoll)
        composer.addPoll()
        XCTAssertNotNil(composer.poll)
        XCTAssertFalse(composer.allowsThread)
        XCTAssertFalse(composer.allowsMedia)
        XCTAssertFalse(composer.canPost, "no question, no options")
        composer.setText("Tea or coffee?", at: 0)
        composer.poll?.options = ["Tea", "Coffee"]
        XCTAssertTrue(composer.canPost)
        composer.removePoll()
        XCTAssertTrue(composer.allowsMedia)
    }

    func testAReplyNeverOffersAPoll() throws {
        let parent = try decode(Post.self, postJSON(extra: ""))
        let composer = ComposerViewModel(
            context: .reply(to: parent),
            author: ComposerAuthor(user: nil),
            composer: ComposerServiceMock(scenario: .success),
            analytics: RecordingAnalyticsClient()
        )
        XCTAssertFalse(composer.canAddPoll)
    }

    func testAPollStarterOpensThePollEditorWithTheQuestion() async {
        let analytics = RecordingAnalyticsClient()
        let composer = ComposerViewModel(
            context: .newPost,
            author: ComposerAuthor(user: nil),
            composer: ComposerServiceMock(scenario: .success),
            analytics: analytics,
            starters: DiscoverServiceMock()
        )
        await composer.loadStarters()
        XCTAssertTrue(composer.showsStarters)
        let choose = composer.starters.first { $0.kind == .poll }!
        composer.use(choose)
        XCTAssertEqual(composer.text(at: 0), choose.phrase())
        XCTAssertNotNil(composer.poll)
        XCTAssertFalse(composer.showsStarters)
        XCTAssertTrue(analytics.events.contains(.composerStarterUsed))
    }

    func testVotingReturnsTheServersAnswerAndIsFinal() async throws {
        let service = DiscoverServiceMock()
        let postId = UUID()
        let option = DiscoverServiceMock.samplePoll.options[0].id
        let answer = try await service.vote(postId: postId, optionId: option)
        XCTAssertEqual(answer.viewerOptionId, option)
        XCTAssertTrue(answer.resultsVisible)
        do {
            _ = try await service.vote(postId: postId, optionId: option)
            XCTFail("a second vote went through")
        } catch let error as APIError {
            XCTAssertEqual(error.code, .alreadyVoted)
            XCTAssertEqual(error.userMessage, L10n.t("poll.error.alreadyVoted"))
        }
    }

    func testEveryPollRefusalHasItsOwnCopy() {
        let codes: [APIErrorCode] = [.invalidPoll, .pollOnReply, .pollWithMedia, .voteNotAllowed, .pollClosed, .alreadyVoted]
        let messages = Set(codes.map { APIError.api(code: $0, message: "server words", status: 400).userMessage })
        XCTAssertEqual(messages.count, codes.count)
        XCTAssertFalse(messages.contains("server words"))
    }
}

// MARK: - Starters

final class ComposerStarterTests: XCTestCase {

    func testAStarterSpeaksTheInterfaceLanguage() throws {
        let starter = try decode(ComposerStarter.self, #"{"id": "choose", "text": "Which one?", "text_ar": "أيهما؟", "kind": "poll", "hashtag": null}"#)
        XCTAssertEqual(starter.kind, .poll)
        XCTAssertEqual(starter.phrase(languageCode: "ar"), "أيهما؟")
        XCTAssertEqual(starter.phrase(languageCode: "en"), "Which one?")
    }
}

// MARK: - Notification settings

@MainActor
final class NotificationGroupsTests: XCTestCase {

    func testGroupsComeBackInTheirOrderWhateverTheJSONOrder() throws {
        let preferences = try decode(FeedPreferences.self, """
        {"notifications": {"like": true, "room_like": false, "quote_boost": true},
         "notification_groups": {"sila": ["prompt"], "rooms": ["room_invite", "room_like"],
                                 "people": ["follow"], "future": ["quote_boost"], "posts": ["like"]}}
        """)
        XCTAssertEqual(preferences.notificationGroups.map(\.id), ["people", "posts", "rooms", "sila", "future"])
        XCTAssertFalse(preferences.notifications.isEnabled(key: "room_like"))
    }

    func testAKindThisBuildDoesNotKnowStillGetsALabelledSwitch() {
        let row = NotificationSettingRow(key: "quote_boost")
        XCTAssertEqual(row.title, "Quote boost")
        XCTAssertEqual(NotificationSettingRow(key: "poll_closed").title, NotificationKind.pollClosed.settingTitle)
    }

    func testTheSheetDrawsTheServersGroupsOrFallsBack() async {
        let fallback = NotificationSettingsViewModel(
            service: PreferencesServiceMock(scenario: .populated),
            analytics: RecordingAnalyticsClient()
        )
        await fallback.load()
        XCTAssertEqual(fallback.sections.flatMap(\.kinds), NotificationKind.settable.map(\.rawValue))
    }

    func testAKindByWireNameSavesAndSpringsBackOnRefusal() async {
        let service = PreferencesServiceMock(scenario: .saveFails)
        let viewModel = NotificationSettingsViewModel(service: service, analytics: RecordingAnalyticsClient())
        await viewModel.load()
        await viewModel.setEnabled(false, key: "room_like")
        XCTAssertTrue(viewModel.preferences.isEnabled(key: "room_like"))
        XCTAssertNotNil(viewModel.toast)
    }

    func testPollClosedIsAPostNotificationWithItsOwnSentence() throws {
        XCTAssertTrue(NotificationKind.pollClosed.isAboutAPost)
        XCTAssertNotEqual(NotificationKind.pollClosed.icon, NotificationKind.unknown.icon)
        XCTAssertEqual(NotificationCopy.sentence(.pollClosed, actor: "Noura"), L10n.t("notifications.sentence.pollClosed"))
    }
}

// MARK: - First run

@MainActor
final class OnboardingViewModelTests: XCTestCase {

    private func make(discover: DiscoverServiceMock = DiscoverServiceMock(), rooms: RoomsServiceProtocol? = nil,
                      finished: @escaping () -> Void = {}) -> OnboardingViewModel {
        OnboardingViewModel(
            discover: discover,
            preferences: PreferencesServiceMock(scenario: .populated),
            profile: ProfileServiceMock(scenario: .populated),
            rooms: rooms,
            analytics: RecordingAnalyticsClient(),
            onFinish: finished
        )
    }

    func testChosenSubjectsAreSentAndThePeopleStepFollows() async {
        let discover = DiscoverServiceMock()
        let viewModel = make(discover: discover)
        await viewModel.load()
        XCTAssertFalse(viewModel.topics.isEmpty)
        let picks = viewModel.topics.prefix(3).map(\.id)
        picks.forEach(viewModel.toggle)
        XCTAssertEqual(viewModel.subjectsHint, L10n.plural("onboarding.interests.chosen", 3))

        await viewModel.continueFromSubjects()

        XCTAssertEqual(discover.submitted, OnboardingInterestsRequest(topics: picks.sorted(), skipped: false))
        XCTAssertEqual(viewModel.step, .people)
        XCTAssertFalse(viewModel.people.isEmpty)
    }

    func testSkippingIsRecordedAsASkip() async {
        let discover = DiscoverServiceMock()
        let viewModel = make(discover: discover)
        await viewModel.load()
        viewModel.toggle(viewModel.topics[0].id)
        await viewModel.skipSubjects()
        XCTAssertEqual(discover.submitted, OnboardingInterestsRequest(topics: [], skipped: true))
    }

    func testFollowingFromThePeopleStep() async {
        let viewModel = make()
        await viewModel.load()
        await viewModel.continueFromSubjects()
        let person = viewModel.people[0]
        await viewModel.follow(person)
        XCTAssertTrue(viewModel.isFollowed(person))
    }

    func testFinishingWithNothingLiveGoesStraightToTheFeed() async {
        var finished = false
        let viewModel = make(rooms: RoomsServiceMock(scenario: .empty), finished: { finished = true })
        await viewModel.finish()
        XCTAssertTrue(finished)
    }

    func testFinishingWithARoomLiveEndsOnItsCard() async {
        var finished = false
        let viewModel = make(rooms: RoomsServiceMock(scenario: .populated), finished: { finished = true })
        await viewModel.finish()
        XCTAssertEqual(viewModel.step, .finale)
        XCTAssertNotNil(viewModel.liveRoom)
        XCTAssertFalse(finished)
        viewModel.complete(result: "feed")
        XCTAssertTrue(finished)
    }

    func testAnOfflineSaveIsNotADeadEnd() async {
        let viewModel = make(discover: DiscoverServiceMock(scenario: .offline))
        await viewModel.continueFromSubjects()
        XCTAssertNotNil(viewModel.toast)
    }

    func testTheServerFlagDecodesAndCanBeCleared() throws {
        let user = try decode(AuthUser.self, #"{"id": "00000000-0000-4000-8000-000000000101", "email": "a@b.c", "email_verified": true, "verification_status": "verified", "created_at": "2026-09-01T00:00:00Z", "needs_interest_prompt": true, "experiment_bucket": 42}"#)
        XCTAssertTrue(user.needsInterestPrompt)
        XCTAssertEqual(user.experimentBucket, 42)
        XCTAssertFalse(user.settingNeedsInterestPrompt(false).needsInterestPrompt)
    }
}

// MARK: - The Explore hub

@MainActor
final class DiscoverHubViewModelTests: XCTestCase {

    func testEverySectionLoadsOnItsOwn() async {
        let hub = DiscoverHubViewModel(
            discover: DiscoverServiceMock(),
            rooms: RoomsServiceMock(scenario: .populated),
            preferences: PreferencesServiceMock(scenario: .populated),
            profile: ProfileServiceMock(scenario: .populated),
            analytics: RecordingAnalyticsClient()
        )
        await hub.loadIfNeeded()
        XCTAssertFalse(hub.liveRooms.isEmpty)
        XCTAssertFalse(hub.needsReply.value?.isEmpty ?? true)
        XCTAssertFalse(hub.people.value?.isEmpty ?? true)
        XCTAssertFalse(hub.trending.value?.isEmpty ?? true)
        XCTAssertFalse(hub.subjects.value?.isEmpty ?? true)
    }

    func testAFailedSectionHidesItselfAndTheOthersStillLoad() async {
        let hub = DiscoverHubViewModel(
            discover: DiscoverServiceMock(scenario: .offline),
            rooms: RoomsServiceMock(scenario: .populated),
            preferences: PreferencesServiceMock(scenario: .populated),
            profile: nil,
            analytics: RecordingAnalyticsClient()
        )
        await hub.loadIfNeeded()
        XCTAssertEqual(hub.needsReply, .failed)
        XCTAssertEqual(hub.people, .failed)
        XCTAssertFalse(hub.liveRooms.isEmpty, "rooms did not wait for the broken sections")
    }

    func testFollowingAPersonMarksTheRow() async {
        let hub = DiscoverHubViewModel(
            discover: DiscoverServiceMock(),
            rooms: RoomsServiceMock(scenario: .empty),
            preferences: PreferencesServiceMock(scenario: .populated),
            profile: ProfileServiceMock(scenario: .populated),
            analytics: RecordingAnalyticsClient()
        )
        await hub.loadIfNeeded()
        let person = hub.people.value![0]
        await hub.follow(person)
        XCTAssertTrue(hub.followed.contains(person.id))
    }

    func testADeletedPostLeavesNeedsAReply() async {
        let hub = DiscoverHubViewModel(
            discover: DiscoverServiceMock(),
            rooms: RoomsServiceMock(scenario: .empty),
            preferences: PreferencesServiceMock(scenario: .populated),
            profile: nil,
            analytics: RecordingAnalyticsClient()
        )
        await hub.loadIfNeeded()
        let id = hub.needsReply.value![0].id
        hub.remove(postId: id)
        XCTAssertEqual(hub.needsReply.value?.contains { $0.id == id }, false)
    }
}

// MARK: - For You order

@MainActor
final class ForYouOrderTests: XCTestCase {

    func testTheOrderIsSentAsSortNewAndRemembered() async throws {
        let network = StubNetworkClient(responses: [#"{"posts": [], "next_cursor": null, "has_more": false}"#])
        let service = FeedService(network: network, tokens: StaticAccessTokenProvider(token: "t"), analytics: RecordingAnalyticsClient())
        _ = try await service.fetchFeed(.forYou, topics: [], order: .newest, cursor: nil, limit: 20)
        XCTAssertTrue(network.lastRequest?.query.contains(URLQueryItem(name: "sort", value: "new")) ?? false)
        _ = try await service.fetchFeed(.following, topics: [], order: .newest, cursor: nil, limit: 20)
        XCTAssertFalse(network.lastRequest?.query.contains { $0.name == "sort" } ?? true, "only For You has an order")

        let storage = InMemoryStorageClient()
        let home = HomeViewModel(service: FeedServiceMock(), analytics: RecordingAnalyticsClient(), storage: storage)
        await home.setForYouOrder(.newest)
        XCTAssertEqual(storage.value(for: .forYouOrder, as: String.self), "newest")
        let again = HomeViewModel(service: FeedServiceMock(), analytics: RecordingAnalyticsClient(), storage: storage)
        XCTAssertEqual(again.forYouOrder, .newest)
    }
}

// MARK: - Telemetry

final class BatchingAnalyticsClientTests: XCTestCase {

    func testEventsAreBatchedWithOnlyAllowedKeys() async throws {
        let network = StubNetworkClient(responses: [#"{"accepted": 1, "dropped": 0}"#])
        let client = BatchingAnalyticsClient(network: network, storage: InMemoryStorageClient(),
                                             downstream: RecordingAnalyticsClient(), appVersion: "1.0 (1)")
        client.track(.feedLoaded, properties: ["tab": "for_you", "subject": "football", "count": "3"])

        let sent = await client.flush()

        XCTAssertEqual(sent, 1)
        let body = try XCTUnwrap(network.lastRequest?.body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["platform"] as? String, "ios")
        XCTAssertEqual(json["anon_id"] as? String, client.anonId)
        let event = try XCTUnwrap((json["events"] as? [[String: Any]])?.first)
        XCTAssertEqual(event["event"] as? String, "feed_loaded")
        XCTAssertEqual(event["props"] as? [String: String], ["tab": "for_you", "count": "3"], "subject is not allow-listed")
        XCTAssertTrue(client.pending.isEmpty)
    }

    func testAFailedBatchIsKeptForLater() async {
        let network = StubNetworkClient(error: .api(code: .rateLimited, message: "later", status: 429))
        let client = BatchingAnalyticsClient(network: network, storage: InMemoryStorageClient(), downstream: RecordingAnalyticsClient())
        client.track(.appLaunched)
        let sent = await client.flush()
        XCTAssertEqual(sent, 0)
        XCTAssertEqual(client.pending.count, 1)
    }

    func testEventsOlderThanADayAreDroppedNotSent() async {
        let network = StubNetworkClient(responses: ["{}"])
        final class Clock: @unchecked Sendable { var now = Date() }
        let clock = Clock()
        let client = BatchingAnalyticsClient(network: network, storage: InMemoryStorageClient(),
                                             downstream: RecordingAnalyticsClient(), now: { clock.now })
        client.track(.appLaunched)
        clock.now = clock.now.addingTimeInterval(25 * 3600)
        let sent = await client.flush()
        XCTAssertEqual(sent, 0)
        XCTAssertTrue(client.pending.isEmpty)
        XCTAssertNil(network.lastRequest)
    }

    func testTheInstallIdIsKept() {
        let storage = InMemoryStorageClient()
        let first = BatchingAnalyticsClient(network: StubNetworkClient(), storage: storage)
        let second = BatchingAnalyticsClient(network: StubNetworkClient(), storage: storage)
        XCTAssertEqual(first.anonId, second.anonId)
        XCTAssertEqual(first.anonId.count, 32)
    }
}
