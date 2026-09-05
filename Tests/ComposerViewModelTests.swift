import XCTest
@testable import Sila

/// ``ComposerServiceProtocol`` whose every call is scriptable, so the thread
/// chain and its failure points can be driven exactly.
final class ScriptedComposerService: ComposerServiceProtocol, @unchecked Sendable {

    /// Drafts received, in order — the assertion surface for thread sequencing.
    private(set) var drafts: [PostDraft] = []
    /// Fails the *nth* call (1-based) with ``failure``. `nil` never fails.
    var failOnCall: Int?
    /// The error thrown when ``failOnCall`` trips.
    var failure: APIError = .api(code: .rateLimited, message: "Slow down", status: 429)

    private let lock = NSLock()
    private var callCount = 0

    func createPost(_ draft: PostDraft) async throws -> Post {
        let (index, shouldFail, error) = lock.withLock { () -> (Int, Bool, APIError) in
            drafts.append(draft)
            callCount += 1
            return (callCount, callCount == failOnCall, failure)
        }
        if shouldFail { throw error }
        return Self.post(index: index, draft: draft)
    }

    /// Paths handed back for uploads, in order, and what a test can make fail.
    private(set) var uploadedBytes: [Int] = []
    var uploadFailure: APIError?

    func uploadImage(_ data: Data) async throws -> String {
        let failure = lock.withLock { () -> APIError? in
            uploadedBytes.append(data.count)
            return uploadFailure
        }
        if let failure { throw failure }
        return "/api/v1/media/posts/scripted-\(uploadedBytes.count).jpg"
    }

    /// Deterministic ids so a test can assert segment 2 replied to segment 1.
    static func id(_ index: Int) -> UUID {
        UUID(uuidString: "00000000-0000-4000-8000-\(String(format: "%012d", 7_000 + index))") ?? UUID()
    }

    private static func post(index: Int, draft: PostDraft) -> Post {
        Post(
            id: id(index),
            author: FeedServiceMock.aziz,
            text: draft.trimmedText,
            createdAt: Date(),
            scope: PostScope(rawValue: draft.scope.wireValue) ?? .international,
            scopeCountry: draft.scope.scopeCountry,
            scopeRegion: draft.scope.scopeRegion,
            replyToPostId: draft.replyToPostId
        )
    }
}

/// ``SearchServiceProtocol`` that records queries and replays a fixed roster.
final class ScriptedSearchService: SearchServiceProtocol, @unchecked Sendable {

    /// Every `searchUsers` query received, in order.
    private(set) var userQueries: [String] = []
    /// Every `searchPosts` query received, in order.
    private(set) var postQueries: [String] = []
    /// How many times trending was fetched.
    private(set) var trendingCalls = 0

    /// Users returned by ``searchUsers(query:limit:)``.
    var users: [UserSummary] = [FeedServiceMock.aziz, FeedServiceMock.noor]
    /// Page returned by ``searchPosts(query:cursor:limit:)``.
    var postPages: [FeedPage] = []
    /// Tags returned by ``trendingTags(limit:)``.
    var tags: [TrendingTag] = [TrendingTag(tag: "riyadh", postCount: 12)]
    /// When set, every call throws it.
    var error: APIError?

    private let lock = NSLock()

    func searchUsers(query: String, limit: Int) async throws -> [UserSummary] {
        let (found, failure) = lock.withLock { () -> ([UserSummary], APIError?) in
            userQueries.append(query)
            return (users, error)
        }
        if let failure { throw failure }
        return found
    }

    func searchPosts(query: String, cursor: String?, limit: Int) async throws -> FeedPage {
        let (page, failure) = lock.withLock { () -> (FeedPage, APIError?) in
            postQueries.append(query)
            let next = postPages.isEmpty ? FeedPage.empty : postPages.removeFirst()
            return (next, error)
        }
        if let failure { throw failure }
        return page
    }

    func trendingTags(limit: Int) async throws -> [TrendingTag] {
        let (found, failure) = lock.withLock { () -> ([TrendingTag], APIError?) in
            trendingCalls += 1
            return (tags, error)
        }
        if let failure { throw failure }
        return found
    }
}

@MainActor
final class ComposerViewModelTests: XCTestCase {

    private let verifiedSaudi = ComposerAuthor(handle: "aziz", countryCode: "SA", isVerified: true)

    private func makeViewModel(
        context: ComposerContext = .newPost,
        author: ComposerAuthor? = nil,
        composer: ComposerServiceProtocol,
        search: SearchServiceProtocol? = nil,
        onPosted: @escaping @MainActor ([Post]) -> Void = { _ in },
        onClose: @escaping @MainActor () -> Void = {}
    ) -> ComposerViewModel {
        ComposerViewModel(
            context: context,
            author: author ?? verifiedSaudi,
            composer: composer,
            search: search,
            analytics: RecordingAnalyticsClient(),
            mentionDebounce: 0.02,
            onPosted: onPosted,
            onClose: onClose
        )
    }

    // MARK: - Posting gate

    func testThePostButtonIsDeadUntilThereIsText() {
        let viewModel = makeViewModel(composer: ScriptedComposerService())

        XCTAssertFalse(viewModel.canPost)

        viewModel.setText("hello", at: 0)
        XCTAssertTrue(viewModel.canPost)

        viewModel.setText("   ", at: 0)
        XCTAssertFalse(viewModel.canPost, "Whitespace is not content")
    }

    func testAnOverLongSegmentBlocksTheWholeThread() {
        let viewModel = makeViewModel(composer: ScriptedComposerService())

        viewModel.setText("fine", at: 0)
        viewModel.addSegment()
        viewModel.setText(String(repeating: "a", count: 281), at: 1)

        XCTAssertFalse(viewModel.canPost, "One over-long segment would 400 halfway through the chain")
    }

    // MARK: - Single post

    func testASinglePostSendsTheChosenScopeAndCloses() async {
        let service = ScriptedComposerService()
        var closed = false
        var published: [Post] = []
        let viewModel = makeViewModel(
            composer: service,
            onPosted: { published = $0 },
            onClose: { closed = true }
        )

        viewModel.select(ScopePicker.options(for: verifiedSaudi).first { $0.scope == .country("SA") } ?? .init(
            scope: .country("SA"), title: "", subtitle: "", icon: "", isAvailable: true
        ))
        viewModel.setText("Hello Riyadh", at: 0)
        await viewModel.post()

        XCTAssertEqual(service.drafts.count, 1)
        XCTAssertEqual(service.drafts.first?.trimmedText, "Hello Riyadh")
        XCTAssertEqual(service.drafts.first?.scope, .country("SA"))
        XCTAssertNil(service.drafts.first?.replyToPostId)
        XCTAssertEqual(published.count, 1)
        XCTAssertTrue(closed, "A clean post closes the sheet")
    }

    func testAnUnavailableScopeIsRefusedWithItsReason() {
        let author = ComposerAuthor(countryCode: nil, isVerified: false)
        let viewModel = makeViewModel(author: author, composer: ScriptedComposerService())

        let locked = ScopePicker.options(for: author).first { !$0.isAvailable }
        viewModel.select(locked ?? .init(scope: .international, title: "", subtitle: "", icon: "", isAvailable: true))

        XCTAssertEqual(viewModel.scope, .international, "The selection did not take")
        XCTAssertNotNil(viewModel.toast, "A tap that silently does nothing reads as broken")
    }

    // MARK: - Thread sequencing

    func testAThreadPostsSequentiallyWithEachSegmentReplyingToTheLast() async {
        let service = ScriptedComposerService()
        var published: [Post] = []
        let viewModel = makeViewModel(composer: service, onPosted: { published = $0 })

        viewModel.setText("one", at: 0)
        viewModel.addSegment()
        viewModel.setText("two", at: 1)
        viewModel.addSegment()
        viewModel.setText("three", at: 2)

        await viewModel.post()

        XCTAssertEqual(service.drafts.map(\.trimmedText), ["one", "two", "three"])
        XCTAssertNil(service.drafts[0].replyToPostId, "The root opens the thread")
        XCTAssertEqual(
            service.drafts[1].replyToPostId,
            ScriptedComposerService.id(1),
            "Segment 2 replies to segment 1"
        )
        XCTAssertEqual(service.drafts[2].replyToPostId, ScriptedComposerService.id(2))
        XCTAssertEqual(published.count, 3)
    }

    func testEverySegmentOfAThreadCarriesTheSameScope() async {
        let service = ScriptedComposerService()
        let viewModel = makeViewModel(composer: service)

        viewModel.select(ScopePicker.options(for: verifiedSaudi).first { $0.scope == .region(.gcc) } ?? .init(
            scope: .region(.gcc), title: "", subtitle: "", icon: "", isAvailable: true
        ))
        viewModel.setText("one", at: 0)
        viewModel.addSegment()
        viewModel.setText("two", at: 1)

        await viewModel.post()

        XCTAssertEqual(service.drafts.map(\.scope), [.region(.gcc), .region(.gcc)])
    }

    func testOnlyTheOpeningSegmentCarriesTheQuote() async {
        let service = ScriptedComposerService()
        let quoted = FeedServiceMock.internationalRoot
        let viewModel = makeViewModel(context: .quote(quoted), composer: service)

        viewModel.setText("one", at: 0)
        viewModel.addSegment()
        viewModel.setText("two", at: 1)

        await viewModel.post()

        XCTAssertEqual(service.drafts[0].quotedPostId, quoted.id)
        XCTAssertNil(service.drafts[1].quotedPostId, "Quoting again would duplicate the card")
    }

    // MARK: - Partial failure

    func testAThreadThatFailsHalfwayKeepsTheUnsentSegmentsAndSaysHowManyPosted() async {
        let service = ScriptedComposerService()
        service.failOnCall = 3
        var closed = false
        var published: [Post] = []
        let viewModel = makeViewModel(
            composer: service,
            onPosted: { published = $0 },
            onClose: { closed = true }
        )

        for (index, text) in ["one", "two", "three", "four", "five"].enumerated() {
            if index > 0 { viewModel.addSegment() }
            viewModel.setText(text, at: index)
        }

        await viewModel.post()

        XCTAssertFalse(closed, "The sheet must stay open — three segments never left the device")
        XCTAssertEqual(published.count, 2, "The two live posts are handed to the feed anyway")
        XCTAssertEqual(
            viewModel.segments.map(\.text),
            ["three", "four", "five"],
            "The posted segments are dropped; the rest are kept verbatim"
        )

        let message = viewModel.partialFailureMessage
        XCTAssertNotNil(message)
        XCTAssertTrue(message?.contains("Posted 2 of 5") == true, "got: \(message ?? "nil")")
        XCTAssertEqual(viewModel.toast?.kind, .warning, "A half-posted thread is not a plain error")
    }

    func testRetryingAfterAPartialFailureContinuesTheChainInsteadOfStartingOver() async {
        let service = ScriptedComposerService()
        service.failOnCall = 2
        let viewModel = makeViewModel(composer: service)

        viewModel.setText("one", at: 0)
        viewModel.addSegment()
        viewModel.setText("two", at: 1)

        await viewModel.post()
        XCTAssertEqual(viewModel.segments.map(\.text), ["two"])

        service.failOnCall = nil
        await viewModel.post()

        XCTAssertEqual(service.drafts.map(\.trimmedText), ["one", "two", "two"])
        XCTAssertEqual(
            service.drafts.last?.replyToPostId,
            ScriptedComposerService.id(1),
            "The retry replies to the post that already exists rather than opening a second thread"
        )
    }

    // MARK: - Failures with nothing posted

    func testAnUnverifiedAccountIsToldWhyNothingWasPosted() async {
        let service = ScriptedComposerService()
        service.failOnCall = 1
        service.failure = .api(code: .unverified, message: "nope", status: 403)
        var closed = false
        let viewModel = makeViewModel(composer: service, onClose: { closed = true })

        viewModel.setText("hello", at: 0)
        await viewModel.post()

        XCTAssertFalse(closed)
        XCTAssertEqual(viewModel.toast?.kind, .error)
        XCTAssertTrue(viewModel.toast?.text.contains("verified") == true, "got: \(viewModel.toast?.text ?? "nil")")
        XCTAssertEqual(viewModel.segments.map(\.text), ["hello"], "Nothing posted means nothing is thrown away")
        XCTAssertNil(viewModel.partialFailureMessage)
    }

    func testAnOfflineFailureKeepsTheDraft() async {
        let service = ScriptedComposerService()
        service.failOnCall = 1
        service.failure = .transport("offline")
        let viewModel = makeViewModel(composer: service)

        viewModel.setText("hello", at: 0)
        await viewModel.post()

        XCTAssertEqual(viewModel.segments.map(\.text), ["hello"])
        XCTAssertEqual(viewModel.toast?.kind, .error)
    }

    func testTheMockPlaysThePartialFailureItAdvertises() async {
        let mock = ComposerServiceMock(scenario: .threadFailsMidway)

        let report = await mock.createThread(segments: ["a", "b", "c"], scope: .international)

        XCTAssertEqual(report.posted.count, 2)
        XCTAssertEqual(report.remaining, ["c"])
        XCTAssertTrue(report.isPartialFailure)
    }

    // MARK: - Replies

    func testAReplyInheritsItsParentsScopeAndOffersNoPicker() {
        let viewModel = makeViewModel(
            context: .reply(to: FeedServiceMock.countryThread),
            composer: ScriptedComposerService()
        )

        XCTAssertEqual(viewModel.scope, .country("SA"))
        XCTAssertFalse(viewModel.context.showsScopePicker)
        XCTAssertFalse(viewModel.allowsThread, "A reply is one post")
    }

    func testABlockedReplyOffersNoInputAndCannotBePosted() {
        // `countryThread` is a 🇸🇦 thread the mocked viewer may not reply to.
        let viewModel = makeViewModel(
            context: .reply(to: FeedServiceMock.countryThread),
            composer: ScriptedComposerService()
        )

        XCTAssertFalse(viewModel.canReplyHere)
        XCTAssertNotNil(viewModel.replyBlockedMessage)
        XCTAssertTrue(
            viewModel.replyBlockedMessage?.contains("Saudi Arabia") == true,
            "got: \(viewModel.replyBlockedMessage ?? "nil")"
        )

        viewModel.setText("let me in", at: 0)
        XCTAssertFalse(viewModel.canPost, "The composer never offers a button the server would refuse")
    }

    func testARepliableThreadShowsNoBlockMessage() {
        let viewModel = makeViewModel(
            context: .reply(to: FeedServiceMock.internationalRoot),
            composer: ScriptedComposerService()
        )

        XCTAssertTrue(viewModel.canReplyHere)
        XCTAssertNil(viewModel.replyBlockedMessage)

        viewModel.setText("here", at: 0)
        XCTAssertTrue(viewModel.canPost)
    }

    func testAReplyPostsAgainstItsParent() async {
        let service = ScriptedComposerService()
        let parent = FeedServiceMock.internationalRoot
        let viewModel = makeViewModel(context: .reply(to: parent), composer: service)

        viewModel.setText("agreed", at: 0)
        await viewModel.post()

        XCTAssertEqual(service.drafts.first?.replyToPostId, parent.id)
        XCTAssertEqual(service.drafts.first?.scope, .international)
    }

    func testARefreshedParentUpdatesThePermissionWithoutLosingTheDraft() {
        var parent = FeedServiceMock.internationalRoot
        let viewModel = makeViewModel(context: .reply(to: parent), composer: ScriptedComposerService())
        viewModel.setText("half typed", at: 0)

        // The detail screen re-read the post and the server now says no.
        parent.viewer = PostViewerState(canReply: false, replyBlockReason: .unverified)
        viewModel.updateReplyTarget(parent)

        XCTAssertFalse(viewModel.canReplyHere)
        XCTAssertEqual(viewModel.text(at: 0), "half typed", "The typed text survives a refresh")
    }

    func testUpdatingWithADifferentPostIsIgnored() {
        let viewModel = makeViewModel(
            context: .reply(to: FeedServiceMock.internationalRoot),
            composer: ScriptedComposerService()
        )

        viewModel.updateReplyTarget(FeedServiceMock.countryThread)

        XCTAssertEqual(viewModel.context.replyTarget?.id, FeedServiceMock.internationalRoot.id)
    }

    // MARK: - Mention autocomplete

    func testTypingAMentionSearchesOnceAfterTheDebounce() async throws {
        let search = ScriptedSearchService()
        let viewModel = makeViewModel(composer: ScriptedComposerService(), search: search)

        // A fast typist: each keystroke cancels the one before it.
        viewModel.setText("hi @a", at: 0)
        viewModel.setText("hi @az", at: 0)
        viewModel.setText("hi @azi", at: 0)

        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(search.userQueries, ["azi"], "Debounce must collapse the burst into one request")
        XCTAssertEqual(viewModel.mentionSuggestions.count, 2)
    }

    func testAOneCharacterMentionNeverReachesTheNetwork() async throws {
        let search = ScriptedSearchService()
        let viewModel = makeViewModel(composer: ScriptedComposerService(), search: search)

        viewModel.setText("hi @a", at: 0)
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertTrue(search.userQueries.isEmpty, "The server answers a one-character query with nothing anyway")
        XCTAssertTrue(viewModel.mentionSuggestions.isEmpty)
    }

    func testFinishingAMentionClosesTheSuggestionList() async throws {
        let search = ScriptedSearchService()
        let viewModel = makeViewModel(composer: ScriptedComposerService(), search: search)

        viewModel.setText("hi @az", at: 0)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(viewModel.mentionSuggestions.isEmpty)

        viewModel.setText("hi @aziz ", at: 0)
        XCTAssertTrue(viewModel.mentionSuggestions.isEmpty, "The mention is finished; the list goes away")
    }

    func testTappingASuggestionInsertsTheHandleIntoTheFocusedSegment() async throws {
        let search = ScriptedSearchService()
        let viewModel = makeViewModel(composer: ScriptedComposerService(), search: search)

        viewModel.setText("first", at: 0)
        viewModel.addSegment()
        viewModel.setText("ask @az", at: 1)
        try await Task.sleep(nanoseconds: 200_000_000)

        viewModel.insertMention(FeedServiceMock.aziz)

        XCTAssertEqual(viewModel.text(at: 1), "ask @aziz ")
        XCTAssertEqual(viewModel.text(at: 0), "first", "Only the focused segment changes")
        XCTAssertTrue(viewModel.mentionSuggestions.isEmpty)
    }

    func testNoSearchServiceMeansNoSuggestionsAndNoCrash() async throws {
        let viewModel = makeViewModel(composer: ScriptedComposerService(), search: nil)

        viewModel.setText("hi @aziz", at: 0)
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertTrue(viewModel.mentionSuggestions.isEmpty)
        XCTAssertTrue(viewModel.canPost, "Autocomplete is an aid, not a requirement")
    }

    // MARK: - Segments and dismissal

    func testSegmentsCanBeAddedAndRemovedButNeverBelowOne() {
        let viewModel = makeViewModel(composer: ScriptedComposerService())

        viewModel.setText("one", at: 0)
        viewModel.addSegment()
        XCTAssertEqual(viewModel.segments.count, 2)
        XCTAssertEqual(viewModel.focusedIndex, 1)

        viewModel.removeSegment(at: 1)
        XCTAssertEqual(viewModel.segments.count, 1)

        viewModel.removeSegment(at: 0)
        XCTAssertEqual(viewModel.segments.count, 1, "There is always something to type into")
    }

    func testAThreadCannotGrowPastTheClientCap() {
        let viewModel = makeViewModel(composer: ScriptedComposerService())

        for _ in 0..<(ComposerConstants.maximumThreadSegments + 5) {
            viewModel.addSegment()
        }

        XCTAssertEqual(viewModel.segments.count, ComposerConstants.maximumThreadSegments)
        XCTAssertFalse(viewModel.allowsThread)
    }

    func testCancellingAnEmptyComposerClosesWithoutAsking() {
        var closed = false
        let viewModel = makeViewModel(composer: ScriptedComposerService(), onClose: { closed = true })

        viewModel.requestDismiss()

        XCTAssertTrue(closed)
        XCTAssertFalse(viewModel.isConfirmingDiscard)
    }

    func testCancellingWithContentAsksBeforeThrowingItAway() {
        var closed = false
        let viewModel = makeViewModel(composer: ScriptedComposerService(), onClose: { closed = true })
        viewModel.setText("something worth keeping", at: 0)

        viewModel.requestDismiss()
        XCTAssertTrue(viewModel.isConfirmingDiscard)
        XCTAssertFalse(closed)

        viewModel.cancelDiscard()
        XCTAssertFalse(viewModel.isConfirmingDiscard)
        XCTAssertFalse(closed)

        viewModel.requestDismiss()
        viewModel.confirmDiscard()
        XCTAssertTrue(closed)
    }
}

// MARK: - Attachments

@MainActor
final class ComposerAttachmentTests: XCTestCase {

    private func makeViewModel(_ service: ComposerServiceProtocol) -> ComposerViewModel {
        ComposerViewModel(
            context: .newPost,
            author: ComposerAuthor(handle: "aziz", countryCode: "SA", isVerified: true),
            composer: service,
            search: nil,
            analytics: RecordingAnalyticsClient(),
            mentionDebounce: 0.02,
            onPosted: { _ in },
            onClose: {}
        )
    }

    /// A failed upload must cost one picture, never the draft.
    ///
    /// This is the whole reason upload and post are two steps: on the
    /// connections this app is written for, images fail far more often than
    /// text, and a composer that sent both together would throw away somebody's
    /// words because a photograph did not make it.
    func testAFailedUploadLeavesTheTextAlone() async {
        let service = ScriptedComposerService()
        service.uploadFailure = .api(code: .imageTooLarge, message: "Too big", status: 413)
        let viewModel = makeViewModel(service)
        viewModel.setText("Words worth keeping", at: 0)

        await viewModel.attach(Data(repeating: 0xFF, count: 32))

        XCTAssertTrue(viewModel.attachments.isEmpty, "a failed upload was attached anyway")
        XCTAssertEqual(viewModel.text(at: 0), "Words worth keeping", "the draft was lost")
        XCTAssertNotNil(viewModel.toast, "the failure was silent")
    }

    /// Only the opening segment of a thread carries the images.
    func testAThreadAttachesImagesOnceNotToEverySegment() async {
        let service = ScriptedComposerService()
        let viewModel = makeViewModel(service)
        viewModel.setText("First", at: 0)
        viewModel.addSegment()
        viewModel.setText("Second", at: 1)

        await viewModel.attach(Data(repeating: 0x01, count: 16))
        await viewModel.post()

        XCTAssertEqual(service.drafts.count, 2)
        XCTAssertEqual(service.drafts[0].imageURLs.count, 1, "the opening segment lost its image")
        XCTAssertTrue(service.drafts[1].imageURLs.isEmpty, "the image was posted twice")
    }

    /// The fifth picture is refused rather than silently dropped.
    func testAFifthImageIsRefusedOutLoud() async {
        let service = ScriptedComposerService()
        let viewModel = makeViewModel(service)

        for _ in 0..<ComposerConstants.maximumImages {
            await viewModel.attach(Data([0x01]))
        }
        viewModel.toast = nil
        await viewModel.attach(Data([0x01]))

        XCTAssertEqual(viewModel.attachments.count, ComposerConstants.maximumImages)
        XCTAssertNotNil(viewModel.toast, "the limit was enforced silently")
    }

    /// Removing an attachment removes exactly one.
    func testRemovingAnAttachmentRemovesOnlyThatOne() async {
        let service = ScriptedComposerService()
        let viewModel = makeViewModel(service)
        await viewModel.attach(Data([0x01]))
        await viewModel.attach(Data([0x02]))
        let survivor = viewModel.attachments[1]

        viewModel.removeAttachment(at: 0)

        XCTAssertEqual(viewModel.attachments, [survivor])
    }
}

// MARK: - Content warnings

/// The warning goes over the wire exactly as the author set it, on every
/// segment of a thread — and nowhere when they set none.
@MainActor
final class ComposerWarningTests: XCTestCase {

    private func makeViewModel(_ service: ComposerServiceProtocol) -> ComposerViewModel {
        ComposerViewModel(
            context: .newPost,
            author: ComposerAuthor(handle: "aziz", countryCode: "SA", isVerified: true),
            composer: service,
            search: nil,
            analytics: RecordingAnalyticsClient(),
            mentionDebounce: 0.02,
            onPosted: { _ in },
            onClose: {}
        )
    }

    func testTheWarningAndNoteTravelWithThePost() async {
        let mock = ComposerServiceMock(scenario: .success, latency: 0)
        let viewModel = makeViewModel(mock)
        viewModel.setText("the butler did it", at: 0)
        viewModel.sensitive = .spoiler
        viewModel.sensitiveNote = "Spoilers for episode 3"

        await viewModel.post()

        let drafts = await mock.receivedDrafts
        XCTAssertEqual(drafts.count, 1)
        XCTAssertEqual(drafts.first?.sensitive, .spoiler)
        XCTAssertEqual(drafts.first?.sensitiveNote, "Spoilers for episode 3")
    }

    func testNoWarningByDefault() async {
        let mock = ComposerServiceMock(scenario: .success, latency: 0)
        let viewModel = makeViewModel(mock)
        viewModel.setText("nothing to see", at: 0)

        await viewModel.post()

        let drafts = await mock.receivedDrafts
        XCTAssertNil(drafts.first?.sensitive, "off unless the author turns it on — never inferred")
    }

    func testAThreadIsCoveredOnEverySegment() async {
        let mock = ComposerServiceMock(scenario: .success, latency: 0)

        let report = await mock.createThread(
            segments: ["one", "two", "three"],
            scope: .international,
            sensitive: .violence,
            sensitiveNote: "Crash footage"
        )

        XCTAssertEqual(report.posted.count, 3)
        let drafts = await mock.receivedDrafts
        XCTAssertEqual(drafts.map(\.sensitive), [.violence, .violence, .violence],
                       "covering only the opening line would leave the rest readable under it")
        XCTAssertEqual(Set(drafts.map(\.sensitiveNote)), ["Crash footage"])
    }
}

