import XCTest
@testable import Sila

/// Drives the deployed preferences API through the app's own service.
///
/// The fixture tests agree with the contract by construction; these are the
/// only ones that would notice the server disagreeing. That matters more here
/// than elsewhere: these settings decide what a person is shown, so a mismatch
/// doesn't produce an error, it quietly changes someone's feed.
///
/// Opt-in, and restores the account's original settings afterwards:
/// ```
/// TEST_RUNNER_SILA_LIVE_API=1 TEST_RUNNER_SILA_LIVE_EMAIL=… \
/// TEST_RUNNER_SILA_LIVE_PASSWORD=… xcodebuild … test
/// ```
final class LivePreferencesTests: XCTestCase {

    private var token: String?
    private var original: FeedPreferences?

    override func setUp() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["SILA_LIVE_API"] == "1" else {
            throw XCTSkip("Live API tests are opt-in — set SILA_LIVE_API=1")
        }
        guard let email = env["SILA_LIVE_EMAIL"],
              let password = env["SILA_LIVE_PASSWORD"] else {
            throw XCTSkip("Set SILA_LIVE_EMAIL and SILA_LIVE_PASSWORD")
        }
        let auth = AuthService(
            network: URLSessionNetworkClient(),
            store: AuthTokenStore(keychain: InMemoryKeychainClient(), storage: InMemoryStorageClient()),
            biometrics: StubBiometricAuthenticator(),
            analytics: RecordingAnalyticsClient()
        )
        token = try await auth.signIn(email: email, password: password).token.accessToken
        original = try await service().fetchPreferences()
    }

    override func tearDown() async throws {
        // Never leave someone's real feed narrowed by a test run.
        guard let original, let token, !token.isEmpty else { return }
        _ = try? await service().updatePreferences(
            PreferencesUpdate(
                topics: original.topicPayload,
                filterInternationalByInterests: original.filterInternationalByInterests,
                showUntaggedPosts: original.showUntaggedPosts,
                mutedCountries: original.mutedCountries
            )
        )
    }

    private func service() throws -> PreferencesService {
        PreferencesService(
            network: URLSessionNetworkClient(),
            tokens: StaticAccessTokenProvider(token: try XCTUnwrap(token)),
            analytics: RecordingAnalyticsClient()
        )
    }

    private func feed() throws -> FeedService {
        FeedService(
            network: URLSessionNetworkClient(),
            tokens: StaticAccessTokenProvider(token: try XCTUnwrap(token)),
            analytics: RecordingAnalyticsClient()
        )
    }

    /// The picker is built from this list; an id the client doesn't recognise
    /// would render a blank row.
    func testTheTaxonomyDecodes() async throws {
        let topics = try await service().fetchTopics()
        XCTAssertEqual(topics.count, 20)
        for topic in topics {
            XCTAssertTrue(topic.isValid)
            XCTAssertFalse(topic.detail.isEmpty, "\(topic.id) has no description to show")
        }
    }

    func testPreferencesRoundTrip() async throws {
        let service = try service()
        let saved = try await service.updatePreferences(
            PreferencesUpdate(
                topics: [
                    TopicStancePayload(topic: "technology", stance: "interested"),
                    TopicStancePayload(topic: "politics", stance: "muted"),
                ],
                filterInternationalByInterests: true,
                showUntaggedPosts: false,
                mutedCountries: ["JP"]
            )
        )
        XCTAssertEqual(saved.interests, ["technology"])
        XCTAssertEqual(saved.mutedTopics, ["politics"])
        XCTAssertTrue(saved.filterInternationalByInterests)
        XCTAssertFalse(saved.showUntaggedPosts)
        XCTAssertEqual(saved.mutedCountries, ["JP"])

        // A second read must agree with the write, not just the response.
        let reread = try await service.fetchPreferences()
        XCTAssertEqual(reread, saved)
    }

    /// `topics` replaces rather than merges — otherwise unchecking a topic is
    /// not expressible and a stance can never be withdrawn.
    func testSavingTopicsReplacesTheWholeSet() async throws {
        let service = try service()
        _ = try await service.updatePreferences(
            PreferencesUpdate(topics: [
                TopicStancePayload(topic: "sports", stance: "interested"),
                TopicStancePayload(topic: "food", stance: "muted"),
            ])
        )
        let after = try await service.updatePreferences(
            PreferencesUpdate(topics: [TopicStancePayload(topic: "sports", stance: "interested")])
        )
        XCTAssertEqual(after.interests, ["sports"])
        XCTAssertEqual(after.mutedTopics, [], "food should be gone, not carried forward")
    }

    /// The screen's central honesty claim, checked against the real server.
    func testTheFilterOnWithNothingSelectedDoesNotEmptyTheFeed() async throws {
        _ = try await service().updatePreferences(
            PreferencesUpdate(topics: [], filterInternationalByInterests: true)
        )
        let page = try await feed().fetchFeed(.international, cursor: nil, limit: 20)
        XCTAssertFalse(
            page.posts.isEmpty,
            "the switch is on with nothing chosen — the feed must still show everything"
        )
    }

    /// Choosing an interest really does narrow the feed.
    ///
    /// Note: the backend also offers `?unfiltered=true` as a per-request
    /// escape hatch, which `FeedService` does not currently send — so this
    /// compares against the filter-off state instead.
    func testInterestsNarrowTheFeed() async throws {
        let service = try service()
        let feed = try feed()

        _ = try await service.updatePreferences(
            PreferencesUpdate(topics: [], filterInternationalByInterests: false)
        )
        let everything = try await feed.fetchFeed(.international, cursor: nil, limit: 20)

        _ = try await service.updatePreferences(
            PreferencesUpdate(
                topics: [TopicStancePayload(topic: "sports", stance: "interested")],
                filterInternationalByInterests: true,
                showUntaggedPosts: false
            )
        )
        let filtered = try await feed.fetchFeed(.international, cursor: nil, limit: 20)

        XCTAssertLessThan(
            filtered.posts.count, everything.posts.count,
            "a narrow interest should show fewer posts than an unfiltered feed"
        )
    }

    /// The client refuses these before sending; the server refuses them too.
    /// Both matter — a stored `ZZ` is a mute that can never fire.
    func testPlaceholderCountryCodesAreRefused() async throws {
        do {
            _ = try await service().updatePreferences(PreferencesUpdate(mutedCountries: ["ZZ"]))
            XCTFail("server accepted ZZ, which matches no verified badge")
        } catch let error as APIError {
            XCTAssertEqual(error.code, .invalidCountry)
        }
    }

    func testAnUnknownTopicIsRefused() async throws {
        do {
            _ = try await service().updatePreferences(
                PreferencesUpdate(topics: [TopicStancePayload(topic: "astrology", stance: "interested")])
            )
            XCTFail("server accepted a topic outside the taxonomy")
        } catch let error as APIError {
            XCTAssertEqual(error.code, .unknownTopic)
        }
    }
}
