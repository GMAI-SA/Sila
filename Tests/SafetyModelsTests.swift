import XCTest
@testable import Sila

/// The safety domain: the wire shapes the backend actually sends, the block
/// confirmation's contents, the report form's rules, and the one decision that
/// separates a receipt from a page of help.
@MainActor
final class SafetyModelsTests: XCTestCase {

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONCoding.decoder.decode(type, from: Data(json.utf8))
    }

    // MARK: - Lists

    /// The shipped shape: `{"blocked": [<UserSummary>, …]}`, bare user objects.
    func testTheBlockedListDecodesTheShippedShape() throws {
        let list = try decode(SafetyRelationList.self, """
        {"blocked": [
          {"id": "2c3ff295-050b-4193-8eea-98f5cf1f92f2", "handle": "yuki",
           "display_name": "Yuki Tanaka", "is_verified": true, "country_code": "JP"},
          {"id": "3c3ff295-050b-4193-8eea-98f5cf1f92f3", "handle": "noor",
           "display_name": "Noor", "is_verified": true, "country_code": "AE"}
        ]}
        """)

        XCTAssertEqual(list.relations.map(\.user.handle), ["yuki", "noor"])
        XCTAssertEqual(list.relations.first?.user.displayName, "Yuki Tanaka")
        XCTAssertNil(list.relations.first?.createdAt, "no timestamp is sent, and none is invented")
    }

    func testTheMutedListDecodesTheShippedShape() throws {
        let list = try decode(SafetyRelationList.self, """
        {"muted": [{"id": "2c3ff295-050b-4193-8eea-98f5cf1f92f2", "handle": "maria",
                    "display_name": "Maria", "is_verified": true}]}
        """)

        XCTAssertEqual(list.relations.map(\.user.handle), ["maria"])
    }

    /// The wrapper key is the only thing that varies between plausible
    /// backends, and getting it wrong empties a safety list — the one list that
    /// must never quietly say "you have blocked nobody" to somebody who has.
    func testAListSurvivesEveryPlausibleWrapper() throws {
        let user = #"{"id": "2c3ff295-050b-4193-8eea-98f5cf1f92f2", "handle": "yuki", "display_name": "Y", "is_verified": true}"#
        for wrapper in ["blocked", "muted", "users", "items", "results", "data"] {
            let list = try decode(SafetyRelationList.self, "{\"\(wrapper)\": [\(user)]}")
            XCTAssertEqual(list.relations.map(\.user.handle), ["yuki"], "wrapper: \(wrapper)")
        }
        let bare = try decode(SafetyRelationList.self, "[\(user)]")
        XCTAssertEqual(bare.relations.map(\.user.handle), ["yuki"], "a bare array")
    }

    /// An unrecognised body reads as an empty list rather than throwing, so a
    /// contract change cannot make the settings screen unopenable.
    func testAnUnreadableListIsEmptyRatherThanAThrow() throws {
        let list = try decode(SafetyRelationList.self, #"{"something_else": 3}"#)
        XCTAssertTrue(list.relations.isEmpty)
    }

    // MARK: - Toggles

    /// `{"blocked": true, "handle": "…"}` — the state comes off the wire.
    func testTheToggleResponseReadsTheServersStateNotTheRequested() throws {
        let blocked = try decode(SafetyToggleResponse.self, #"{"blocked": true, "handle": "yuki"}"#)
        XCTAssertTrue(blocked.state(requested: false), "the server's answer wins")

        let unmuted = try decode(SafetyToggleResponse.self, #"{"muted": false, "handle": "yuki"}"#)
        XCTAssertFalse(unmuted.state(requested: true))
    }

    /// Both verbs are idempotent, so a body that says nothing leaves exactly the
    /// state that was asked for. That is not optimism — the call returned 2xx.
    func testASilentToggleResponseFallsBackToWhatWasAskedFor() throws {
        let empty = try decode(SafetyToggleResponse.self, "{}")
        XCTAssertTrue(empty.state(requested: true))
        XCTAssertFalse(empty.state(requested: false))
    }

    // MARK: - Reports

    /// `{"id", "status", "support": null}` — the ordinary case.
    func testAReceiptWithoutSupportDecodesAsSuch() throws {
        let receipt = try decode(ReportReceipt.self, #"{"id": "rpt_0007", "status": "open", "support": null}"#)

        XCTAssertEqual(receipt.id, "rpt_0007")
        XCTAssertEqual(receipt.status, "open")
        XCTAssertNil(receipt.support)
    }

    /// The shipped `support` shape: `headline`, `body`, `resources[{label, value}]`.
    func testASupportObjectDecodesTheShippedShape() throws {
        let receipt = try decode(ReportReceipt.self, """
        {"id": "rpt_0008", "status": "open",
         "support": {
           "headline": "Help is available",
           "body": "You did the right thing by telling us.",
           "resources": [
             {"label": "National Centre for Mental Health", "value": "920033360"},
             {"label": "Befrienders Worldwide", "value": "https://befrienders.org"},
             {"label": "Emergency services", "value": "Call your local emergency number now."}
           ]
         }}
        """)

        let support = try XCTUnwrap(receipt.support)
        XCTAssertEqual(support.title, "Help is available")
        XCTAssertEqual(support.message, "You did the right thing by telling us.")
        XCTAssertEqual(support.resources.count, 3)
        XCTAssertFalse(support.isEmpty)
    }

    /// `value` is one untyped string, so the client sorts it out by shape — and
    /// conservatively. A dial button on a sentence would be worse than no button.
    func testASupportValueIsClassifiedByShapeAndNeverGuessedInto() throws {
        let support = try decode(SupportResources.self, """
        {"headline": "H", "body": "B", "resources": [
          {"label": "Phone", "value": "920033360"},
          {"label": "Site", "value": "https://befrienders.org"},
          {"label": "Advice", "value": "Call your local emergency number now."}
        ]}
        """)

        XCTAssertEqual(support.resources[0].phone, "920033360")
        XCTAssertNil(support.resources[0].url)

        XCTAssertEqual(support.resources[1].url?.absoluteString, "https://befrienders.org")
        XCTAssertNil(support.resources[1].phone, "a URL is not a number to dial")

        // A sentence stays a sentence: it has letters in it, so it is neither.
        XCTAssertNil(support.resources[2].phone, "a sentence must not become a dial button")
        XCTAssertNil(support.resources[2].url)
        XCTAssertEqual(support.resources[2].detail, "Call your local emergency number now.")
    }

    func testThePhoneClassifierRefusesAnythingItIsNotSureOf() {
        XCTAssertEqual(SupportResource.classify("116 123"), .telephone("116 123"))
        XCTAssertEqual(SupportResource.classify("+966 (11) 234-5678"), .telephone("+966 (11) 234-5678"))
        XCTAssertEqual(SupportResource.classify("tel:911"), .telephone("911"))
        XCTAssertEqual(
            SupportResource.classify("https://x.example"),
            .link(URL(string: "https://x.example") ?? URL(fileURLWithPath: "/"))
        )
        // Too many digits to be a number; letters in it; empty of digits.
        XCTAssertEqual(SupportResource.classify("Open 24 hours a day"), .plain("Open 24 hours a day"))
        XCTAssertEqual(SupportResource.classify("12"), .plain("12"), "two digits is not a helpline")
        XCTAssertEqual(
            SupportResource.classify(String(repeating: "9", count: 30)),
            .plain(String(repeating: "9", count: 30))
        )
    }

    /// The `tel:` URL keeps exactly the digits the server sent, and adds nothing.
    func testTheDialLinkNeverInventsDigits() {
        XCTAssertEqual(ReportSheet.telURL("920 033 360")?.absoluteString, "tel:920033360")
        XCTAssertEqual(ReportSheet.telURL("+966 11 234 5678")?.absoluteString, "tel:+966112345678")
        XCTAssertNil(ReportSheet.telURL("Emergency services"))
    }

    /// An empty `support` object is still a `support` object. Its presence is
    /// what decides the outcome screen; its contents only decide the list.
    func testAnEmptySupportObjectIsStillPresent() throws {
        let receipt = try decode(ReportReceipt.self, #"{"id": "r", "status": "open", "support": {}}"#)
        let support = try XCTUnwrap(receipt.support, "an empty object is not the same as null")
        XCTAssertTrue(support.isEmpty)
    }

    /// Exactly one of the two identifying fields is sent, and a blank `detail`
    /// is omitted rather than shipped as noise for a reviewer to read past.
    func testTheReportBodyCarriesExactlyOneSubject() throws {
        let postId = UUID(uuidString: "2c3ff295-050b-4193-8eea-98f5cf1f92f2") ?? UUID()
        let forPost = ReportRequest(
            subject: .post(id: postId, author: SafetyTarget(handle: "yuki"), excerpt: "hi"),
            reason: .spam,
            detail: "   "
        )
        let postJSON = String(decoding: try JSONCoding.encoder.encode(forPost), as: UTF8.self)
        XCTAssertTrue(postJSON.contains("\"post_id\""))
        XCTAssertFalse(postJSON.contains("\"user_handle\""))
        XCTAssertFalse(postJSON.contains("\"detail\""), "a whitespace-only detail is not a detail")
        XCTAssertTrue(postJSON.contains("\"reason\":\"spam\""))

        let forUser = ReportRequest(
            subject: .account(SafetyTarget(handle: "@Yuki")),
            reason: .hateSpeech,
            detail: "Repeated slurs"
        )
        let userJSON = String(decoding: try JSONCoding.encoder.encode(forUser), as: UTF8.self)
        XCTAssertTrue(userJSON.contains("\"user_handle\":\"yuki\""), "normalised, no @")
        XCTAssertFalse(userJSON.contains("\"post_id\""))
        XCTAssertTrue(userJSON.contains("\"reason\":\"hate_speech\""))
        XCTAssertTrue(userJSON.contains("\"detail\":\"Repeated slurs\""))
    }

    /// Every reason the contract lists, spelled the way the server spells it.
    func testEveryContractReasonIsPresentAndSpelledCorrectly() {
        XCTAssertEqual(
            Set(ReportReason.allCases.map(\.rawValue)),
            ["spam", "harassment", "hate_speech", "violence", "sexual_content",
             "self_harm", "impersonation", "illegal", "other"]
        )
    }

    /// A reason this build has never heard of must not fail somebody's receipt.
    func testAnUnknownReasonOnAReceiptDecodesToNilRatherThanThrowing() throws {
        let report = try decode(Report.self, """
        {"id": "rpt_1", "status": "open", "reason": "something_invented_later",
         "created_at": "2026-08-20T10:00:00Z", "user_handle": "yuki"}
        """)

        XCTAssertNil(report.reason)
        XCTAssertEqual(report.id, "rpt_1")
        XCTAssertEqual(report.userHandle, "yuki")
        XCTAssertEqual(report.subjectDescription, "@yuki")
    }

    // MARK: - The report form's rules

    /// **Reason-picker validation.** Nothing can be sent until something has
    /// been picked, and the message says what to do rather than what is wrong.
    func testAReportCannotBeSentWithoutAReason() {
        var draft = ReportDraft(subject: .account(SafetyTarget(handle: "yuki")))

        XCTAssertFalse(draft.isSubmittable)
        XCTAssertEqual(draft.validationError, "Choose what is wrong with this first.")
        XCTAssertNil(draft.request, "an invalid draft cannot be turned into a body")

        draft.reason = .spam
        XCTAssertTrue(draft.isSubmittable)
        XCTAssertNil(draft.validationError)
        XCTAssertNotNil(draft.request)
    }

    /// Every reason except "Something else" is submittable on its own: a
    /// category a reviewer can act on does not need an essay attached.
    func testEveryNamedReasonIsSubmittableWithNoDetail() {
        for reason in ReportReason.allCases where reason != .other {
            let draft = ReportDraft(
                subject: .account(SafetyTarget(handle: "yuki")),
                reason: reason
            )
            XCTAssertTrue(draft.isSubmittable, "\(reason.rawValue) needed a detail it should not")
            XCTAssertFalse(reason.requiresDetail)
        }
    }

    /// "Something else" with nothing after it names nothing at all.
    func testSomethingElseNeedsWordsOfItsOwn() {
        var draft = ReportDraft(subject: .account(SafetyTarget(handle: "yuki")), reason: .other)

        XCTAssertTrue(draft.requiresDetail)
        XCTAssertFalse(draft.isSubmittable)
        XCTAssertEqual(
            draft.validationError,
            "\"Something else\" needs a line explaining what is wrong — "
                + "on its own there is nothing for a reviewer to act on."
        )

        draft.detail = "   \n  "
        XCTAssertFalse(draft.isSubmittable, "whitespace is not a description")

        draft.detail = "too short"
        XCTAssertFalse(draft.isSubmittable, "under the floor")

        draft.detail = "They keep editing my quotes"
        XCTAssertTrue(draft.isSubmittable)
        XCTAssertEqual(draft.request?.detail, "They keep editing my quotes")
    }

    func testAnOverlongDetailIsRefusedBeforeItIsSent() {
        var draft = ReportDraft(subject: .account(SafetyTarget(handle: "yuki")), reason: .spam)
        draft.detail = String(repeating: "a", count: SafetyLimits.maximumDetailLength + 1)

        XCTAssertFalse(draft.isSubmittable)
        XCTAssertEqual(draft.detailRemaining, -1)
        XCTAssertTrue(draft.validationError?.contains("at most") == true)
        XCTAssertNil(draft.request)
    }

    /// `invalid_reason` is unreachable from a picker built out of the enum, and
    /// this is the assertion that keeps it that way.
    func testThePickerOffersOnlyReasonsTheServerAccepts() {
        let offered = ReportViewModel(
            subject: .account(SafetyTarget(handle: "yuki")),
            service: SafetyServiceMock(scenario: .populated),
            analytics: RecordingAnalyticsClient()
        ).reasons
        XCTAssertEqual(offered, ReportReason.allCases)
        XCTAssertEqual(Set(offered.map(\.rawValue)).count, offered.count, "no duplicates")
        XCTAssertTrue(offered.allSatisfy { !$0.title.isEmpty && !$0.detail.isEmpty })
    }

    // MARK: - The outcome decision

    /// **The core requirement.** A non-nil `support` object changes the screen.
    func testSupportBeingPresentChangesTheOutcome() {
        let plain = ReportReceipt(id: "r1", status: "open", support: nil)
        XCTAssertEqual(ReportOutcome.make(receipt: plain, reason: .spam), .received(plain))
        XCTAssertFalse(ReportOutcome.make(receipt: plain, reason: .spam).isSupport)

        let helping = ReportReceipt(
            id: "r2",
            status: "open",
            support: SupportResources(title: "Help is available", message: "…")
        )
        let outcome = ReportOutcome.make(receipt: helping, reason: .spam)
        XCTAssertTrue(outcome.isSupport, "the server said this needs help, whatever the reason was")
        XCTAssertEqual(outcome.resources?.title, "Help is available")
    }

    /// The backstop. If a deployment ever forgets to attach resources to a
    /// self-harm report, this client still must not answer somebody's report of
    /// a friend in danger with a filing reference.
    func testSelfHarmGetsTheCareScreenEvenIfTheServerSendsNoSupport() {
        let bare = ReportReceipt(id: "r3", status: "open", support: nil)
        let outcome = ReportOutcome.make(receipt: bare, reason: .selfHarm)

        XCTAssertTrue(outcome.isSupport)
        XCTAssertNil(outcome.resources, "nothing is invented to fill the gap")
        XCTAssertEqual(outcome.receipt.id, "r3")
    }

    /// A care-first outcome is never closed by a three-second timer.
    func testACareFirstOutcomeIsNeverAllowedToBeATransientToast() {
        let care = ReportOutcome.make(
            receipt: ReportReceipt(id: "r", support: SupportResources()),
            reason: .selfHarm
        )
        XCTAssertFalse(care.mayCloseWithToast)

        let ordinary = ReportOutcome.make(receipt: ReportReceipt(id: "r"), reason: .spam)
        XCTAssertTrue(ordinary.mayCloseWithToast)
    }

    /// An empty support object still produces the care screen, and still
    /// produces no fabricated resource list.
    func testAnEmptySupportObjectStillLeadsWithCareAndInventsNothing() {
        let outcome = ReportOutcome.make(
            receipt: ReportReceipt(id: "r", support: SupportResources()),
            reason: .harassment
        )
        XCTAssertTrue(outcome.isSupport)
        XCTAssertNil(outcome.resources, "an empty object draws no rows")
    }

    // MARK: - The block confirmation

    /// All four consequences, in order, every time. A confirmation that drops
    /// the third is asking for consent to something it has not described.
    func testTheBlockConfirmationStatesEveryConsequence() {
        let confirmation = BlockConfirmation(
            target: SafetyTarget(handle: "yuki", name: "Yuki Tanaka"),
            origin: .profile
        )

        XCTAssertEqual(confirmation.title, "Block Yuki Tanaka?")
        XCTAssertEqual(confirmation.consequences.count, 4)

        let joined = confirmation.consequences.joined(separator: " ")
        XCTAssertTrue(joined.contains("stop seeing each other"), "the visibility change")
        XCTAssertTrue(joined.contains("both ways"), "the follows are severed in both directions")
        XCTAssertTrue(
            joined.contains("Unblocking later does not put them back"),
            "the one people do not expect"
        )
        XCTAssertTrue(joined.contains("is not told"), "and it is never announced")
        XCTAssertTrue(joined.contains("Yuki Tanaka"), "named, not '@handle'")
    }

    /// **Nothing anywhere may say or imply the other person was notified.**
    /// The whole copy surface is swept, not just the sentences that mention it.
    func testNoSafetyCopyEverSuggestsTheOtherPersonWasTold() {
        let target = SafetyTarget(handle: "yuki", name: "Yuki Tanaka")
        let everySentence = SafetyCopy.blockConsequences(for: target) + [
            SafetyCopy.blockReversible,
            SafetyCopy.blocked(target),
            SafetyCopy.unblocked(target),
            SafetyCopy.muteIsSilent,
            SafetyCopy.muteEffect,
            SafetyCopy.muted(target),
            SafetyCopy.unmuted(target),
            SafetyCopy.reportIntro,
            SafetyCopy.reportIsSilent,
            SafetyCopy.reportOutcome,
            SafetyCopy.reportReceivedTitle,
            SafetyCopy.reportReceivedBody(id: "rpt_1"),
            SafetyCopy.supportTitle,
            SafetyCopy.supportFallbackMessage,
            SafetyCopy.supportPrivacy,
            SafetyCopy.supportNextSteps,
            SafetyCopy.blockedListCaption,
            SafetyCopy.mutedListCaption,
            SafetyCopy.reportsListCaption
        ]

        // Phrases that would announce, or hint at, a notification. Each one is
        // checked in the affirmative only — "is not told" must stay legal.
        let forbidden = [
            "will be notified", "is notified", "are notified", "we'll let them know",
            "they will know", "they'll know", "we tell them", "sends them a notification",
            "they will be informed", "we notify"
        ]
        for sentence in everySentence {
            let lowered = sentence.lowercased()
            for phrase in forbidden {
                XCTAssertFalse(
                    lowered.contains(phrase),
                    "\"\(phrase)\" appears in safety copy: \(sentence)"
                )
            }
        }

        // And the three that have to say it outright do.
        XCTAssertTrue(SafetyCopy.muteIsSilent.contains("never told"))
        XCTAssertTrue(SafetyCopy.reportIsSilent.contains("never shown who"))
        XCTAssertTrue(SafetyCopy.muted(target).contains("not told"))
    }

    /// Mute's copy has to promise the two things a block does not: reversible,
    /// and nothing else about the relationship changed.
    func testMuteCopyPromisesSilenceAndNothingElse() {
        XCTAssertTrue(SafetyCopy.muteIsSilent.contains("stay following each other"))
        XCTAssertTrue(SafetyCopy.muteEffect.contains("still open their profile"))
        XCTAssertTrue(SafetyCopy.muteEffect.contains("can still see and reply to you"))
    }

    /// Unblocking must never be described as putting a follow back.
    func testUnblockCopySaysWhatDoesNotComeBack() {
        let message = SafetyCopy.unblocked(SafetyTarget(handle: "yuki", name: "Yuki"))
        XCTAssertTrue(message.contains("Following is not restored"))
    }

    // MARK: - Targets

    func testATargetNormalisesTheHandleAndFallsBackToIt() {
        let typed = SafetyTarget(handle: "  @Yuki_T ", name: "  ")
        XCTAssertEqual(typed.handle, "yuki_t")
        XCTAssertEqual(typed.atHandle, "@yuki_t")
        XCTAssertEqual(typed.name, "@yuki_t", "a blank name is not a name")
        XCTAssertTrue(typed.isAddressable)

        let named = SafetyTarget(handle: "yuki", name: "Yuki Tanaka")
        XCTAssertEqual(named.name, "Yuki Tanaka")
    }

    /// A "handle" that sanitises to nothing would build `/users//block`, which
    /// is a different endpoint. It is refused before a menu is even offered.
    func testAHandleThatSanitisesToNothingIsNotAddressable() {
        // Separators are dropped rather than encoded, so a traversal attempt
        // survives only as the letters that were in it — and still cannot
        // become a different path.
        XCTAssertEqual(SafetyTarget(handle: "../../me/account").handle, "../../me/account")
        XCTAssertEqual(Handle.pathComponent(SafetyTarget(handle: "../../me/account").handle), "meaccount")
        XCTAssertFalse(SafetyTarget(handle: "!!!").isAddressable)
        XCTAssertFalse(SafetyTarget(handle: "  ").isAddressable)
    }

    // MARK: - Suspension

    /// The shipped shape, with an end date and no appeal.
    func testASuspensionDecodesTheShippedShape() throws {
        let suspension = try decode(Suspension.self, """
        {"suspended": true, "reason": "Repeated replies after being asked to stop.",
         "until": "2026-09-12T00:00:00Z", "appeal": null}
        """)

        XCTAssertTrue(suspension.suspended)
        XCTAssertEqual(suspension.reason, "Repeated replies after being asked to stop.")
        XCTAssertNotNil(suspension.until)
        XCTAssertFalse(suspension.isIndefinite)
        XCTAssertFalse(suspension.hasAppealed)
    }

    /// **`until: null` means indefinite.** Not "unknown", and not "today".
    func testANullUntilIsIndefiniteAndNotAMissingValue() throws {
        let suspension = try decode(Suspension.self, """
        {"suspended": true, "reason": null, "until": null, "appeal": null}
        """)

        XCTAssertTrue(suspension.isIndefinite)
        XCTAssertNil(suspension.reason, "an empty reason is not invented into one")
    }

    func testAnAppealOnFileDecodesWithItsStatus() throws {
        let suspension = try decode(Suspension.self, """
        {"suspended": true, "reason": "x", "until": null,
         "appeal": {"submitted_at": "2026-08-26T09:00:00Z", "status": "pending"}}
        """)

        XCTAssertTrue(suspension.hasAppealed)
        XCTAssertEqual(suspension.appeal?.status, .pending)
        XCTAssertNotNil(suspension.appeal?.submittedAt)
    }

    /// `POST /me/appeal` answers `{"id", "status": "pending"}` — no timestamp.
    /// The client records that it has no date rather than stamping "now" on it.
    func testTheAppealResponseDecodesWithoutInventingATimestamp() throws {
        let appeal = try decode(SuspensionAppeal.self, #"{"id": "apl_1", "status": "pending"}"#)

        XCTAssertEqual(appeal.status, .pending)
        XCTAssertNil(appeal.submittedAt)
    }

    /// A status vocabulary the client does not own must not make the one screen
    /// a suspended account can reach fail to render.
    func testAnUnknownAppealStatusStillRenders() {
        XCTAssertEqual(AppealStatus(serverValue: "under_review"), .reviewing)
        XCTAssertEqual(AppealStatus(serverValue: "APPROVED"), .upheld)
        XCTAssertEqual(AppealStatus(serverValue: "denied"), .rejected)
        XCTAssertEqual(AppealStatus(serverValue: "escalated_to_legal"), .unknown)
        XCTAssertFalse(AppealStatus.unknown.label.isEmpty)
    }

    /// A malformed body defaults to `suspended: true`. This endpoint is only
    /// read because something already said the account was suspended, and
    /// guessing "fine" would hand somebody an app the server will refuse.
    func testAMalformedSuspensionBodyFailsClosed() throws {
        let suspension = try decode(Suspension.self, #"{"reason": "x"}"#)
        XCTAssertTrue(suspension.suspended)
    }

    // MARK: - Routing

    /// **Only** `account_suspended` routes. Everything else is an ordinary
    /// failure the screen that made the call has to report itself.
    func testOnlyTheSuspensionCodeProducesTheSuspensionRoute() {
        XCTAssertEqual(
            SafetyRouting.route(forError: APIError.api(code: .accountSuspended, message: "…", status: 403)),
            .suspended
        )
        // A 403 that is not a suspension — a block on a reply — is not a route.
        XCTAssertNil(SafetyRouting.route(forError: APIError.api(code: .blocked, message: "…", status: 403)))
        XCTAssertNil(SafetyRouting.route(forError: APIError.api(code: .selfBlock, message: "…", status: 400)))
        XCTAssertNil(SafetyRouting.route(forError: APIError.api(code: .accountDeactivated, message: "…", status: 403)))
        XCTAssertNil(SafetyRouting.route(forError: APIError.transport("offline")))
        XCTAssertNil(SafetyRouting.route(forError: APIError.unauthenticated))
    }

    func testTheLoadedRecordDecidesTheRouteToo() {
        XCTAssertEqual(SafetyRouting.route(for: Suspension(suspended: true)), .suspended)
        XCTAssertEqual(SafetyRouting.route(for: Suspension(suspended: false)), .normal)
    }

    // MARK: - Error codes

    /// Every safety code the contract lists maps to a case, and every one of
    /// them has a sentence safe to show a user.
    func testEverySafetyErrorCodeIsRecognisedAndSpeakable() {
        let expected: [String: APIErrorCode] = [
            "self_block": .selfBlock,
            "self_mute": .selfMute,
            "self_report": .selfReport,
            "invalid_reason": .invalidReason,
            "blocked": .blocked,
            "account_suspended": .accountSuspended,
            "rate_limited": .rateLimited,
            "user_not_found": .userNotFound,
            "already_appealed": .alreadyAppealed
        ]
        for (raw, code) in expected {
            XCTAssertEqual(APIErrorCode(serverCode: raw), code, raw)
            let message = APIError.api(code: code, message: "", status: 400).userMessage
            XCTAssertFalse(message.isEmpty, "\(raw) has no user-facing sentence")
        }
    }

    /// `blocked` on a reply must never say **which** direction the block runs.
    /// Turning a safety tool into a notification is the one thing it cannot do.
    func testTheBlockedReplyMessageNeverNamesWhoBlockedWhom() {
        let message = APIError.api(code: .blocked, message: "", status: 403).userMessage
        XCTAssertTrue(message.contains("block between you"))
        for leak in ["they blocked", "they have blocked", "you were blocked", "has blocked you"] {
            XCTAssertFalse(message.lowercased().contains(leak), "leaks direction: \(leak)")
        }
    }
}
