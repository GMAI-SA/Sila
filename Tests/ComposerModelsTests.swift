import XCTest
@testable import Sila

/// The composer's pure logic: counting characters, deciding which audiences an
/// account may open a thread to, and finding the `@mention` being typed.
///
/// All of it is value-type behaviour, so none of these tests need a view, a
/// network or a signed-in session.
final class ComposerModelsTests: XCTestCase {

    // MARK: - Character counting

    func testAnEmptyDraftCannotBePosted() {
        let metrics = ComposerTextMetrics.make("")

        XCTAssertEqual(metrics.count, 0)
        XCTAssertEqual(metrics.remaining, 280)
        XCTAssertTrue(metrics.isEmpty)
        XCTAssertFalse(metrics.canPost)
        XCTAssertNil(metrics.counterText, "A fresh composer shows no counter at all")
    }

    func testWhitespaceOnlyCountsAsEmpty() {
        let metrics = ComposerTextMetrics.make("   \n\t  ")

        XCTAssertTrue(metrics.isEmpty)
        XCTAssertFalse(metrics.canPost, "Whitespace is not a post")
    }

    func testCounterStaysSilentUntilTheWarningBand() {
        let metrics = ComposerTextMetrics.make(String(repeating: "a", count: 259))

        XCTAssertEqual(metrics.remaining, 21)
        XCTAssertFalse(metrics.isNearLimit)
        XCTAssertNil(metrics.counterText)
        XCTAssertTrue(metrics.canPost)
    }

    func testCounterWarnsBeforeTheLimitIsReached() {
        let metrics = ComposerTextMetrics.make(String(repeating: "a", count: 265))

        XCTAssertEqual(metrics.remaining, 15)
        XCTAssertTrue(metrics.isNearLimit, "The warning must arrive before the limit, not at it")
        XCTAssertFalse(metrics.isOverLimit)
        XCTAssertEqual(metrics.counterText, "15")
        XCTAssertTrue(metrics.canPost)
    }

    func testExactlyAtTheLimitIsStillPostable() {
        let metrics = ComposerTextMetrics.make(String(repeating: "a", count: 280))

        XCTAssertEqual(metrics.remaining, 0)
        XCTAssertFalse(metrics.isOverLimit, "280 is the limit, not one past it")
        XCTAssertTrue(metrics.canPost)
        XCTAssertEqual(metrics.progress, 1)
    }

    func testOneCharacterOverTheLimitBlocksPosting() {
        let metrics = ComposerTextMetrics.make(String(repeating: "a", count: 281))

        XCTAssertEqual(metrics.remaining, -1)
        XCTAssertTrue(metrics.isOverLimit)
        XCTAssertFalse(metrics.canPost)
        XCTAssertEqual(metrics.counterText, "-1")
        XCTAssertEqual(metrics.progress, 1, "The ring stays full rather than overflowing")
        // Was "1 characters" before the counter went through the catalog: the
        // old string interpolated the number into a hard-coded plural noun, so
        // English never agreed at a count of one and Arabic could not have
        // agreed at any count. Asserted for a fixed locale, because the whole
        // point of the change is that the sentence is now language-dependent.
        L10n.use("en")
        defer { L10n.use(nil) }
        XCTAssertEqual(metrics.accessibilityValue, "1 character over the 280 character limit")
    }

    func testTheLimitMatchesTheContract() {
        XCTAssertEqual(ComposerConstants.characterLimit, FeedConstants.maximumPostLength)
        XCTAssertEqual(ComposerConstants.characterLimit, 280)
    }

    func testCountingIsByGraphemeClusterSoAnEmojiIsOneCharacter() {
        // The server counts code points, so this is the conservative direction:
        // the client may stop the user early, never late.
        XCTAssertEqual(ComposerTextMetrics.make("👍").count, 1)
        XCTAssertEqual(ComposerTextMetrics.make("🇸🇦").count, 1)
    }

    // MARK: - Scope: with a country badge

    func testAVerifiedSaudiAccountIsOfferedItsOwnCountryAndItsRegions() {
        let author = ComposerAuthor(handle: "aziz", countryCode: "SA", isVerified: true)

        let options = ScopePicker.options(for: author)
        let available = options.filter(\.isAvailable).map(\.scope)

        XCTAssertTrue(available.contains(.international))
        XCTAssertTrue(available.contains(.country("SA")))
        XCTAssertTrue(available.contains(.region(.gcc)), "SA is in the GCC")
        XCTAssertTrue(available.contains(.region(.mena)), "SA is in MENA")
        XCTAssertFalse(available.contains(.region(.eu)), "SA is not in the EU")
    }

    func testTheCountryRowNamesTheAuthorsOwnCountry() throws {
        let author = ComposerAuthor(countryCode: "SA", isVerified: true)

        let option = try XCTUnwrap(
            ScopePicker.options(for: author).first { if case .country = $0.scope { return true } else { return false } }
        )

        XCTAssertTrue(option.isAvailable)
        XCTAssertTrue(option.title.contains("🇸🇦"), "The flag is the point of the row")
        XCTAssertTrue(option.title.contains("Saudi Arabia"))
        XCTAssertNil(option.unavailableReason)
    }

    func testACountryScopeCarriesTheCodeOnTheWire() {
        let scope = ComposeScope.country("sa")

        XCTAssertEqual(scope.wireValue, "country")
        XCTAssertEqual(scope.scopeCountry, "SA", "Codes are normalised before they are sent")
        XCTAssertNil(scope.scopeRegion)
    }

    func testARegionScopeCarriesTheRegionOnTheWire() {
        let scope = ComposeScope.region(.gcc)

        XCTAssertEqual(scope.wireValue, "region")
        XCTAssertEqual(scope.scopeRegion, "GCC")
        XCTAssertNil(scope.scopeCountry)
    }

    // MARK: - Scope: without a country badge

    func testAnAccountWithNoBadgeIsOfferedInternationalOnly() {
        let author = ComposerAuthor(handle: "newcomer", countryCode: nil, isVerified: false)

        let options = ScopePicker.options(for: author)
        let available = options.filter(\.isAvailable).map(\.scope)

        XCTAssertEqual(available, [.international], "Everything else needs a verified country")
    }

    func testTheCountryRowIsShownAndExplainedRatherThanHidden() throws {
        let author = ComposerAuthor(countryCode: nil, isVerified: false)

        let options = ScopePicker.options(for: author)

        XCTAssertEqual(options.count, 5, "International + My Country + three regions, always all five")

        let country = try XCTUnwrap(options.first { $0.title == "My Country" })
        XCTAssertFalse(country.isAvailable)
        let reason = try XCTUnwrap(country.unavailableReason)
        XCTAssertTrue(
            reason.contains("identity verification"),
            "The user must learn the badge comes from verification, not from where they are"
        )
    }

    func testEveryRegionIsExplainedWhenTheAccountHasNoBadge() {
        let author = ComposerAuthor(countryCode: nil, isVerified: false)

        let regions = ScopePicker.options(for: author).filter {
            if case .region = $0.scope { return true } else { return false }
        }

        XCTAssertEqual(regions.count, 3)
        for region in regions {
            XCTAssertFalse(region.isAvailable)
            XCTAssertNotNil(region.unavailableReason, "A locked row without a reason is a dead control")
        }
    }

    func testAnOutOfRegionCountryGetsASpecificReason() throws {
        let author = ComposerAuthor(countryCode: "JP", isVerified: true)

        let eu = try XCTUnwrap(ScopePicker.options(for: author).first { $0.scope == .region(.eu) })

        XCTAssertFalse(eu.isAvailable)
        let reason = try XCTUnwrap(eu.unavailableReason)
        XCTAssertTrue(reason.contains("Japan"), "The reason names the country the badge actually carries")
    }

    func testAVerifiedJapaneseAccountStillGetsInternational() {
        let author = ComposerAuthor(countryCode: "JP", isVerified: true)

        XCTAssertTrue(ScopePicker.isAvailable(.international, for: author))
        XCTAssertTrue(ScopePicker.isAvailable(.country("JP"), for: author))
        XCTAssertFalse(ScopePicker.isAvailable(.region(.gcc), for: author))
    }

    func testTheDefaultScopeIsTheWidestOneAlwaysAvailable() {
        XCTAssertEqual(ScopePicker.defaultScope(for: ComposerAuthor(isVerified: false)), .international)
        XCTAssertEqual(
            ScopePicker.defaultScope(for: ComposerAuthor(countryCode: "SA", isVerified: true)),
            .international
        )
    }

    func testAGarbageCountryCodeNeverProducesACountryOption() {
        // `ZZ` passes `Locale.Region.isISORegion` but is not a real country.
        let author = ComposerAuthor(countryCode: "ZZ", isVerified: true)

        XCTAssertNil(author.countryCode)
        XCTAssertFalse(author.hasCountryBadge)
        XCTAssertEqual(ScopePicker.options(for: author).filter(\.isAvailable).map(\.scope), [.international])
    }

    // MARK: - Region membership

    func testRegionMembershipIsCaseInsensitiveAndRejectsNil() {
        XCTAssertTrue(GeoRegion.gcc.contains("ae"))
        XCTAssertTrue(GeoRegion.eu.contains("DE"))
        XCTAssertFalse(GeoRegion.gcc.contains(nil))
        XCTAssertFalse(GeoRegion.eu.contains("SA"))
    }

    func testRegionsContainingACountryAreListedInOrder() {
        XCTAssertEqual(GeoRegion.regions(containing: "SA"), [.gcc, .mena])
        XCTAssertEqual(GeoRegion.regions(containing: "FR"), [.eu])
        XCTAssertEqual(GeoRegion.regions(containing: "JP"), [])
    }

    func testRegionParsingToleratesCaseAndRejectsJunk() {
        XCTAssertEqual(GeoRegion.parse("gcc"), .gcc)
        XCTAssertEqual(GeoRegion.parse(" MENA "), .mena)
        XCTAssertNil(GeoRegion.parse("ASEAN"))
        XCTAssertNil(GeoRegion.parse(nil))
    }

    // MARK: - Inherited scope

    func testAReplyInheritsACountryThreadsScope() {
        let parent = FeedServiceMock.countryThread

        XCTAssertEqual(ComposeScope.inherited(from: parent), .country("SA"))
    }

    func testAReplyInheritsARegionThreadsScope() {
        XCTAssertEqual(ComposeScope.inherited(from: FeedServiceMock.regionThread), .region(.gcc))
    }

    func testAReplyToAnInternationalThreadStaysInternational() {
        XCTAssertEqual(ComposeScope.inherited(from: FeedServiceMock.internationalRoot), .international)
    }

    // MARK: - Mention detection

    func testAMentionAtTheEndOfTheTextIsDetected() {
        XCTAssertEqual(MentionDetector.activeQuery(in: "hello @az"), "az")
        XCTAssertEqual(MentionDetector.activeQuery(in: "@az"), "az")
        XCTAssertEqual(MentionDetector.activeQuery(in: "@"), "")
    }

    func testACompletedMentionFollowedByASpaceIsNotActive() {
        XCTAssertNil(MentionDetector.activeQuery(in: "hello @aziz "))
        XCTAssertNil(MentionDetector.activeQuery(in: "hello @aziz how are you"))
    }

    func testAnEmailAddressDoesNotOpenTheSuggestionList() {
        XCTAssertNil(MentionDetector.activeQuery(in: "write to me@example"))
    }

    func testTextWithNoSigilHasNoActiveMention() {
        XCTAssertNil(MentionDetector.activeQuery(in: "just some words"))
    }

    func testAQueryUnderTwoCharactersIsNotSearchable() {
        XCTAssertFalse(MentionDetector.isSearchable(""))
        XCTAssertFalse(MentionDetector.isSearchable("a"))
        XCTAssertTrue(MentionDetector.isSearchable("az"))
        XCTAssertEqual(MentionDetector.minimumQueryLength, SearchConstants.minimumQueryLength)
    }

    // MARK: - Mention insertion

    func testInsertingAHandleReplacesThePartialMentionAndAddsASpace() {
        let result = MentionDetector.inserting(handle: "aziz", into: "hello @az")

        XCTAssertEqual(result, "hello @aziz ")
    }

    func testInsertingAcceptsAHandleThatAlreadyCarriesTheSigil() {
        XCTAssertEqual(MentionDetector.inserting(handle: "@aziz", into: "@a"), "@aziz ")
    }

    func testInsertingDoesNothingWhenNoMentionIsInProgress() {
        XCTAssertEqual(
            MentionDetector.inserting(handle: "aziz", into: "no mention here"),
            "no mention here"
        )
    }

    // MARK: - Request body

    func testTheRequestBodyOmitsEverythingTheDraftDoesNotCarry() throws {
        let body = CreatePostBody(draft: PostDraft(text: "  hello  ", scope: .international))

        let json = try JSONSerialization.jsonObject(
            with: try JSONCoding.encoder.encode(body)
        ) as? [String: Any]

        XCTAssertEqual(json?["text"] as? String, "hello", "The text is trimmed before it is sent")
        XCTAssertEqual(json?["scope"] as? String, "international")
        XCTAssertNil(json?["scope_country"], "A nil optional is omitted, not sent as null")
        XCTAssertNil(json?["scope_region"])
        XCTAssertNil(json?["reply_to_post_id"])
        XCTAssertNil(json?["quoted_post_id"])
    }

    func testTheRequestBodySendsSnakeCaseAndLowercaseIds() throws {
        let parent = UUID()
        let quoted = UUID()
        let body = CreatePostBody(
            draft: PostDraft(
                text: "hi",
                scope: .country("SA"),
                replyToPostId: parent,
                quotedPostId: quoted
            )
        )

        let json = try JSONSerialization.jsonObject(
            with: try JSONCoding.encoder.encode(body)
        ) as? [String: Any]

        XCTAssertEqual(json?["scope"] as? String, "country")
        XCTAssertEqual(json?["scope_country"] as? String, "SA")
        XCTAssertEqual(json?["reply_to_post_id"] as? String, parent.uuidString.lowercased())
        XCTAssertEqual(json?["quoted_post_id"] as? String, quoted.uuidString.lowercased())
    }

    // MARK: - Thread report

    func testACleanSinglePostNeedsNoSummary() {
        let report = ThreadPostReport(posted: [FeedServiceMock.internationalRoot])

        XCTAssertTrue(report.isCompleteSuccess)
        XCTAssertFalse(report.isPartialFailure)
        XCTAssertNil(report.summary, "One post that worked closes the sheet without a speech")
    }

    func testAPartialFailureSaysHowManyPostsAreAlreadyLive() throws {
        let report = ThreadPostReport(
            posted: [FeedServiceMock.internationalRoot, FeedServiceMock.replyFromJapan],
            remaining: ["three", "four", "five"],
            error: .api(code: .rateLimited, message: "Slow down", status: 429)
        )

        XCTAssertFalse(report.isCompleteSuccess)
        XCTAssertTrue(report.isPartialFailure)
        XCTAssertEqual(report.totalSegments, 5)
        XCTAssertEqual(report.continuationId, FeedServiceMock.replyFromJapan.id)

        let summary = try XCTUnwrap(report.summary)
        XCTAssertTrue(summary.contains("Posted 2 of 5"), "got: \(summary)")
    }

    func testATotalFailureReportsTheErrorAndNothingPosted() throws {
        let report = ThreadPostReport(
            posted: [],
            remaining: ["one"],
            error: .api(code: .unverified, message: "no", status: 403)
        )

        XCTAssertFalse(report.isPartialFailure)
        XCTAssertNil(report.continuationId)
        XCTAssertEqual(report.summary, APIError.api(code: .unverified, message: "no", status: 403).userMessage)
    }
}
