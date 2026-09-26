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

private extension VouchClaimViewModel.Phase {
    var isOpen: Bool {
        if case .open = self { return true }
        return false
    }
}
