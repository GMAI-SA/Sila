import XCTest
@testable import TrustNet

/// The wire contract with contract v4 (`/topics`, `/me/preferences`) and the
/// request construction around it.
///
/// Uses ``StubNetworkClient`` from `FeedServiceTests`, so paths, verbs, tokens
/// and — most importantly — the exact shape of the `PUT` body are asserted
/// without a server.
final class PreferencesServiceTests: XCTestCase {

    private func makeService(
        _ network: StubNetworkClient,
        token: String? = "prefs-token"
    ) -> PreferencesService {
        PreferencesService(
            network: network,
            tokens: StaticAccessTokenProvider(token: token),
            analytics: RecordingAnalyticsClient()
        )
    }

    private func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        try JSONCoding.decoder.decode(T.self, from: Data(json.utf8))
    }

    /// The `PUT` body as a dictionary, which is what the server actually parses.
    private func body(of request: APIRequest?) throws -> [String: Any] {
        let data = try XCTUnwrap(request?.body, "the request carried no body")
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [String: Any], "the body was not a JSON object")
    }

    // MARK: - GET /topics

    func testTopicsDecodeIdsAndDescriptionsAndDeriveTheirOwnLabels() throws {
        let response = try decode(TopicsResponse.self, from: """
        {"topics": [
          {"id": "technology", "description": "Software, hardware, AI, startups, engineering"},
          {"id": "real_estate", "description": "Property, housing, construction, land"}
        ]}
        """)

        XCTAssertEqual(response.topics.map(\.id), ["technology", "real_estate"])
        XCTAssertEqual(response.topics.first?.detail, "Software, hardware, AI, startups, engineering")
        XCTAssertEqual(
            response.topics.last?.label,
            "Real estate",
            "Labels are derived on the client because the contract says server labels are not stable"
        )
    }

    func testAMissingTopicsKeyDecodesAsEmptyRatherThanFailing() throws {
        XCTAssertTrue(try decode(TopicsResponse.self, from: "{}").topics.isEmpty)
    }

    func testATopicRowWithNoIdIsDroppedRatherThanRenderedAsANamelessControl() throws {
        let response = try decode(TopicsResponse.self, from: """
        {"topics": [{"id": "", "description": "nothing"}, {"id": "food", "description": "Cooking"}]}
        """)

        XCTAssertEqual(response.topics.map(\.id), ["food"])
    }

    func testTopicsHitTheDocumentedPathWithTheBearerToken() async throws {
        let network = StubNetworkClient(responses: ["{\"topics\": []}"])

        _ = try await makeService(network).fetchTopics()

        XCTAssertEqual(network.lastRequest?.path, "/topics")
        XCTAssertEqual(network.lastRequest?.method, .get)
        XCTAssertEqual(network.lastRequest?.accessToken, "prefs-token")
    }

    // MARK: - GET /me/preferences

    func testPreferencesDecodeEveryFieldTheFilterRunsOn() throws {
        let prefs = try decode(FeedPreferences.self, from: """
        {"interests": ["technology", "science"],
         "muted_topics": ["politics"],
         "filter_international_by_interests": true,
         "show_untagged_posts": false,
         "muted_countries": ["JP", "SA"]}
        """)

        XCTAssertEqual(prefs.interests, ["science", "technology"], "Sorted so a round trip is not an edit")
        XCTAssertEqual(prefs.mutedTopics, ["politics"])
        XCTAssertTrue(prefs.filterInternationalByInterests)
        XCTAssertFalse(prefs.showUntaggedPosts)
        XCTAssertEqual(prefs.mutedCountries, ["JP", "SA"])
    }

    func testEmptyArraysDecodeIntoTheServersOwnDefaultBehaviour() throws {
        let prefs = try decode(FeedPreferences.self, from: """
        {"interests": [], "muted_topics": [],
         "filter_international_by_interests": false,
         "show_untagged_posts": true, "muted_countries": []}
        """)

        XCTAssertEqual(prefs, FeedPreferences())
        XCTAssertFalse(prefs.narrowsToInterests)
        XCTAssertFalse(prefs.changesInternationalFeed)
    }

    func testMissingKeysFallBackToTheServersDefaultsInsteadOfFailingTheDecode() throws {
        let prefs = try decode(FeedPreferences.self, from: "{}")

        XCTAssertTrue(prefs.interests.isEmpty)
        XCTAssertFalse(prefs.filterInternationalByInterests, "Off by default, per the contract")
        XCTAssertTrue(prefs.showUntaggedPosts, "Untagged posts are shown by default, per the contract")
    }

    func testAnUnknownTopicIdFromTheServerDecodesWithoutCrashingAndIsThenIgnored() throws {
        let prefs = try decode(FeedPreferences.self, from: """
        {"interests": ["technology", "quantum_basketry"], "muted_topics": ["fictional_topic"],
         "filter_international_by_interests": true, "show_untagged_posts": true,
         "muted_countries": []}
        """)

        // Decoding keeps whatever arrived — throwing here would make one stale
        // row block the whole screen.
        XCTAssertEqual(prefs.interests, ["quantum_basketry", "technology"])

        let known: Set<String> = ["technology", "science", "politics"]
        XCTAssertEqual(prefs.unknownTopicIds(against: known), ["fictional_topic", "quantum_basketry"])

        let usable = prefs.limited(to: known)
        XCTAssertEqual(usable.interests, ["technology"], "Unknown ids never reach the picker")
        XCTAssertTrue(usable.mutedTopics.isEmpty)
        XCTAssertTrue(
            usable.topicPayload.allSatisfy { known.contains($0.topic) },
            "Sending one back would make the server reject the entire PUT with unknown_topic"
        )
    }

    func testAnUnrecognisedMutedCountryIsDroppedRatherThanShownAsAFlaglessChip() throws {
        let prefs = try decode(FeedPreferences.self, from: """
        {"interests": [], "muted_topics": [], "filter_international_by_interests": false,
         "show_untagged_posts": true, "muted_countries": ["JP", "ZZ", "sa"]}
        """)

        XCTAssertEqual(prefs.mutedCountries, ["JP", "SA"], "ZZ is a CLDR placeholder, not a country")
    }

    func testPreferencesHitTheDocumentedPath() async throws {
        let network = StubNetworkClient(responses: ["{}"])

        _ = try await makeService(network).fetchPreferences()

        XCTAssertEqual(network.lastRequest?.path, "/me/preferences")
        XCTAssertEqual(network.lastRequest?.method, .get)
    }

    func testASignedOutCallerNeverReachesTheNetwork() async {
        let network = StubNetworkClient(responses: ["{}"])

        do {
            _ = try await makeService(network, token: nil).fetchPreferences()
            XCTFail("Expected the missing token to throw")
        } catch {
            XCTAssertEqual(error as? APIError, .unauthenticated)
            XCTAssertTrue(network.requests.isEmpty)
        }
    }

    // MARK: - PUT /me/preferences

    private static let storedResponse = """
    {"interests": ["technology"], "muted_topics": ["politics"],
     "filter_international_by_interests": true, "show_untagged_posts": false,
     "muted_countries": ["JP"]}
    """

    func testTheUpdateIsAPutToTheDocumentedPathWithTheBearerToken() async throws {
        let network = StubNetworkClient(responses: [Self.storedResponse])

        _ = try await makeService(network).updatePreferences(
            PreferencesUpdate(filterInternationalByInterests: true)
        )

        XCTAssertEqual(network.lastRequest?.path, "/me/preferences")
        XCTAssertEqual(network.lastRequest?.method, .put)
        XCTAssertEqual(network.lastRequest?.accessToken, "prefs-token")
    }

    func testATopicWithNoStanceIsAbsentFromTheBodyRatherThanSentAsNull() async throws {
        let network = StubNetworkClient(responses: [Self.storedResponse])
        // technology interested, politics muted, science deliberately cleared.
        let preferences = FeedPreferences(
            interests: ["technology"],
            mutedTopics: ["politics"]
        ).setting(TopicStance.none, for: "science")

        _ = try await makeService(network).updatePreferences(.replacing(preferences))

        let sent = try body(of: network.lastRequest)
        let topics = try XCTUnwrap(sent["topics"] as? [[String: Any]])
        XCTAssertEqual(topics.count, 2)
        XCTAssertEqual(
            topics.compactMap { $0["topic"] as? String },
            ["politics", "technology"]
        )
        XCTAssertEqual(
            topics.compactMap { $0["stance"] as? String },
            ["muted", "interested"]
        )
        XCTAssertFalse(
            topics.contains { ($0["topic"] as? String) == "science" },
            "'topics' is a full replacement — absence is how 'no opinion' is expressed"
        )
        XCTAssertTrue(
            topics.allSatisfy { $0["stance"] is String },
            "A null stance is not part of the contract"
        )
    }

    func testClearingEveryStanceSendsAnEmptyArrayNotAnOmittedField() async throws {
        let network = StubNetworkClient(responses: [Self.storedResponse])

        _ = try await makeService(network).updatePreferences(.replacing(FeedPreferences()))

        let sent = try body(of: network.lastRequest)
        let topics = try XCTUnwrap(sent["topics"] as? [[String: Any]])
        XCTAssertTrue(
            topics.isEmpty,
            "Omitting 'topics' means 'leave stances alone'; an empty array means 'clear them'"
        )
    }

    func testAPartialUpdateOmitsTheFieldsItIsNotChanging() async throws {
        let network = StubNetworkClient(responses: [Self.storedResponse])

        _ = try await makeService(network).updatePreferences(
            PreferencesUpdate(showUntaggedPosts: false)
        )

        let sent = try body(of: network.lastRequest)
        XCTAssertEqual(sent["show_untagged_posts"] as? Bool, false)
        XCTAssertNil(sent["topics"], "A nil field must not be encoded, or it would clear the stances")
        XCTAssertNil(sent["filter_international_by_interests"])
        XCTAssertNil(sent["muted_countries"])
    }

    func testTheBodyUsesTheSnakeCaseKeysTheServerParses() async throws {
        let network = StubNetworkClient(responses: [Self.storedResponse])

        _ = try await makeService(network).updatePreferences(
            .replacing(FeedPreferences(
                filterInternationalByInterests: true,
                showUntaggedPosts: false,
                mutedCountries: ["JP"]
            ))
        )

        let sent = try body(of: network.lastRequest)
        XCTAssertEqual(sent["filter_international_by_interests"] as? Bool, true)
        XCTAssertEqual(sent["show_untagged_posts"] as? Bool, false)
        XCTAssertEqual(sent["muted_countries"] as? [String], ["JP"])
    }

    func testTheResponseIsAdoptedRatherThanTheLocallyGuessedValue() async throws {
        let network = StubNetworkClient(responses: [Self.storedResponse])

        let stored = try await makeService(network).updatePreferences(
            .replacing(FeedPreferences(interests: ["technology", "gaming"]))
        )

        XCTAssertEqual(
            stored.interests,
            ["technology"],
            "What the server says it stored wins over what the client asked for"
        )
        XCTAssertEqual(stored.mutedCountries, ["JP"])
    }

    // MARK: - Errors

    func testTheContractsErrorCodesDecodeAndCarryAUserSafeSentence() {
        let unknownTopic = URLSessionNetworkClient.makeError(
            status: 400,
            data: Data("""
            {"detail": {"code": "unknown_topic", "message": "Not topics in this taxonomy: nope"}}
            """.utf8)
        )
        XCTAssertEqual(unknownTopic.code, .unknownTopic)
        XCTAssertTrue(
            unknownTopic.userMessage.contains("nothing was saved"),
            "The whole PUT is rejected, so the message must not imply a partial write"
        )

        let invalidCountry = URLSessionNetworkClient.makeError(
            status: 400,
            data: Data("""
            {"detail": {"code": "invalid_country", "message": "Expected ISO-3166 alpha-2 codes: JPN"}}
            """.utf8)
        )
        XCTAssertEqual(invalidCountry.code, .invalidCountry)
        XCTAssertFalse(invalidCountry.userMessage.isEmpty)
    }

    // MARK: - The mock

    func testTheMockServesTheFullTwentyTopicTaxonomy() async throws {
        let topics = try await PreferencesServiceMock(scenario: .populated).fetchTopics()

        XCTAssertEqual(topics.count, 20, "The screen's whole layout problem is twenty rows")
        XCTAssertEqual(Set(topics.map(\.id)).count, 20)
    }

    func testTheMockAppliesFullReplacementSemanticsLikeTheServer() async throws {
        let mock = PreferencesServiceMock(scenario: .populated)
        _ = try await mock.fetchPreferences()

        let stored = try await mock.updatePreferences(
            PreferencesUpdate(topics: [TopicStancePayload(topic: "gaming", stance: "interested")])
        )

        XCTAssertEqual(stored.interests, ["gaming"], "The previous interests are replaced, not merged")
        XCTAssertTrue(stored.mutedTopics.isEmpty, "A stance left out of the array is gone")
        XCTAssertTrue(
            stored.filterInternationalByInterests,
            "Fields the body omitted keep their value"
        )
    }

    func testTheOfflineMockFailsEveryCall() async {
        let mock = PreferencesServiceMock(scenario: .offline)
        do {
            _ = try await mock.fetchTopics()
            XCTFail("Expected the offline scenario to throw")
        } catch {
            XCTAssertEqual(APIError.wrapping(error).code, nil)
        }
    }

    func testTheSaveFailsMockLoadsButRefusesToStore() async throws {
        let mock = PreferencesServiceMock(scenario: .saveFails)

        let topics = try await mock.fetchTopics()
        XCTAssertFalse(topics.isEmpty)
        do {
            _ = try await mock.updatePreferences(.replacing(FeedPreferences()))
            XCTFail("Expected the save to fail")
        } catch {
            XCTAssertEqual((error as? APIError)?.code, .unknownTopic)
        }
    }

    func testTheEmptyMockStartsFromTheServersDefaults() async throws {
        let stored = try await PreferencesServiceMock(scenario: .empty).fetchPreferences()

        XCTAssertEqual(stored, FeedPreferences())
    }
}
