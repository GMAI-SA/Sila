import XCTest
@testable import TrustNet

/// The pure mappings the feed's UI is built from: country flags, scope chips,
/// reply permissions, relative timestamps and inline entity parsing.
final class PostPresentationTests: XCTestCase {

    // MARK: Country-verified flag

    func testKnownCodesProduceTheirFlag() {
        XCTAssertEqual(CountryCode.flag("SA"), "🇸🇦")
        XCTAssertEqual(CountryCode.flag("JP"), "🇯🇵")
        XCTAssertEqual(CountryCode.flag("br"), "🇧🇷")
    }

    func testNothingIsRenderedWhenThereIsNoVerifiedCountry() {
        // The product's core honesty rule: never guess a flag.
        for input in [nil, "", " ", "S", "SAU", "12", "ZZ", "??"] as [String?] {
            XCTAssertNil(CountryCode.normalised(input), "\(input ?? "nil") should not normalise")
            XCTAssertNil(CountryCode.flag(input), "\(input ?? "nil") must render no flag")
            XCTAssertNil(CountryCode.accessibilityLabel(input))
        }
    }

    func testTheFlagIsNormalisedIndependentlyOfCase() {
        XCTAssertEqual(CountryCode.normalised(" sa "), "SA")
        XCTAssertEqual(CountryCode.flag(" sa "), CountryCode.flag("SA"))
    }

    func testTheAccessibilityLabelNamesVerificationNotLocation() {
        let label = CountryCode.accessibilityLabel("SA", locale: Locale(identifier: "en_US"))
        XCTAssertEqual(label, "Identity verified in Saudi Arabia")
    }

    // MARK: Scope → chip

    func testAnInternationalPostSaysSo() {
        let presentation = ScopePresentation.make(for: FeedFixture.post(scope: .international))

        XCTAssertEqual(presentation.icon, "globe")
        XCTAssertEqual(presentation.label, "International")
        XCTAssertTrue(presentation.accessibilityLabel.contains("Any verified account can reply"))
    }

    func testACountryPostNamesItsCountryWithTheFlag() {
        let post = FeedFixture.post(scope: .country, scopeCountry: "SA")
        let presentation = ScopePresentation.make(for: post)
        let name = CountryCode.name("SA") ?? "SA"

        XCTAssertEqual(presentation.icon, "flag.fill")
        XCTAssertEqual(presentation.label, "🇸🇦 \(name) only")
    }

    func testACountryPostWithoutAUsableCodeDoesNotInventAFlag() {
        let post = FeedFixture.post(scope: .country, scopeCountry: nil)
        let presentation = ScopePresentation.make(for: post)

        XCTAssertEqual(presentation.label, "Country thread")
        XCTAssertFalse(presentation.label.contains("🇺"), "No flag may be conjured from a missing code")
    }

    func testARegionPostNamesItsRegion() {
        let post = FeedFixture.post(scope: .region, scopeRegion: "gcc")

        XCTAssertEqual(ScopePresentation.make(for: post).label, "GCC region")
    }

    func testEveryScopeProducesANonEmptyPresentation() {
        for scope in PostScope.allCases {
            let presentation = ScopePresentation.make(for: FeedFixture.post(scope: scope))
            XCTAssertFalse(presentation.icon.isEmpty, "\(scope) has no icon")
            XCTAssertFalse(presentation.label.isEmpty, "\(scope) has no label")
            XCTAssertFalse(presentation.accessibilityLabel.isEmpty, "\(scope) has no accessibility label")
        }
    }

    // MARK: can_reply → UI

    func testARepliablePostHasNoBlockedMessage() {
        let permission = ReplyPermission.make(
            for: FeedFixture.post(viewer: PostViewerState(canReply: true))
        )

        XCTAssertTrue(permission.canReply)
        XCTAssertNil(permission.blockedMessage)
    }

    func testACountryMismatchNamesTheCountryThatMayReply() {
        let post = FeedFixture.post(
            scope: .country,
            scopeCountry: "SA",
            viewer: PostViewerState(canReply: false, replyBlockReason: .countryMismatch)
        )
        let permission = ReplyPermission.make(for: post)
        let name = CountryCode.name("SA") ?? "SA"

        XCTAssertFalse(permission.canReply)
        XCTAssertEqual(
            permission.blockedMessage,
            "Only 🇸🇦 \(name)-verified accounts can reply to this thread."
        )
    }

    func testARegionMismatchNamesTheRegion() {
        let post = FeedFixture.post(
            scope: .region,
            scopeRegion: "GCC",
            viewer: PostViewerState(canReply: false, replyBlockReason: .regionMismatch)
        )

        XCTAssertEqual(
            ReplyPermission.make(for: post).blockedMessage,
            "Only accounts verified in the GCC region can reply to this thread."
        )
    }

    func testAnUnverifiedViewerIsToldToVerifyNotThatTheyAreBanned() {
        let post = FeedFixture.post(
            viewer: PostViewerState(canReply: false, replyBlockReason: .unverified)
        )
        let message = try? XCTUnwrap(ReplyPermission.make(for: post).blockedMessage)

        XCTAssertEqual(message?.contains("Verify your identity"), true)
    }

    func testEveryBlockReasonProducesASentence() {
        let reasons: [ReplyBlockReason?] = [
            .countryMismatch, .regionMismatch, .unverified, .unknown, nil
        ]
        for reason in reasons {
            let message = ReplyPermission.message(for: reason, scopeCountry: "SA", scopeRegion: "GCC")
            XCTAssertFalse(message.isEmpty, "\(String(describing: reason)) has no sentence")
        }
    }

    func testABlockReasonWithNoUsableCountryStillExplainsItself() {
        let message = ReplyPermission.message(
            for: .countryMismatch,
            scopeCountry: nil,
            scopeRegion: nil
        )

        XCTAssertEqual(message, "Only accounts verified in this thread's country can reply.")
    }

    // MARK: Relative time

    func testRelativeTimestampsUseTheFeedIdiom() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        XCTAssertEqual(RelativeTime.short(now, relativeTo: now), "now")
        XCTAssertEqual(RelativeTime.short(now.addingTimeInterval(-45), relativeTo: now), "45s")
        XCTAssertEqual(RelativeTime.short(now.addingTimeInterval(-60 * 12), relativeTo: now), "12m")
        XCTAssertEqual(RelativeTime.short(now.addingTimeInterval(-3_600 * 2), relativeTo: now), "2h")
        XCTAssertEqual(RelativeTime.short(now.addingTimeInterval(-86_400 * 3), relativeTo: now), "3d")
        XCTAssertEqual(RelativeTime.short(now.addingTimeInterval(-604_800 * 5), relativeTo: now), "5w")
    }

    func testAFutureTimestampReadsAsNowRatherThanNegative() {
        let now = Date()
        XCTAssertEqual(RelativeTime.short(now.addingTimeInterval(30), relativeTo: now), "now")
    }

    func testAYearOldPostFallsBackToAnAbsoluteDate() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = now.addingTimeInterval(-86_400 * 500)

        let rendered = RelativeTime.short(old, relativeTo: now)

        XCTAssertFalse(rendered.hasSuffix("w"), "Beyond a year we show a date, not 71w")
        XCTAssertFalse(rendered.isEmpty)
    }

    // MARK: Inline entities

    func testMentionsAndHashtagsAreExtracted() {
        let tokens = PostTextParser.tokenize("Hey @aziz look at #ProofOfPersonhood today")

        XCTAssertTrue(tokens.contains(.mention("aziz")))
        XCTAssertTrue(tokens.contains(.hashtag("ProofOfPersonhood")))
    }

    func testTokenizingIsLossless() {
        let inputs = [
            "Hey @aziz look at #tag",
            "no entities here",
            "email me at aziz@example.com",
            "#leading and trailing #",
            "@",
            "مرحبا #الرياض @aziz"
        ]
        for input in inputs {
            let rebuilt = PostTextParser.tokenize(input).map(\.raw).joined()
            XCTAssertEqual(rebuilt, input, "Tokenizing lost characters in: \(input)")
        }
    }

    func testAnEmailAddressIsNotAMention() {
        let tokens = PostTextParser.tokenize("write to aziz@example.com please")

        XCTAssertFalse(tokens.contains { if case .mention = $0 { return true } else { return false } })
    }

    func testABareSigilIsNotAnEntity() {
        XCTAssertEqual(PostTextParser.tokenize("cost @ 5# each"), [.plain("cost @ 5# each")])
    }

    func testArabicHashtagsSurvive() {
        let tokens = PostTextParser.tokenize("الطقس اليوم #الرياض")

        XCTAssertTrue(tokens.contains(.hashtag("الرياض")))
    }

    func testEntityLinksRoundTrip() throws {
        let mention = try XCTUnwrap(PostEntityLink.mention("aziz").url)
        XCTAssertEqual(PostEntityLink.parse(mention), .mention("aziz"))

        let hashtag = try XCTUnwrap(PostEntityLink.hashtag("الرياض").url)
        XCTAssertEqual(PostEntityLink.parse(hashtag), .hashtag("الرياض"))
    }

    func testForeignURLsAreLeftToTheSystem() throws {
        let external = try XCTUnwrap(URL(string: "https://example.com"))
        XCTAssertNil(PostEntityLink.parse(external))
    }

    // MARK: Counters

    func testEngagementCountsAreAbbreviated() {
        XCTAssertEqual(PostCardView.count(0), "0")
        XCTAssertEqual(PostCardView.count(999), "999")
        XCTAssertEqual(PostCardView.count(1_200), "1.2K")
        XCTAssertEqual(PostCardView.count(20_140), "20K")
        XCTAssertEqual(PostCardView.count(1_500_000), "1.5M")
    }

    // MARK: Optimistic prediction

    func testApplyingALikePredictsTheCounter() {
        let post = FeedFixture.post(metrics: PostMetrics(likes: 10), viewer: PostViewerState(liked: false))

        let liked = PostEngagement.applying(.like, on: true, to: post)

        XCTAssertTrue(liked.viewer.liked)
        XCTAssertEqual(liked.metrics.likes, 11)
    }

    func testApplyingTheStateItIsAlreadyInChangesNothing() {
        let post = FeedFixture.post(metrics: PostMetrics(likes: 10), viewer: PostViewerState(liked: true))

        XCTAssertEqual(PostEngagement.applying(.like, on: true, to: post).metrics.likes, 10)
    }

    func testCountersNeverGoNegative() {
        let post = FeedFixture.post(metrics: PostMetrics(likes: 0), viewer: PostViewerState(liked: true))

        XCTAssertEqual(PostEngagement.applying(.like, on: false, to: post).metrics.likes, 0)
    }

    func testEveryEngagementActionTouchesOnlyItsOwnCounter() {
        let post = FeedFixture.post(
            metrics: PostMetrics(likes: 1, reposts: 2, replies: 3, views: 4, bookmarks: 5)
        )

        let reposted = PostEngagement.applying(.repost, on: true, to: post)
        XCTAssertEqual(reposted.metrics.reposts, 3)
        XCTAssertEqual(reposted.metrics.likes, 1)
        XCTAssertEqual(reposted.metrics.replies, 3)
        XCTAssertEqual(reposted.metrics.bookmarks, 5)

        let bookmarked = PostEngagement.applying(.bookmark, on: true, to: post)
        XCTAssertEqual(bookmarked.metrics.bookmarks, 6)
        XCTAssertEqual(bookmarked.metrics.reposts, 2)
    }

    // MARK: Feed tabs

    func testTheFourTabsAreTheV4ProductsTabs() {
        XCTAssertEqual(FeedTab.allCases, [.forYou, .following, .myCountry, .international])
        XCTAssertEqual(FeedTab.allCases.map(\.title), ["For You", "Following", "My Country", "International"])
    }

    func testEveryTabHasAPathAndAnAccessibilityHint() {
        for tab in FeedTab.allCases {
            XCTAssertTrue(tab.path.hasPrefix("/feed/"), "\(tab) has an odd path")
            XCTAssertFalse(tab.accessibilityHint.isEmpty, "\(tab) has no hint")
        }
    }
}
