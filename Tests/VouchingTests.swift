import XCTest
@testable import Sila

/// Contract v24 on iOS, §11 and §12 included: what vouching reads from the
/// wire, what it sends, what it says in both languages, and where each
/// screen, row and push leads.
///
/// Two rules are asserted wherever they could break: the tag is never drawn
/// beside the seal, and what a voucher wrote about somebody never reaches
/// that somebody — a mismatch names the field, never the value.
@MainActor
final class VouchingTests: XCTestCase {

    override func tearDown() {
        L10n.use(nil)
        super.tearDown()
    }

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONCoding.decoder.decode(T.self, from: Data(json.utf8))
    }

    /// Arabic sentences carry invisible direction marks: Foundation isolates
    /// each argument (U+2068 … U+2069), the catalogue keeps "@handle" one
    /// left-to-right piece (U+2066 … U+2069) and starts a sentence that opens
    /// on it right-to-left (U+200F). The words are compared without them.
    private func plain(_ text: String?) -> String? {
        text.map { String($0.unicodeScalars.filter { !(0x2066...0x2069).contains($0.value) && $0.value != 0x200F }.map(Character.init)) }
    }

    func testAHandleInsideArabicStaysOnePieceWithItsAt() {
        L10n.use("ar")
        let tag = VouchCopy.tag(Self.aziz).unicodeScalars.map(\.value)
        let lri = tag.firstIndex(of: 0x2066)
        let at = tag.firstIndex(of: 0x40)
        XCTAssertNotNil(lri, "the handle is not isolated left-to-right")
        XCTAssertEqual(lri.map { $0 + 1 }, at, "the @ sits inside the isolate, beside its handle")
    }

    private static let aziz = VouchedBy(
        id: UUID(uuidString: "44444444-0000-4000-8000-0000000000a1")!,
        handle: "aziz", since: ISODay.date("2026-09-03"), country: "SA"
    )

    // MARK: - The tag on the wire (§3, §11)

    func testTheTagIsReadAndNeverDrawnBesideTheSeal() throws {
        let vouched = try decode(UserSummary.self, """
        {"id": "11111111-0000-4000-8000-000000000001", "handle": "khalid", "display_name": "Khalid",
         "is_verified": false, "country_code": null,
         "vouched_by": {"id": "44444444-0000-4000-8000-0000000000a1", "handle": "aziz", "display_name": "Aziz",
                        "since": "2026-09-03T10:00:00+00:00", "country": "sa"}}
        """)
        let tag = try XCTUnwrap(vouched.vouchedBy)
        XCTAssertEqual(tag.handle, "aziz")
        XCTAssertEqual(tag.country, "SA", "the nationality is read as an ISO code, upper-cased")
        XCTAssertNil(vouched.countryCode, "the country is text beside the tag, never the flag's code")

        let sealed = try decode(UserSummary.self, """
        {"id": "11111111-0000-4000-8000-000000000002", "handle": "noura", "display_name": "Noura",
         "is_verified": true, "country_code": "SA",
         "vouched_by": {"id": "44444444-0000-4000-8000-0000000000a1", "handle": "aziz"}}
        """)
        XCTAssertNil(sealed.vouchedBy, "the seal wins: a tag beside is_verified is never kept")
        XCTAssertNil(UserSummary(id: UUID(), handle: "x", displayName: "X", isVerified: true, vouchedBy: Self.aziz).vouchedBy)
    }

    func testATagWithNoHandleOrACountryNobodyCanNameIsNotGuessed() throws {
        let noHandle = try decode(UserSummary.self, """
        {"id": "11111111-0000-4000-8000-000000000003", "handle": "k", "display_name": "K", "is_verified": false,
         "vouched_by": {"id": "44444444-0000-4000-8000-0000000000a1", "handle": ""}}
        """)
        XCTAssertNil(noHandle.vouchedBy, "a tag with no handle is nothing to draw")

        let oddCountry = try decode(VouchedBy.self, #"{"id": "44444444-0000-4000-8000-0000000000a1", "handle": "aziz", "country": "Saudi"}"#)
        XCTAssertNil(oddCountry.country)
        L10n.use("en")
        XCTAssertEqual(VouchCopy.tag(oddCountry), "vouched by @aziz", "no country, no guess: the tag alone")
    }

    func testTheTagReadsVouchedByHandleAndCountryInBothLanguages() {
        L10n.use("en")
        XCTAssertEqual(VouchCopy.tag(Self.aziz), "vouched by @aziz · Saudi Arabia")
        XCTAssertEqual(VouchCopy.tagAccessibility(Self.aziz),
                       "Vouched for by @aziz. Nationality given: Saudi Arabia. Not identity\u{2011}verified.")
        XCTAssertFalse(VouchCopy.tag(Self.aziz).localizedCaseInsensitiveContains("verified by"))
        XCTAssertEqual(VouchCopy.profileRow(Self.aziz),
                       "Not identity\u{2011}verified · vouched for by @aziz since \(SLFormat.dayAndMonth(Self.aziz.since!))")

        L10n.use("ar")
        XCTAssertEqual(plain(VouchCopy.tag(Self.aziz)), "بتزكية @aziz · السعودية")
        XCTAssertEqual(plain(VouchCopy.tagAccessibility(Self.aziz)), "مُزكّى من @aziz. الجنسية المُعلنة: السعودية. لم يوثّق هويته بعد.")
        XCTAssertFalse(VouchCopy.tag(Self.aziz).contains("🇸🇦"), "never a flag")
    }

    // MARK: - Standing (§2)

    private func user(_ json: String) throws -> AuthUser {
        try decode(AuthUser.self, """
        {"id": "11111111-2222-3333-4444-555555555555", "email": "k@example.com", "email_verified": true,
         "created_at": "2026-09-01T00:00:00+00:00", \(json)}
        """)
    }

    func testStandingIsReadAndIdentityAlwaysWins() throws {
        let vouched = try user("""
        "verification_status": "rejected", "standing": "vouched",
        "vouch": {"id": "66666666-0000-4000-8000-000000000001", "status": "active", "voucher_handle": "aziz",
                  "accepted_at": "2026-09-20T00:00:00+00:00", "confirmed_at": "2026-09-20T01:00:00+00:00",
                  "expires_at": "2026-10-20T01:00:00+00:00"}
        """)
        XCTAssertTrue(vouched.isVouched, "a refused document does not end a vouch")
        XCTAssertEqual(vouched.vouch?.status, .active)
        XCTAssertEqual(vouched.vouch?.atVoucher, "@aziz")

        let verified = try user(#""verification_status": "verified", "standing": "vouched""#)
        XCTAssertEqual(verified.standing, .verified, "identity always wins")

        let pending = try user("""
        "verification_status": "unstarted", "standing": "none",
        "vouch": {"id": "66666666-0000-4000-8000-000000000002", "status": "pending", "voucher_handle": "aziz",
                  "confirm_by": "2026-09-27T00:00:00+00:00"}
        """)
        XCTAssertFalse(pending.isVouched)
        XCTAssertEqual(pending.vouch?.isPending, true)
    }

    func testAnOlderServerWithoutStandingReadsFromTheStatus() throws {
        XCTAssertEqual(try user(#""verification_status": "verified""#).standing, .verified)
        XCTAssertEqual(try user(#""verification_status": "unstarted""#).standing, .noStanding)
        XCTAssertEqual(try user(#""verification_status": "unstarted", "standing": "someday""#).standing, .noStanding,
                       "a standing this build cannot name is the wall, the safe reading")
    }

    // MARK: - The voucher's list (§5, §11)

    func testTheOverviewSurvivesAnUnreadableRowAndReadsWhatTheVoucherWrote() throws {
        let overview = try decode(VouchingOverview.self, """
        {"can_vouch": false, "reason": {"code": "vouch_slots_full", "message": "You can stand behind 3 people at a time"},
         "slots": {"total": 3, "used": 3, "available": 0}, "verified_since": "2026-01-01T00:00:00+00:00",
         "privilege": {"active": true, "reason": null, "until": null, "strikes": 0},
         "vouches": [
           {"id": "66666666-0000-4000-8000-000000000001", "status": "pending", "vouchee_handle": "khalid",
            "accepted_at": "2026-09-26T00:00:00+00:00", "confirm_by": "2026-09-28T00:00:00+00:00", "label": "work",
            "details": {"full_name": "Khalid Al-Harbi", "nationality": "SA", "date_of_birth": "1995-04-12"}},
           {"status": "active"}
         ],
         "ended": [{"id": "66666666-0000-4000-8000-000000000003", "status": "ended", "end_reason": "expired",
                    "vouchee": null, "vouchee_handle": "sara"}],
         "invites": [{"id": "77777777-0000-4000-8000-000000000001", "state": "closed", "mismatches": 3,
                      "details": {"full_name": "Faisal", "nationality": "SA", "date_of_birth": "2001-09-03"}}],
         "rules": {"vouch_days": 30, "invite_hours": 72, "confirm_hours": 48}}
        """)
        XCTAssertEqual(overview.vouches.count, 1, "the row with no id costs that row, not the list")
        XCTAssertEqual(overview.pending.first?.details?.fullName, "Khalid Al-Harbi")
        XCTAssertEqual(overview.pending.first?.label, "work")
        XCTAssertEqual(overview.ended.first?.atVouchee, "@sara", "the handle snapshot stands in for a gone account")
        XCTAssertEqual(overview.invites.first?.state, .closed)
        XCTAssertEqual(overview.invites.first?.mismatches, 3)
        XCTAssertTrue(overview.isOpen)
        XCTAssertEqual(overview.rules.voucherMinVerifiedDays, 30, "a rule the server left out reads as the contract's")
    }

    func testNotOpenHidesTheEntryAndAStrikeSaysTheRightIsGone() async {
        let closed = VouchingViewModel(service: VouchingServiceMock(scenario: .notOpen))
        await closed.load()
        XCTAssertFalse(closed.isOpen, "vouching_not_open: nothing is offered")

        let struck = VouchingViewModel(service: VouchingServiceMock(scenario: .struck))
        await struck.load()
        XCTAssertTrue(struck.isOpen)
        XCTAssertTrue(struck.privilegeLost, "one strike ends the right to vouch")
        L10n.use("en")
        XCTAssertEqual(struck.refusalText, "Your right to vouch has been withdrawn.")
    }

    func testConfirmDeclineWithdrawAndBurnReachTheServerAndTheListIsReadAgain() async throws {
        let mock = VouchingServiceMock(scenario: .voucher)
        let model = VouchingViewModel(service: mock)
        await model.load()
        let overview = try XCTUnwrap(model.overview)
        XCTAssertEqual(overview.pending.count, 1)
        XCTAssertEqual(overview.active.count, 1)
        XCTAssertTrue(overview.active[0].awaitsAnswer, "a moderator's open question is shown on the vouch")

        await model.confirm(overview.pending[0])
        XCTAssertEqual(model.overview?.pending.count, 0)
        XCTAssertEqual(model.overview?.active.count, 2)

        let invite = try XCTUnwrap(model.overview?.invites.first)
        await model.burn(invite)
        XCTAssertTrue(model.overview?.invites.isEmpty == true)

        let calls = await mock.recordedCalls
        XCTAssertEqual(calls, ["overview", "confirm", "overview", "burnInvite", "overview"])
    }

    func testAnAnswerToAFindingNeedsTenCharacters() async throws {
        let mock = VouchingServiceMock(scenario: .voucher)
        let model = VouchingViewModel(service: mock)
        await model.load()
        let summoned = try XCTUnwrap(model.overview?.active.first)
        model.statements[summoned.id] = "short"
        await model.answer(summoned, .reattest)
        let before = await mock.recordedCalls
        XCTAssertFalse(before.contains("answer:reattest"), "nine characters never reach the server")

        model.statements[summoned.id] = "I have known him for ten years."
        await model.answer(summoned, .reattest)
        let after = await mock.recordedCalls
        XCTAssertTrue(after.contains("answer:reattest"))
    }

    // MARK: - Minting a link (§5, §11, §12)

    func testMintingWaitsForTheWarningsTheDetailsAndTheFourPromises() async throws {
        let mock = VouchingServiceMock(scenario: .empty)
        var minted = 0
        let model = VouchInviteViewModel(service: mock, analytics: RecordingAnalyticsClient(), onMinted: { minted += 1 })
        model.draft = VouchDetailsDraft(fullName: "Khalid Al-Harbi", nationality: "SA", dateOfBirth: ISODay.date("1995-04-12"))
        model.knowsPersonally = true; model.adult = true; model.realName = true; model.singleAccount = true
        XCTAssertFalse(model.canMint, "the two warnings come before anything can be minted")

        model.hasAcknowledgedWarnings = true
        XCTAssertTrue(model.canMint)
        model.singleAccount = false
        XCTAssertFalse(model.canMint, "all four promises, every time")
        model.singleAccount = true

        await model.mint()
        XCTAssertEqual(minted, 1)
        XCTAssertEqual(model.minted?.invite.details?.fullName, "Khalid Al-Harbi")
        XCTAssertFalse(model.canMint, "one link per sheet")
    }

    func testSomebodyUnder18IsRefusedBeforeALinkIsSpent() async {
        let mock = VouchingServiceMock(scenario: .empty)
        let model = VouchInviteViewModel(service: mock, analytics: RecordingAnalyticsClient(), onMinted: {})
        model.hasAcknowledgedWarnings = true
        model.draft = VouchDetailsDraft(fullName: "Young One", nationality: "SA",
                                        dateOfBirth: Calendar(identifier: .gregorian).date(byAdding: .year, value: -17, to: Date()))
        model.knowsPersonally = true; model.adult = true; model.realName = true; model.singleAccount = true
        await model.mint()
        XCTAssertNotNil(model.fieldErrors[.dateOfBirth])
        let calls = await mock.recordedCalls
        XCTAssertTrue(calls.isEmpty, "nothing is sent for a date nobody may be vouched for")
    }

    func testAMintRefusalIsSaidInTheReadersLanguage() async {
        L10n.use("ar")
        let model = VouchInviteViewModel(service: VouchingServiceMock(scenario: .notOpen),
                                         analytics: RecordingAnalyticsClient(), onMinted: {})
        model.hasAcknowledgedWarnings = true
        model.draft = VouchDetailsDraft(fullName: "خالد الحربي", nationality: "SA", dateOfBirth: ISODay.date("1995-04-12"))
        model.knowsPersonally = true; model.adult = true; model.realName = true; model.singleAccount = true
        await model.mint()
        XCTAssertEqual(model.errorMessage, "التزكية متاحة قريبًا.", "the server's English sentence is not what an Arabic reader sees")
    }

    func testTheServiceSendsTheFourPromisesAndTheDetailsAsTyped() async throws {
        let network = StubNetworkClient(responses: ["""
        {"invite": {"id": "77777777-0000-4000-8000-000000000009", "state": "open", "label": null,
                    "created_at": "2026-09-26T00:00:00+00:00", "expires_at": "2026-09-29T00:00:00+00:00",
                    "details": {"full_name": "khalid  al-harbi.", "nationality": "SA", "date_of_birth": "1995-04-12"},
                    "mismatches": 0},
         "token": "abcdefghijklmnopqrstuvwxyz012345", "url": "https://sila.gmai.sa/vouch/abcdefghijklmnopqrstuvwxyz012345"}
        """])
        let analytics = RecordingAnalyticsClient()
        let service = VouchingService(network: network, tokens: StaticAccessTokenProvider(token: "t"), analytics: analytics)

        let minted = try await service.mintInvite(
            label: "  ",
            details: VouchDetails(fullName: "khalid  al-harbi.", nationality: "sa", dateOfBirth: "1995-04-12")
        )

        let request = try XCTUnwrap(network.lastRequest)
        XCTAssertEqual(request.path, "/vouching/invites")
        XCTAssertEqual(request.method, .post)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.body)) as? [String: Any])
        XCTAssertNil(body["label"], "a blank note is not sent")
        XCTAssertEqual(body["attestations"] as? [String: Bool],
                       ["knows_personally": true, "adult": true, "real_name": true, "single_account": true])
        XCTAssertEqual(body["details"] as? [String: String],
                       ["full_name": "khalid  al-harbi.", "nationality": "SA", "date_of_birth": "1995-04-12"],
                       "the name goes as typed — the server folds it; the nationality upper-cased")
        XCTAssertEqual(minted.url.absoluteString, "https://sila.gmai.sa/vouch/abcdefghijklmnopqrstuvwxyz012345")
        XCTAssertEqual(analytics.events, [.vouchLinkCreated])
        XCTAssertTrue(analytics.recorded.allSatisfy { $0.properties.isEmpty }, "nothing typed reaches analytics")
    }

    // MARK: - The claim (§5, §11, §12)

    private func claimModel(
        signedIn: Bool = true,
        standing: Standing = .noStanding,
        mock: VouchingServiceMock = VouchingServiceMock(),
        onClaimed: @escaping @MainActor (VouchState?) async -> Void = { _ in }
    ) -> VouchClaimViewModel {
        VouchClaimViewModel(token: VouchingServiceMock.openToken, isSignedIn: signedIn, standing: standing,
                            service: mock, onClaimed: onClaimed)
    }

    private func fill(_ model: VouchClaimViewModel, name: String = "Khalid Al-Harbi", born: String = "1995-04-12") {
        model.hasAcknowledgedWarnings = true
        model.draft = VouchDetailsDraft(fullName: name, nationality: "SA", dateOfBirth: ISODay.date(born))
        model.adult = true; model.realName = true; model.singleAccount = true; model.terms = true
    }

    func testALinkThatCannotBeUsedIsOneState() async {
        let model = VouchClaimViewModel(token: "someone-elses-link-0000", isSignedIn: true,
                                        service: VouchingServiceMock(), onClaimed: { _ in })
        await model.load()
        XCTAssertEqual(model.phase, .unavailable)
    }

    func testTheWarningsComeBeforeTheFormEveryTime() async {
        let model = claimModel()
        await model.load()
        guard case .open = model.phase else { return XCTFail("the landing did not open") }
        fill(model)
        model.hasAcknowledgedWarnings = false
        XCTAssertFalse(model.canSubmit, "no claim before the two warnings")
        await model.submit()
        XCTAssertEqual(model.phase.isOpen, true, "submitting without them does nothing")

        XCTAssertFalse(claimModel().hasAcknowledgedWarnings, "a fresh open of the link asks again")
    }

    func testAMismatchNamesTheFieldsKeepsWhatWasTypedAndCountsDown() async throws {
        L10n.use("en")
        let mock = VouchingServiceMock()
        let model = claimModel(mock: mock)
        await model.load()
        fill(model, name: "Khaled Al-Harbi", born: "1995-04-13")

        await model.submit()

        XCTAssertEqual(model.mismatched, [.fullName, .dateOfBirth], "which fields, in the server's order")
        XCTAssertEqual(model.attemptsLeft, 2)
        XCTAssertEqual(model.draft.fullName, "Khaled Al-Harbi", "what was typed stays, to be corrected — never replaced")
        let text = try XCTUnwrap(model.mismatchText)
        XCTAssertEqual(text, "These don't match what @noura entered: name, date of birth")
        let written = VouchingServiceMock.expectedDetails
        XCTAssertFalse(text.contains(written.fullName) || text.contains(written.dateOfBirth) || text.contains("Khalid"),
                       "never what the voucher wrote")
        XCTAssertEqual(VouchCopy.attemptsLeft(2), "2 tries left")

        L10n.use("ar")
        XCTAssertEqual(plain(model.mismatchText), "هذه لا تطابق ما أدخله @noura: الاسم، تاريخ الميلاد")
    }

    func testACorrectedClaimAfterAMismatchIsAccepted() async {
        let model = claimModel()
        await model.load()
        fill(model, name: "Khaled Al-Harbi")
        await model.submit()
        XCTAssertEqual(model.mismatched, [.fullName])
        model.draft.fullName = "Khalid Al-Harbi"
        await model.submit()
        guard case .claimed = model.phase else { return XCTFail("the corrected claim was not accepted: \(model.phase), \(String(describing: model.errorMessage))") }
        XCTAssertTrue(model.mismatched.isEmpty)
    }

    func testTheThirdMismatchClosesTheLinkForGood() async {
        let model = claimModel()
        await model.load()
        fill(model, name: "Somebody Else")
        await model.submit()
        await model.submit()
        XCTAssertEqual(model.attemptsLeft, 1)
        await model.submit()
        XCTAssertEqual(model.phase, .closed)
    }

    func testTheRightDetailsClaimAndTheVoucherIsAskedToConfirm() async throws {
        var handedOver: VouchState?
        let mock = VouchingServiceMock()
        let model = claimModel(mock: mock, onClaimed: { handedOver = $0 })
        await model.load()
        // Spacing, case and punctuation are the server's to fold.
        fill(model, name: "khalid  AL-HARBI")
        await model.submit()

        guard case let .claimed(vouch) = model.phase else { return XCTFail("not claimed: \(model.phase)") }
        XCTAssertEqual(vouch?.status, .pending)
        XCTAssertEqual(handedOver?.voucherHandle, "noura")
        let sent = await mock.lastClaimedDetails
        XCTAssertEqual(sent?.fullName, "khalid  AL-HARBI", "sent as typed")
    }

    func testSomebodyUnder18IsToldBeforeATryIsSpent() async {
        let mock = VouchingServiceMock()
        let model = claimModel(mock: mock)
        await model.load()
        fill(model)
        model.draft.dateOfBirth = Calendar(identifier: .gregorian).date(byAdding: .year, value: -16, to: Date())
        await model.submit()
        XCTAssertNotNil(model.fieldErrors[.dateOfBirth])
        let calls = await mock.recordedCalls
        XCTAssertEqual(calls, ["landing"], "no claim was sent, so no try was spent")
    }

    func testAVerifiedOrVouchedAccountIsToldAtOnce() async {
        let mock = VouchingServiceMock()
        let verified = claimModel(standing: .verified, mock: mock)
        await verified.load()
        guard case .refused = verified.phase else { return XCTFail("a verified account was offered the form") }
        let vouched = claimModel(standing: .vouched, mock: mock)
        await vouched.load()
        guard case .refused = vouched.phase else { return XCTFail("a vouched account was offered the form") }
        let calls = await mock.recordedCalls
        XCTAssertTrue(calls.isEmpty, "nothing is asked that the server would refuse")
    }

    func testSignedOutReadsTheLandingAndCannotClaim() async {
        let model = claimModel(signedIn: false, standing: .verified)
        await model.load()
        XCTAssertEqual(model.voucher?.handle, "noura", "the landing is public; a stale standing is ignored signed out")
        fill(model)
        XCTAssertFalse(model.canSubmit, "sign up or sign in first")
    }

    func testTheClaimRecordsTheRefusalCodeAndNothingTyped() async throws {
        let network = StubNetworkClient(error: .detailsMismatch(fields: ["full_name"], attemptsLeft: 2, message: "x"))
        let analytics = RecordingAnalyticsClient()
        let service = VouchingService(network: network, tokens: StaticAccessTokenProvider(token: "t"), analytics: analytics)
        do {
            _ = try await service.claim(token: "abcdefghijklmnopqrstuvwxyz012345",
                                        details: VouchDetails(fullName: "Khalid", nationality: "SA", dateOfBirth: "1995-04-12"))
            XCTFail("expected the mismatch")
        } catch APIError.detailsMismatch(let fields, let left, _) {
            XCTAssertEqual(fields, ["full_name"])
            XCTAssertEqual(left, 2)
        }
        let request = try XCTUnwrap(network.lastRequest)
        XCTAssertEqual(request.path, "/vouch/invites/abcdefghijklmnopqrstuvwxyz012345/claim")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.body)) as? [String: Any])
        XCTAssertEqual(body["attestations"] as? [String: Bool],
                       ["adult": true, "real_name": true, "single_account": true, "terms": true])
        let recorded = try XCTUnwrap(analytics.recorded.last)
        XCTAssertEqual(recorded.event, .vouchClaimRefused)
        XCTAssertEqual(recorded.properties, ["reason": "details_mismatch"], "which refusal, never which field or what")
    }

    func testTheLandingIsReadWithoutASession() async throws {
        let network = StubNetworkClient(responses: ["""
        {"voucher": {"id": "44444444-0000-4000-8000-000000000001", "handle": "noura", "display_name": "Noura",
                     "is_verified": true, "country_code": "SA"}, "expires_at": "2026-09-29T00:00:00+00:00"}
        """])
        let service = VouchingService(network: network, tokens: StaticAccessTokenProvider(token: nil),
                                      analytics: RecordingAnalyticsClient())
        let landing = try await service.landing(token: "abcdefghijklmnopqrstuvwxyz012345")
        XCTAssertEqual(landing.voucher.handle, "noura")
        XCTAssertNil(network.lastRequest?.accessToken, "a guest opens it")
        XCTAssertEqual(network.lastRequest?.path, "/public/vouch-invites/abcdefghijklmnopqrstuvwxyz012345")
    }

    // MARK: - Errors (§9, §11)

    func testAMismatchArrivesAsFieldsAndTriesLeftNeverValues() {
        let error = URLSessionNetworkClient.makeError(status: 409, data: Data("""
        {"detail": {"code": "details_mismatch", "message": "Some of your details don't match",
                    "fields": ["full_name", "date_of_birth"], "attempts_left": 1}}
        """.utf8))
        XCTAssertEqual(error, .detailsMismatch(fields: ["full_name", "date_of_birth"], attemptsLeft: 1,
                                               message: "Some of your details don't match"))
        XCTAssertEqual(error.code, .detailsMismatch)

        let closed = URLSessionNetworkClient.makeError(status: 409, data: Data(
            #"{"detail": {"code": "invite_closed", "message": "closed"}}"#.utf8))
        XCTAssertEqual(closed.code, .inviteClosed)
        let selfVerify = URLSessionNetworkClient.makeError(status: 403, data: Data(
            #"{"detail": {"code": "self_verification_required", "message": "Verify your identity to take the microphone"}}"#.utf8))
        XCTAssertEqual(selfVerify.code, .selfVerificationRequired)
    }

    func testAValidationErrorStillReadsItsFieldObjects() {
        let error = URLSessionNetworkClient.makeError(status: 422, data: Data("""
        {"detail": {"code": "validation_error", "message": "x",
                    "fields": [{"field": "label", "type": "string_too_long", "ctx": {"max_length": 60}}]}}
        """.utf8))
        XCTAssertEqual(error.code, .validationError, "the shared `fields` key still reads as objects here")
    }

    // MARK: - Deep links (§5, §8)

    func testVouchLinksParse() {
        func parse(_ raw: String) -> DeepLink? { DeepLink.parse(URL(string: raw)!) }
        XCTAssertEqual(parse("https://sila.gmai.sa/vouch/abcdefghijklmnopqrstuvwxyz012345"),
                       .vouchInvite(token: "abcdefghijklmnopqrstuvwxyz012345"))
        XCTAssertEqual(parse("https://sila.gmai.sa/vouch"), .ownVouch)
        XCTAssertEqual(parse("https://sila.gmai.sa/vouching"), .vouching)
        XCTAssertNil(parse("https://sila.gmai.sa/vouch/short"), "not a token the server makes")
        XCTAssertNil(parse("https://sila.gmai.sa/vouch/abc%2F..%2Fadmin0000000000000"), "nothing that could become another path")
        XCTAssertNil(parse("https://evil.example/vouch/abcdefghijklmnopqrstuvwxyz012345"))
    }

    // MARK: - The inbox

    func testTheInboxKeepsALinkThroughARelaunchAndLetsGo() {
        let storage = InMemoryStorageClient()
        let inbox = VouchInviteInbox(storage: storage)
        inbox.receive(token: "abcdefghijklmnopqrstuvwxyz012345")
        inbox.park()
        XCTAssertTrue(inbox.isParked)

        let relaunched = VouchInviteInbox(storage: storage)
        XCTAssertEqual(relaunched.pending?.token, "abcdefghijklmnopqrstuvwxyz012345", "kept through the email code and a relaunch")
        XCTAssertFalse(relaunched.isParked)

        relaunched.settle()
        XCTAssertNotNil(relaunched.pending, "the claimed screen stays until it is closed")
        XCTAssertNil(VouchInviteInbox(storage: storage).pending, "but a relaunch has nothing to come back to")

        inbox.forget()
        XCTAssertNil(inbox.pending)
    }

    func testALinkHeldLongerThanItCouldWorkIsDropped() {
        let storage = InMemoryStorageClient()
        storage.set(PendingVouchInvite(token: "abcdefghijklmnopqrstuvwxyz012345", receivedAt: Date().addingTimeInterval(-73 * 3600)),
                    for: VouchInviteInbox.storageKey)
        XCTAssertNil(VouchInviteInbox(storage: storage).pending)
    }

    // MARK: - The person's side

    func testTakingTheTagOffTellsTheSession() async {
        var changed = false
        let model = OwnVouchViewModel(service: VouchingServiceMock(), onChanged: { changed = true })
        await model.remove()
        XCTAssertTrue(changed, "the session re-reads /auth/me and routes back to the wall")
        XCTAssertFalse(model.rights.directMessages, "the contract's table before the server has answered: no messages")
        XCTAssertFalse(model.rights.hostRooms)
        XCTAssertTrue(model.rights.allows("post_international"))
    }

    func testTheWallSaysWhoItIsWaitingFor() {
        L10n.use("en")
        let pending = AuthServiceMock.mockVouch(pending: true)
        let wall = WallPresentation.make(for: .unstarted, pendingVouch: pending)
        XCTAssertEqual(wall.title, "Waiting for @noura to confirm it's you")
        XCTAssertEqual(WallPresentation.make(for: .rejected, pendingVouch: pending).title, wall.title,
                       "a refused document does not hide the claim")
        XCTAssertEqual(WallPresentation.make(for: .pendingReview, pendingVouch: pending),
                       WallPresentation.make(for: .pendingReview), "a submission under review keeps its own copy")
        L10n.use("ar")
        XCTAssertEqual(plain(WallPresentation.make(for: .unstarted, pendingVouch: pending).title), "بانتظار أن يؤكّد @noura أنك أنت")
    }

    // MARK: - Routing (§2)

    private func session(_ user: AuthUser, scenario: AuthServiceMock.MockScenario = .unstarted) async -> AuthSession {
        let session = AuthSession(
            service: AuthServiceMock(scenario: scenario),
            store: AuthTokenStore(keychain: InMemoryKeychainClient(), storage: InMemoryStorageClient()),
            analytics: RecordingAnalyticsClient()
        )
        await session.adopt(TokenPair(
            token: AuthToken(accessToken: "a", refreshToken: "r", expiresAt: Date().addingTimeInterval(3600)),
            user: user
        ))
        return session
    }

    private func account(_ status: VerificationStatus) -> AuthUser {
        AuthUser(id: UUID(), email: "k@example.com", displayName: nil, emailVerified: true,
                 verificationStatus: status, createdAt: Date())
    }

    func testAVouchedAccountReachesTheFeedWhateverTheStatus() async {
        for status in [VerificationStatus.unstarted, .pendingReview, .rejected] {
            let user = account(status).settingVouch(AuthServiceMock.mockVouch(pending: false), standing: .vouched)
            let routed = await session(user)
            XCTAssertEqual(routed.route, .feed, "vouched with \(status) is a member, not the wall")
        }
    }

    func testAPendingClaimWaitsOnTheWallEvenAfterARefusedDocument() async {
        let user = account(.rejected).settingVouch(AuthServiceMock.mockVouch(pending: true), standing: .noStanding)
        let routed = await session(user, scenario: .rejected)
        XCTAssertEqual(routed.route, .verificationWall(.rejected))

        let fresh = await session(account(.unstarted))
        await fresh.adoptVouch(AuthServiceMock.mockVouch(pending: true))
        XCTAssertEqual(fresh.route, .verificationWall(.unstarted), "a claim waits at the wall")
        XCTAssertEqual(fresh.user?.vouch?.isPending, true, "and the wall has it at once")
    }

    // MARK: - The limited tier (§4)

    func testASelfVerificationRefusalOffersVerifyingNeverTheWall() {
        let gate = VerificationGate(analytics: RecordingAnalyticsClient())
        gate.noticeSelfVerification(message: " Verify your identity to take the microphone ")
        XCTAssertEqual(gate.selfVerificationPrompt?.message, "Verify your identity to take the microphone")
        XCTAssertNil(gate.selfVerificationPrompt?.reason, "the server's English is never drawn")
        XCTAssertFalse(gate.wasRefused, "not the wall")
        let first = gate.selfVerificationPrompt?.id
        gate.noticeSelfVerification(message: "again")
        XCTAssertEqual(gate.selfVerificationPrompt?.id, first, "a burst of refusals is one question")
    }

    func testAVouchedAccountsPollSaysVerifyToVote() throws {
        let poll = try decode(Poll.self, """
        {"id": "88888888-0000-4000-8000-000000000001", "options": [], "total_votes": 0,
         "closes_at": "2099-01-01T00:00:00+00:00", "closed": false, "results_visibility": "always",
         "results_visible": true, "viewer_option_id": null, "can_vote": false,
         "vote_block_reason": "self_verification_required"}
        """)
        XCTAssertEqual(poll.voteBlockReason, .selfVerificationRequired)
    }

    // MARK: - Notices (§7, §8, §11)

    private func notification(_ kind: String, detail: String? = nil) throws -> UserNotification {
        try decode(UserNotification.self, """
        {"id": "99999999-0000-4000-8000-000000000001", "kind": "\(kind)",
         "actor": {"id": "11111111-0000-4000-8000-000000000001", "handle": "khalid", "display_name": "Khalid", "is_verified": false},
         "post_id": null, "post_excerpt": null, "vouch_id": "66666666-0000-4000-8000-000000000001",
         "detail": \(detail.map { "\"\($0)\"" } ?? "null"), "read": false, "created_at": "2026-09-26T00:00:00+00:00"}
        """)
    }

    private static let allKinds = [
        "vouch_claimed", "vouch_confirmed", "vouch_declined", "vouch_expiring", "vouch_ended",
        "vouch_graduated", "vouch_verified", "vouch_review", "vouch_strike", "vouch_invite_closed",
    ]

    func testEveryVouchingKindDecodesWithItsVouchAndSaysItsOwnSentence() throws {
        L10n.use("en")
        var sentences = Set<String>()
        for kind in Self.allKinds {
            let row = try notification(kind)
            XCTAssertNotEqual(row.kind, .unknown, "\(kind) is not an unknown kind")
            XCTAssertEqual(row.vouchId, UUID(uuidString: "66666666-0000-4000-8000-000000000001"))
            XCTAssertFalse(row.sentence.contains("notifications."), "\(kind) renders its key")
            sentences.insert(row.sentence)
        }
        XCTAssertEqual(sentences.count, Self.allKinds.count, "every kind gets its own sentence")
        XCTAssertEqual(try notification("vouch_claimed").sentence, "Khalid accepted your vouch — confirm it's them")
        XCTAssertFalse(try notification("vouch_invite_closed").sentence.contains("Khalid"),
                       "three tries may be three accounts: the closed link names nobody")
        XCTAssertEqual(try notification("vouch_ended", detail: "expired").sentence, "A vouch has ended: The 30 days ran out")
    }

    func testVoucherRowsOpenTheListAndThePersonsOpenTheirOwnVouch() async throws {
        func open(_ kind: String, vouched: Bool) async throws -> NotificationDestination? {
            let model = NotificationsViewModel(
                service: NotificationsServiceMock(scenario: .empty), feed: FeedServiceMock(),
                analytics: RecordingAnalyticsClient(), viewerIsVouched: { vouched }
            )
            return await model.open(try notification(kind))
        }
        for kind in ["vouch_claimed", "vouch_graduated", "vouch_review", "vouch_strike", "vouch_invite_closed"] {
            let destination = try await open(kind, vouched: false)
            XCTAssertEqual(destination, .vouching, "\(kind) is the voucher's")
        }
        for kind in ["vouch_confirmed", "vouch_declined", "vouch_expiring", "vouch_verified"] {
            let destination = try await open(kind, vouched: true)
            XCTAssertEqual(destination, .ownVouch, "\(kind) is the person's")
        }
        let asVoucher = try await open("vouch_ended", vouched: false)
        let asPerson = try await open("vouch_ended", vouched: true)
        XCTAssertEqual(asVoucher, .vouching, "an ended vouch opens the side the reader is on")
        XCTAssertEqual(asPerson, .ownVouch)
    }

    func testEveryVouchPushHasAWordAndATapThatLands() {
        for kind in Self.allKinds {
            XCTAssertTrue(PushCopy.keys.contains("push.\(kind)"), "push.\(kind) has no string in the bundle")
        }
        XCTAssertEqual(PushCopy.vouchLink(forKind: "vouch_claimed"), .vouching)
        XCTAssertEqual(PushCopy.vouchLink(forKind: "vouch_invite_closed"), .vouching)
        XCTAssertEqual(PushCopy.vouchLink(forKind: "vouch_confirmed"), .ownVouch)
        XCTAssertEqual(PushCopy.vouchLink(forKind: "vouch_expiring"), .ownVouch)
        XCTAssertNil(PushCopy.vouchLink(forKind: "reply"))

        // The bundle's line names nobody: the payload carries no name to fill in.
        L10n.use("en")
        for kind in Self.allKinds {
            let line = L10n.t("push.\(kind)")
            XCTAssertNotEqual(line, "push.\(kind)")
            XCTAssertFalse(line.contains("%@"), "push.\(kind) expects a name the payload never carries")
        }
    }

    // MARK: - Copy

    func testDaysLeftRoundsUpAndSaysTheLastDay() {
        L10n.use("en")
        let now = Date()
        XCTAssertEqual(VouchCopy.daysLeftText(until: now.addingTimeInterval(86_400 * 22.2), now: now), "23 days left")
        XCTAssertEqual(VouchCopy.daysLeftText(until: now.addingTimeInterval(3_600), now: now), "Less than a day left")
        XCTAssertEqual(VouchCopy.hoursLeftText(until: now.addingTimeInterval(3_600 * 42.5), now: now), "43 hours")
    }

    func testEveryEndingAndFindingIsSaidInWords() {
        L10n.use("en")
        let reasons = ["self_verified", "expired", "unconfirmed", "withdrawn", "removed", "declined", "voucher_left",
                       "vouchee_left", "voucher_penalised", "impostor", "under_age", "false_attestation", "sold_link",
                       "verification_refused", "voucher_unverified", "voucher_suspended"]
        let words = Set(reasons.map(VouchCopy.endReason))
        XCTAssertEqual(words.count, reasons.count, "every ending is said its own way")
        for reason in reasons {
            XCTAssertFalse(VouchCopy.endReason(reason).contains("_"), "\(reason) reached the screen as a code")
        }
        XCTAssertEqual(VouchCopy.endReason("something_new"), "Ended")
        XCTAssertEqual(VouchCopy.finding("sold_link"), "The link was sold or passed on")
    }

    func testARefusalIsSaidWithTheOverviewsOwnNumbers() {
        L10n.use("en")
        let since = ISODay.date("2026-09-10")!
        let tooNew = VouchingOverview(canVouch: false, reason: VouchRefusal(code: "vouch_too_new", message: "x"), verifiedSince: since)
        XCTAssertTrue(VouchCopy.refusal(tooNew.reason!, in: tooNew).hasPrefix("You can vouch for people 30 days after verifying — from "))
        let first = VouchingOverview(canVouch: false, reason: VouchRefusal(code: "vouch_slots_full", message: "x"),
                                     slots: VouchSlots(total: 1, used: 1, available: 0))
        XCTAssertEqual(VouchCopy.refusal(first.reason!, in: first),
                       "Your first vouch has to verify their identity before you can vouch again.")
        let full = VouchingOverview(canVouch: false, reason: VouchRefusal(code: "vouch_slots_full", message: "x"),
                                    slots: VouchSlots(total: 3, used: 3, available: 0))
        XCTAssertEqual(VouchCopy.refusal(full.reason!, in: full), "You can stand behind 3 people at a time.")
        XCTAssertEqual(VouchCopy.refusal(VouchRefusal(code: "brand_new", message: "The server's words")), "The server's words",
                       "a code this build has no copy for shows the server's sentence")
    }
}

// MARK: - After the review (the fixer's pass)

/// What the code review and the simulator run found, each held by a test:
/// the answer to a finding survives a failed send, limits count the way the
/// server counts, the link sheet does not lose its one link, a claim already
/// waiting is refused at once, a dropped connection is not "this link can't
/// be used", `vouch_role` decides where a row goes, the waiting wall reads
/// the voucher's answer, and a link does not outlive a sign-out.
@MainActor
final class VouchingReviewTests: XCTestCase {

    override func tearDown() {
        L10n.use(nil)
        super.tearDown()
    }

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONCoding.decoder.decode(T.self, from: Data(json.utf8))
    }

    // MARK: The written answer (§5)

    func testAnAnswerThatFailsToSendIsKeptAndOneThatSendsIsCleared() async throws {
        let mock = VouchingServiceMock(scenario: .voucher)
        let model = VouchingViewModel(service: mock)
        await model.load()
        let summoned = try XCTUnwrap(model.overview?.active.first { $0.awaitsAnswer })
        let written = "I have known him since school and I stand by what I said."
        model.statements[summoned.id] = written

        await mock.setAnswerFailure(.transport("The network connection was lost."))
        await model.answer(summoned, .reattest)
        XCTAssertEqual(model.statements[summoned.id], written, "a failed send must not wipe the answer")
        XCTAssertNotNil(model.toast)

        await mock.setAnswerFailure(nil)
        await model.answer(summoned, .reattest)
        XCTAssertNil(model.statements[summoned.id], "sent: the box empties")
    }

    func testTheAnswersBoundsAreCountedAsTheServerCountsThem() async throws {
        let mock = VouchingServiceMock(scenario: .voucher)
        let model = VouchingViewModel(service: mock)
        await model.load()
        let summoned = try XCTUnwrap(model.overview?.active.first { $0.awaitsAnswer })
        // Five letters with a shadda and harakat: five characters on screen,
        // ten code points on the wire — the server's ten.
        model.statements[summoned.id] = "عَلِيّ نَعَم"
        XCTAssertLessThan(("عَلِيّ نَعَم" as String).count, 10)
        await model.answer(summoned, .reattest)
        let calls = await mock.recordedCalls
        XCTAssertTrue(calls.contains("answer:reattest"), "ten code points is ten to the server")
    }

    func testClampingCutsByCodePointsAndNeverThroughACharacter() {
        let tashkeel = "خَالِد"                                   // 3 letters + 3 marks = 6 code points
        XCTAssertEqual(tashkeel.serverLength, 6)
        XCTAssertEqual(tashkeel.clamped(toServerLength: 6), tashkeel)
        XCTAssertEqual(tashkeel.clamped(toServerLength: 3).serverLength, 3)
        let family = "👨‍👩‍👧" + "a"                                // one character, five code points
        XCTAssertEqual(family.clamped(toServerLength: 4), "", "a character is never split")
        XCTAssertEqual(family.clamped(toServerLength: 5), "👨‍👩‍👧")
        let note = String(repeating: "مَ", count: 40)              // 40 characters, 80 code points
        XCTAssertEqual(note.clamped(toServerLength: VouchInviteViewModel.labelLimit).serverLength, 60)
    }

    // MARK: The link sheet (§5)

    private func mintedSheet() async -> VouchInviteViewModel {
        let model = VouchInviteViewModel(service: VouchingServiceMock(scenario: .empty),
                                         analytics: RecordingAnalyticsClient(), onMinted: {})
        model.hasAcknowledgedWarnings = true
        model.draft = VouchDetailsDraft(fullName: "Khalid Al-Harbi", nationality: "SA", dateOfBirth: ISODay.date("1995-04-12"))
        model.knowsPersonally = true; model.adult = true; model.realName = true; model.singleAccount = true
        await model.mint()
        return model
    }

    func testAMintedLinkThatWentNowhereAsksBeforeTheSheetCloses() async {
        let model = await mintedSheet()
        XCTAssertNotNil(model.minted)
        XCTAssertFalse(model.mayCloseFreely, "no swipe away: the link is shown this once")
        XCTAssertFalse(model.requestClose(), "Done asks first")
        XCTAssertTrue(model.isConfirmingClose)
        XCTAssertTrue(model.requestClose(), "and closes when asked again")

        let copied = await mintedSheet()
        copied.didCopy()
        XCTAssertTrue(copied.mayCloseFreely)
        XCTAssertTrue(copied.requestClose())

        let shared = await mintedSheet()
        shared.didShare()
        XCTAssertTrue(shared.mayCloseFreely)

        let empty = VouchInviteViewModel(service: VouchingServiceMock(scenario: .empty),
                                         analytics: RecordingAnalyticsClient(), onMinted: {})
        XCTAssertTrue(empty.requestClose(), "nothing minted, nothing to lose")
    }

    // MARK: The claim (§5, §11)

    func testAClaimAlreadyWaitingIsRefusedBeforeTheWarningsAndTheForm() async {
        L10n.use("en")
        let mock = VouchingServiceMock()
        let model = VouchClaimViewModel(token: VouchingServiceMock.openToken, isSignedIn: true,
                                        pendingClaim: AuthServiceMock.mockVouch(pending: true),
                                        service: mock, onClaimed: { _ in })
        await model.load()
        guard case let .refused(message) = model.phase else { return XCTFail("offered the form: \(model.phase)") }
        XCTAssertTrue(message.contains("@noura"), message)
        let calls = await mock.recordedCalls
        XCTAssertTrue(calls.isEmpty, "the landing is not even read")
    }

    func testADroppedConnectionIsNotALinkThatCannotBeUsed() async {
        let mock = VouchingServiceMock()
        await mock.setLandingFailure(.transport("The request timed out."))
        let model = VouchClaimViewModel(token: VouchingServiceMock.openToken, isSignedIn: true,
                                        service: mock, onClaimed: { _ in })
        await model.load()
        guard case .failed = model.phase else { return XCTFail("a timeout read as \(model.phase)") }

        await mock.setLandingFailure(nil)
        await model.load()
        guard case .open = model.phase else { return XCTFail("the retry did not open the link") }

        await mock.setLandingFailure(.http(status: 500, message: "Internal Server Error"))
        await model.load()
        guard case .failed = model.phase else { return XCTFail("a server error read as \(model.phase)") }

        XCTAssertTrue(VouchClaimViewModel.isUnusableLink(APIError.api(code: .inviteUnavailable, message: "", status: 404)))
        XCTAssertTrue(VouchClaimViewModel.isUnusableLink(APIError.http(status: 404, message: "")))
        XCTAssertFalse(VouchClaimViewModel.isUnusableLink(APIError.transport("offline")))
    }

    func testEachMismatchIsCountedSoItCanBeAnnounced() async {
        let model = VouchClaimViewModel(token: VouchingServiceMock.openToken, isSignedIn: true,
                                        service: VouchingServiceMock(), onClaimed: { _ in })
        await model.load()
        model.hasAcknowledgedWarnings = true
        model.draft = VouchDetailsDraft(fullName: "Somebody Else", nationality: "SA", dateOfBirth: ISODay.date("1995-04-12"))
        model.adult = true; model.realName = true; model.singleAccount = true; model.terms = true
        await model.submit()
        XCTAssertEqual(model.mismatchSerial, 1)
        await model.submit()
        XCTAssertEqual(model.mismatchSerial, 2, "every try that failed is said, even with the same fields")
    }

    // MARK: Which side a notice is for (§14)

    private func notice(_ kind: String, role: String?) throws -> UserNotification {
        try decode(UserNotification.self, """
        {"id": "99999999-0000-4000-8000-000000000002", "kind": "\(kind)",
         "actor": {"id": "11111111-0000-4000-8000-000000000001", "handle": "noura", "display_name": "Noura", "is_verified": true},
         "vouch_id": "66666666-0000-4000-8000-000000000002",
         "vouch_role": \(role.map { "\"\($0)\"" } ?? "null"),
         "detail": "expired", "read": false, "created_at": "2026-09-26T00:00:00+00:00"}
        """)
    }

    func testVouchRoleIsReadAndAnUnknownWordIsNone() throws {
        XCTAssertEqual(try notice("vouch_ended", role: "person").vouchRole, .person)
        XCTAssertEqual(try notice("vouch_ended", role: "voucher").vouchRole, .voucher)
        XCTAssertNil(try notice("vouch_ended", role: nil).vouchRole)
        XCTAssertNil(try notice("vouch_ended", role: "bystander").vouchRole, "an unknown side is no side")
    }

    func testAnEndedVouchOpensTheSideTheServerNamesNotAGuess() async throws {
        // The person whose vouch lapsed has since verified: not vouched now.
        let person = try notice("vouch_ended", role: "person")
        XCTAssertEqual(NotificationsViewModel.vouchDestination(for: person, viewerIsVouched: false), .ownVouch,
                       "a person who verified since still opens their own vouch")
        let voucher = try notice("vouch_ended", role: "voucher")
        XCTAssertEqual(NotificationsViewModel.vouchDestination(for: voucher, viewerIsVouched: true), .vouching)

        // Without the word, the old guess.
        let unnamed = try notice("vouch_ended", role: nil)
        XCTAssertEqual(NotificationsViewModel.vouchDestination(for: unnamed, viewerIsVouched: true), .ownVouch)
        XCTAssertEqual(NotificationsViewModel.vouchDestination(for: unnamed, viewerIsVouched: false), .vouching)
        XCTAssertEqual(NotificationsViewModel.vouchDestination(for: try notice("vouch_claimed", role: nil),
                                                               viewerIsVouched: false), .vouching)

        let model = NotificationsViewModel(service: NotificationsServiceMock(scenario: .empty), feed: FeedServiceMock(),
                                           analytics: RecordingAnalyticsClient(), viewerIsVouched: { false })
        let opened = await model.open(person)
        XCTAssertEqual(opened, .ownVouch)
    }

    func testTheMockServesEveryVouchingShape() async throws {
        let mock = NotificationsServiceMock(scenario: .vouching)
        let page = try await mock.fetchNotifications(cursor: nil, limit: 20, unreadOnly: false)
        XCTAssertTrue(page.notifications.allSatisfy { $0.kind.isVouching })
        XCTAssertTrue(page.notifications.contains { $0.vouchRole == .person })
        XCTAssertTrue(page.notifications.contains { $0.vouchRole == .voucher })
        XCTAssertTrue(page.notifications.contains { $0.vouchRole == nil }, "one without the word, routed by its kind")
    }

    // MARK: The waiting wall (§2, §8)

    func testCheckingStatusWhileAClaimWaitsReadsTheAccountToo() async {
        var reads = 0
        let wall = VerificationWallViewModel(status: .unstarted, service: AuthServiceMock(scenario: .unstarted),
                                             analytics: RecordingAnalyticsClient())
        wall.refreshSession = { reads += 1 }
        await wall.refresh()
        XCTAssertEqual(reads, 0, "no claim: /verification/status is the whole answer")

        wall.pendingVouch = AuthServiceMock.mockVouch(pending: true)
        await wall.refresh()
        XCTAssertEqual(reads, 1, "a claim's answer is on the account, not in the status")
    }

    func testTheWallWatchesAClaimForAWhileAndStopsAtTheAnswer() async {
        var reads = 0
        let wall = VerificationWallViewModel(status: .unstarted, service: AuthServiceMock(scenario: .unstarted),
                                             analytics: RecordingAnalyticsClient())
        wall.pause = { _ in }
        wall.pendingVouch = AuthServiceMock.mockVouch(pending: true)
        wall.refreshSession = {
            reads += 1
            if reads == 3 { wall.pendingVouch = nil }   // the voucher answered
        }
        await wall.watchForVouchAnswer(attempts: 10)
        XCTAssertEqual(reads, 3, "stops once the claim has its answer")

        reads = 0
        wall.pendingVouch = AuthServiceMock.mockVouch(pending: true)
        wall.refreshSession = { reads += 1 }
        await wall.watchForVouchAnswer(attempts: 4)
        XCTAssertEqual(reads, 4, "and gives up after its few reads")
    }

    func testAVouchingPushIsKnownByItsKind() {
        XCTAssertTrue(PushRegistrar.isVouching(["kind": "vouch_confirmed", "vouch_id": "x"]))
        XCTAssertFalse(PushRegistrar.isVouching(["kind": "reply"]))
        XCTAssertFalse(PushRegistrar.isVouching([:]))
    }

    // MARK: Signing out

    func testSigningOutLetsAWaitingLinkGo() async {
        let container = AppContainer.preview(scenario: .unstarted)
        container.vouchInbox.receive(token: "abcdefghijklmnopqrstuvwxyz012345")
        await container.session.signOut()
        XCTAssertNil(container.vouchInbox.pending, "the next account on this phone does not inherit it")
    }
}

// MARK: - Copy and direction

@MainActor
final class VouchCopyReviewTests: XCTestCase {

    override func tearDown() {
        L10n.use(nil)
        super.tearDown()
    }

    private static let catalogue: [String: Any] = {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sila/Resources/Localizable.xcstrings")
        let json = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any]
        return json?["strings"] as? [String: Any] ?? [:]
    }()

    private func values(_ node: Any) -> [String] {
        guard let dict = node as? [String: Any] else { return [] }
        if let unit = dict["stringUnit"] as? [String: Any], let value = unit["value"] as? String { return [value] }
        return dict.values.flatMap(values)
    }

    /// Every Arabic sentence that puts "@" before a handle keeps the two one
    /// left-to-right piece — otherwise the "@" drifts to the far end
    /// ("أُزيل aziz@").
    func testEveryArabicHandleIsOneLeftToRightPiece() throws {
        XCTAssertFalse(Self.catalogue.isEmpty)
        var loose: [String] = []
        for (key, raw) in Self.catalogue {
            guard let entry = raw as? [String: Any], let locs = entry["localizations"] as? [String: Any],
                  let arabic = locs["ar"] else { continue }
            for value in values(arabic) {
                let scalars = Array(value.unicodeScalars)
                for (index, scalar) in scalars.enumerated() where scalar == "@" && index + 1 < scalars.count
                    && (scalars[index + 1] == "%" || scalars[index + 1] == "{") {
                    if index == 0 || scalars[index - 1].value != 0x2066 { loose.append(key) }
                }
            }
        }
        XCTAssertEqual(loose.sorted(), [], "these put a handle in Arabic without isolating it")
        L10n.use("ar")
        XCTAssertTrue(L10n.t("groups.member.removed", "aziz").unicodeScalars.contains { $0.value == 0x2066 })
        XCTAssertTrue(L10n.t("rooms.invites.revoked", "aziz").unicodeScalars.contains { $0.value == 0x2066 })
    }

    func testTheWelcomeNoLongerSaysEveryAccountIsVerified() {
        L10n.use("en")
        XCTAssertEqual(L10n.t("auth.wall.verified.message"),
                       "Welcome to Sila. Every account you'll see here belongs to a real person — verified, or vouched for by one.")
        L10n.use("ar")
        XCTAssertTrue(L10n.t("auth.wall.verified.message").contains("مُزكّى"))
    }

    func testTheRejectionHintSaysWhoDecided() {
        L10n.use("en")
        XCTAssertEqual(VerificationRejection.reasonHint("not_a_document"), "Why the automatic check turned the photos away")
        XCTAssertEqual(VerificationRejection.reasonHint("document_expired"), "Why the decision was made")
        XCTAssertEqual(VerificationRejection.reasonHint("The photo was too dark to read."),
                       "The reviewer's explanation for the decision")
    }

    func testTheSubmittedMessageAllowsForTheMinuteAndTheDay() {
        L10n.use("en")
        let message = L10n.t("document.submitted.message")
        XCTAssertTrue(message.contains("within a day"))
        XCTAssertTrue(message.contains("within minutes"), "the pre-screen can answer within a minute")
    }

    func testTheNotePlaceholderNamesNobody() {
        for language in ["en", "ar"] {
            L10n.use(language)
            let placeholder = L10n.t("vouch.new.note.placeholder")
            XCTAssertFalse(placeholder.contains("Khalid") || placeholder.contains("خالد"), placeholder)
        }
    }

    /// A Saudi phone's calendar is Umm al-Qura; the app's dates are Gregorian
    /// everywhere, beside a date of birth that always is.
    func testDatesAreGregorianInArabicToo() {
        let date = ISODay.date("2026-09-03")!.addingTimeInterval(12 * 3_600)
        let saudi = L10n.westernDigits(Locale(identifier: "ar_SA"))
        let since = SLFormat.dayAndMonth(date, locale: saudi)
        XCTAssertTrue(since.contains("سبتمبر"), since)
        XCTAssertTrue(SLFormat.date(date, locale: saudi).contains("2026"), SLFormat.date(date, locale: saudi))
        XCTAssertFalse(SLFormat.dateTime(date, locale: saudi).contains("هـ"))
        // Even a bare Saudi locale, whose own calendar is Umm al-Qura.
        XCTAssertTrue(SLFormat.monthAndYear(date, locale: Locale(identifier: "ar_SA")).contains("سبتمبر"))
    }
}

// MARK: - Why the last vouch ended (contract v24 §15)

@MainActor
final class LastEndedVouchTests: XCTestCase {

    override func tearDown() {
        L10n.use(nil)
        super.tearDown()
    }

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONCoding.decoder.decode(T.self, from: Data(json.utf8))
    }

    private static let voucher = """
    {"id": "44444444-0000-4000-8000-000000000001", "handle": "aziz", "display_name": "Aziz", "is_verified": true}
    """

    private func ended(_ reason: String?, handle: String? = "aziz", vouchAgain: String? = nil) -> LastEndedVouch {
        LastEndedVouch(id: UUID(), endReason: reason, endedAt: Date(), voucher: nil,
                       voucherHandle: handle, vouchAgain: vouchAgain)
    }

    // MARK: The wire

    func testMyVouchReadsLastEnded() throws {
        let mine = try decode(MyVouch.self, """
        {"standing": "none", "vouch": null, "rights": null, "limits": null,
         "last_ended": {"id": "66666666-0000-4000-8000-000000000009", "end_reason": "declined",
                        "ended_at": "2026-09-24T10:00:00+00:00", "voucher": \(Self.voucher),
                        "voucher_handle": "aziz_old", "vouch_again": null}}
        """)
        let ended = try XCTUnwrap(mine.lastEnded)
        XCTAssertEqual(ended.endReason, "declined")
        XCTAssertNotNil(ended.endedAt)
        XCTAssertEqual(ended.handle, "aziz", "the live account's handle, when there is one")
        XCTAssertNil(ended.vouchAgain)
        XCTAssertNil(mine.vouch)
    }

    func testAGoneVoucherIsNamedByTheHandleKeptOnTheVouch() throws {
        let mine = try decode(MyVouch.self, """
        {"standing": "none", "vouch": null,
         "last_ended": {"id": "66666666-0000-4000-8000-000000000009", "end_reason": "voucher_left",
                        "ended_at": null, "voucher": null, "voucher_handle": "aziz",
                        "vouch_again": "vouch_too_soon"}}
        """)
        XCTAssertEqual(mine.lastEnded?.handle, "aziz")
        XCTAssertEqual(mine.lastEnded?.vouchAgain, "vouch_too_soon")
    }

    func testAnOlderServerOrABrokenFieldIsNoLastEnded() throws {
        XCTAssertNil(try decode(MyVouch.self, #"{"standing": "none", "vouch": null}"#).lastEnded)
        XCTAssertNil(try decode(MyVouch.self, #"{"standing": "none", "last_ended": null}"#).lastEnded)
        XCTAssertNil(try decode(MyVouch.self, #"{"standing": "none", "last_ended": {"end_reason": "declined"}}"#).lastEnded,
                     "no id: nothing to say")
        XCTAssertEqual(try decode(MyVouch.self, #"{"standing": "none", "last_ended": {"id": "x"}}"#).standing, .noStanding)
    }

    // MARK: The words (the web's, in each language)

    func testEachEndingSaysWhyInEnglish() {
        L10n.use("en")
        XCTAssertEqual(VouchCopy.lastEnded(ended("declined")),
                       VouchCopy.LastEndedCopy(title: "The vouch from @aziz has ended",
                                               reason: "@aziz didn't confirm it was you.",
                                               next: "Someone else you know can vouch for you, or verify your identity."))
        XCTAssertEqual(VouchCopy.lastEnded(ended("unconfirmed")).reason, "@aziz didn't confirm in time.")
        XCTAssertEqual(VouchCopy.lastEnded(ended("expired")).reason, "The 30 days ended.")
        XCTAssertEqual(VouchCopy.lastEnded(ended("withdrawn")).reason, "@aziz withdrew their vouch.")
        XCTAssertEqual(VouchCopy.lastEnded(ended("removed")).reason, "You took the vouch off.")
        for code in ["voucher_left", "voucher_penalised", "voucher_unverified", "voucher_suspended"] {
            XCTAssertEqual(VouchCopy.lastEnded(ended(code)).reason, "@aziz can no longer vouch for anyone.", code)
        }
        for code in ["impostor", "under_age", "false_attestation", "sold_link"] {
            XCTAssertEqual(VouchCopy.lastEnded(ended(code, vouchAgain: "vouch_not_eligible")).reason,
                           "A moderator ended this vouch.", "a finding is said as that and no more: \(code)")
        }
        XCTAssertEqual(VouchCopy.lastEnded(ended("something_newer")).reason, "This vouch has ended.")
        XCTAssertEqual(VouchCopy.lastEnded(ended(nil)).reason, "This vouch has ended.")
    }

    func testWhatIsLeftFollowsVouchAgain() {
        L10n.use("en")
        XCTAssertEqual(VouchCopy.lastEnded(ended("expired")).next,
                       "Someone else you know can vouch for you, or verify your identity.")
        for refusal in ["vouch_too_soon", "vouch_lifetime_reached", "vouch_not_eligible", "anything_newer"] {
            XCTAssertEqual(VouchCopy.lastEnded(ended("expired", vouchAgain: refusal)).next,
                           "Verify your identity to continue.", refusal)
        }
    }

    func testWithoutAHandleNothingNamesAVoucher() {
        L10n.use("en")
        let unnamed = VouchCopy.lastEnded(ended("declined", handle: nil))
        XCTAssertEqual(unnamed.title, "Your vouch has ended")
        XCTAssertEqual(unnamed.reason, "This vouch has ended.", "a sentence that names the voucher needs the handle")
        XCTAssertEqual(VouchCopy.lastEnded(ended("expired", handle: "")).title, "Your vouch has ended")
    }

    func testArabicIsArabicOnlyAndTheHandleIsOnePiece() {
        L10n.use("ar")
        let copy = VouchCopy.lastEnded(ended("declined"))
        // The catalogue wraps "@%@" in LRI … PDI; Foundation adds its own
        // FSI … PDI around the argument inside it. Compared without them,
        // and the "@" checked to sit inside the left-to-right isolate.
        let isolates: Set<UInt32> = [0x2066, 0x2068, 0x2069]
        func plain(_ text: String) -> String {
            String(String.UnicodeScalarView(text.unicodeScalars.filter { !isolates.contains($0.value) }))
        }
        XCTAssertEqual(plain(copy.title), "انتهت تزكية @aziz لك")
        XCTAssertEqual(plain(copy.reason), "لم يؤكّد @aziz أنك أنت.")
        for line in [copy.title, copy.reason] {
            XCTAssertTrue(line.contains("\u{2066}@"), "the \"@\" drifts away from the handle: \(line)")
        }
        XCTAssertEqual(copy.next, "يمكن أن يزكّيك شخص آخر تعرفه، أو أن توثّق هويتك.")
        XCTAssertEqual(VouchCopy.lastEnded(ended("expired", vouchAgain: "vouch_too_soon")).next, "وثّق هويتك للمتابعة.")
        XCTAssertEqual(VouchCopy.lastEnded(ended("impostor")).reason, "أنهى أحد المشرفين هذه التزكية.")
        XCTAssertEqual(VouchCopy.lastEnded(ended("expired", handle: nil)).title, "انتهت تزكيتك")
        for line in [copy.title, copy.reason, copy.next] {
            let latin = plain(line).replacingOccurrences(of: "@aziz", with: "").unicodeScalars
                .filter { CharacterSet.letters.contains($0) && $0.value < 0x0250 }
            XCTAssertTrue(latin.isEmpty, "English beside the Arabic: \(line)")
        }
    }

    // MARK: The wall

    private func wall(_ status: VerificationStatus = .unstarted) -> VerificationWallViewModel {
        VerificationWallViewModel(status: status, service: AuthServiceMock(scenario: .unstarted),
                                  analytics: RecordingAnalyticsClient())
    }

    func testTheWallReadsWhyTheLastVouchEndedWhenNothingWaits() async {
        let model = wall()
        var reads = 0
        model.loadMyVouch = {
            reads += 1
            return MyVouch(standing: .noStanding, lastEnded: AuthServiceMock.mockLastEnded())
        }
        await model.refreshLastEnded()
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(model.lastEnded?.endReason, "declined")
        XCTAssertTrue(model.showsLastEnded)
    }

    func testAClaimStillWaitingIsNotAnEnding() async {
        let model = wall()
        var reads = 0
        model.loadMyVouch = { reads += 1; return MyVouch(standing: .noStanding, lastEnded: AuthServiceMock.mockLastEnded()) }
        model.pendingVouch = AuthServiceMock.mockVouch(pending: true)
        await model.refreshLastEnded()
        XCTAssertEqual(reads, 0, "a claim waits: nothing ended")
        XCTAssertNil(model.lastEnded)
        XCTAssertFalse(model.showsLastEnded)
    }

    func testOnceTheClaimGoesTheWallAsksAgain() async {
        let model = wall()
        model.pendingVouch = AuthServiceMock.mockVouch(pending: true)
        model.loadMyVouch = { MyVouch(standing: .noStanding, lastEnded: AuthServiceMock.mockLastEnded(reason: "unconfirmed")) }
        await model.refreshLastEnded()
        XCTAssertNil(model.lastEnded)
        model.pendingVouch = nil        // the 48 hours ran out
        await model.refreshLastEnded()
        XCTAssertEqual(model.lastEnded?.endReason, "unconfirmed")
    }

    func testTheCardIsOnlyForTheStartOfTheWall() async {
        for (status, shows) in [(VerificationStatus.unstarted, true), (.inProgress, true),
                                (.pendingReview, false), (.rejected, false)] {
            let model = wall(status)
            model.loadMyVouch = { MyVouch(standing: .noStanding, lastEnded: AuthServiceMock.mockLastEnded()) }
            await model.refreshLastEnded()
            XCTAssertEqual(model.showsLastEnded, shows, "\(status)")
        }
    }

    func testAFailedReadLeavesTheWallAsItWas() async {
        let model = wall()
        model.loadMyVouch = { MyVouch(standing: .noStanding, lastEnded: AuthServiceMock.mockLastEnded()) }
        await model.refreshLastEnded()
        model.loadMyVouch = { throw APIError.transport("offline") }
        await model.refreshLastEnded()
        XCTAssertNotNil(model.lastEnded, "no toast, no change: the wall stands without it")
        XCTAssertNil(model.toast)
    }

    func testALiveVouchOrAVerifiedAccountHasNoEndingToShow() async {
        let model = wall()
        model.loadMyVouch = {
            MyVouch(standing: .vouched, vouch: AuthServiceMock.mockVouch(pending: false),
                    lastEnded: AuthServiceMock.mockLastEnded())
        }
        await model.refreshLastEnded()
        XCTAssertNil(model.lastEnded)
        model.loadMyVouch = { MyVouch(standing: .verified, lastEnded: AuthServiceMock.mockLastEnded()) }
        await model.refreshLastEnded()
        XCTAssertNil(model.lastEnded)
    }

    // MARK: The mock plays the server

    func testWithdrawingAClaimLeavesARecordOfIt() async throws {
        let mock = VouchingServiceMock()
        await mock.setOwnVouch(AuthServiceMock.mockVouch(pending: true), standing: .noStanding)
        try await mock.removeMyVouch()
        let mine = try await mock.myVouch()
        XCTAssertNil(mine.vouch)
        XCTAssertEqual(mine.lastEnded?.endReason, "removed")
        XCTAssertEqual(mine.lastEnded?.handle, "noura")
        XCTAssertNil(mine.lastEnded?.vouchAgain, "an unconfirmed claim starts no wait")

        let vouched = VouchingServiceMock()
        await vouched.setOwnVouch(AuthServiceMock.mockVouch(pending: false), standing: .vouched)
        try await vouched.removeMyVouch()
        let after = try await vouched.myVouch()
        XCTAssertEqual(after.lastEnded?.vouchAgain, "vouch_too_soon", "a confirmed vouch starts the fortnight")
    }

    func testTheOwnVouchScreenReadsIt() async {
        let mock = VouchingServiceMock()
        await mock.setLastEnded(AuthServiceMock.mockLastEnded(reason: "expired"))
        let model = OwnVouchViewModel(service: mock, onChanged: {})
        await model.load()
        XCTAssertNil(model.vouch)
        XCTAssertEqual(model.mine?.lastEnded?.endReason, "expired")
    }
}

private extension VouchClaimViewModel.Phase {
    var isOpen: Bool {
        if case .open = self { return true }
        return false
    }
}
