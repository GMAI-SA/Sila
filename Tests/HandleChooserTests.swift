import XCTest
@testable import Sila

/// Choosing a handle (contract v33; owner, 2026-09-30: "Why does a user get
/// created with @userajc5u5i7?"). The account says whether its handle was
/// chosen; the chooser offers the server's suggestions, says at once what the
/// phone can tell, asks the server about the rest once typing stops, takes
/// the handle, and never blocks — "Keep @user… for now" always goes on.
@MainActor
final class HandleChooserTests: XCTestCase {

    override func tearDown() {
        L10n.use(nil)
        super.tearDown()
    }

    private let given = AuthServiceMock.generatedHandle

    private func account(handle: String = AuthServiceMock.generatedHandle, chosen: Bool = false) -> AuthUser {
        var user = AuthUser(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            email: "new@example.com", emailVerified: true, verificationStatus: .unstarted,
            createdAt: Date(), handle: handle
        )
        user.handleChosen = chosen
        return user
    }

    private func make(
        context: HandleChooserViewModel.Context = .signUp,
        current: String? = AuthServiceMock.generatedHandle,
        service: HandleServiceMock? = nil,
        debounce: Duration = .milliseconds(10),
        onChosen: @escaping @MainActor (AuthUser) async -> Void = { _ in },
        onDismiss: @escaping @MainActor () -> Void = {}
    ) -> (HandleChooserViewModel, HandleServiceMock) {
        let owner = account(handle: current ?? "")
        let mock = service ?? HandleServiceMock(account: { owner })
        let viewModel = HandleChooserViewModel(
            service: mock, analytics: RecordingAnalyticsClient(), currentHandle: current,
            context: context, debounce: debounce, onChosen: onChosen, onDismiss: onDismiss
        )
        return (viewModel, mock)
    }

    private func settle(_ viewModel: HandleChooserViewModel) async {
        for _ in 0..<200 where viewModel.status == .checking {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    // MARK: - The account

    func testTheAccountSaysWhetherItsHandleWasChosen() throws {
        func user(_ extra: String) throws -> AuthUser {
            try JSONCoding.decoder.decode(AuthUser.self, from: Data("""
            {"id": "\(AuthFixtures.userID)", "email": "a@example.com", "email_verified": true,
             "verification_status": "unstarted", "created_at": "2026-01-01T00:00:00Z",
             "handle": "user7k2m9q4x"\(extra)}
            """.utf8))
        }
        XCTAssertFalse(try user(#", "handle_chosen": false"#).handleChosen)
        XCTAssertTrue(try user(#", "handle_chosen": true"#).handleChosen)
        XCTAssertTrue(try user("").handleChosen, "an older server or cached session never asks")

        // The keychain's copy keeps the answer across a launch.
        let cached = try JSONCoding.decoder.decode(
            AuthUser.self, from: try JSONCoding.encoder.encode(try user(#", "handle_chosen": false"#))
        )
        XCTAssertFalse(cached.handleChosen)
        XCTAssertFalse(cached.settingNeedsInterestPrompt(true).handleChosen, "copies keep it")
    }

    func testTheCheckDecodesTheContractsShape() throws {
        func check(_ json: String) throws -> HandleCheck {
            try JSONCoding.decoder.decode(HandleCheck.self, from: Data(json.utf8))
        }
        let taken = try check(#"{"handle": "aziz", "available": false, "reason": "taken", "suggestions": ["aziz_1", "x", "aziz482"]}"#)
        XCTAssertEqual(taken.reason, .taken)
        XCTAssertEqual(taken.suggestions, ["aziz_1", "aziz482"], "nothing the server could not hold is offered")
        XCTAssertEqual(try check(#"{"handle": "moh", "available": false, "reason": "reserved", "suggestions": []}"#).reason, .reserved)
        XCTAssertEqual(try check(#"{"handle": "a", "available": false, "reason": "invalid"}"#).reason, .invalid)
        XCTAssertNil(try check(#"{"handle": "aziz_w", "available": true, "reason": null, "suggestions": []}"#).reason)
        XCTAssertEqual(try check(#"{"handle": "x", "available": false, "reason": "something_new"}"#).reason, .taken,
                       "a reason this build does not know still means it cannot be had")
    }

    // MARK: - The wire

    func testItAsksAndTakesAtTheContractsRoutes() async throws {
        let network = ScriptedNetwork { request in
            switch request.path {
            case "/handles/check":
                return #"{"handle": "aziz", "available": false, "reason": "taken", "suggestions": ["aziz_w"]}"#
            default:
                return """
                {"id": "\(AuthFixtures.userID)", "email": "a@example.com", "email_verified": true,
                 "verification_status": "unstarted", "created_at": "2026-01-01T00:00:00Z",
                 "handle": "aziz_w", "handle_chosen": true}
                """
            }
        }
        let service = HandleService(network: network, tokens: StaticAccessTokenProvider(), analytics: RecordingAnalyticsClient())

        let answer = try await service.check(" @Aziz ")
        XCTAssertEqual(answer.reason, .taken)
        let asked = try XCTUnwrap(network.requests.first)
        XCTAssertEqual(asked.method, .get)
        XCTAssertEqual(asked.query, [URLQueryItem(name: "handle", value: "aziz")], "as it would be stored; no name, no email")
        XCTAssertNotNil(asked.accessToken)

        let chosen = try await service.choose("@Aziz_W")
        XCTAssertEqual(chosen.handle, "aziz_w")
        XCTAssertTrue(chosen.handleChosen)
        let taken = try XCTUnwrap(network.requests.last)
        XCTAssertEqual(taken.path, "/me/handle")
        XCTAssertEqual(taken.method, .post)
        XCTAssertEqual(String(decoding: try XCTUnwrap(taken.body), as: UTF8.self), #"{"handle":"aziz_w"}"#)
    }

    func testAReservedHandleIsTypedAndSaidInBothLanguages() {
        let body = Data(#"{"detail": {"code": "handle_reserved", "message": "That handle is reserved"}}"#.utf8)
        let error = URLSessionNetworkClient.makeError(status: 409, data: body)
        XCTAssertEqual(error.code, .handleReserved)
        XCTAssertEqual(error.userMessage, "That handle is reserved.")
        XCTAssertTrue(L10n.use("ar"))
        XCTAssertEqual(error.userMessage, "هذا المعرّف محجوز.")
    }

    // MARK: - The chooser

    /// A good handle is one tap away: the first suggestion is in the field,
    /// the rest are chips, and "Keep @user… for now" is there.
    func testASuggestionIsPrefilled() async {
        let (viewModel, mock) = make()
        await viewModel.load()
        XCTAssertEqual(viewModel.text, HandleServiceMock.suggestions.first)
        XCTAssertEqual(viewModel.status, .available)
        XCTAssertEqual(viewModel.suggestions, HandleServiceMock.suggestions)
        XCTAssertTrue(viewModel.canSave)
        XCTAssertTrue(viewModel.offersKeep)
        let checked = await mock.checked
        XCTAssertEqual(checked, [""], "suggestions alone: nothing typed was sent")
    }

    /// What the phone knows is said at once, without a request; taken and
    /// reserved are the server's to say.
    func testTheRulesThePhoneKnowsAreSaidAtOnce() async {
        let (viewModel, mock) = make()
        await viewModel.load()

        viewModel.update("ab")
        XCTAssertEqual(viewModel.status, .unavailable(.invalid))
        XCTAssertEqual(viewModel.statusLine, "3–20 letters (a–z), numbers or underscores.")
        viewModel.update("aziz wakeel")
        XCTAssertEqual(viewModel.status, .unavailable(.invalid), "a space is not part of a handle")
        viewModel.update("عزيز")
        XCTAssertEqual(viewModel.status, .unavailable(.invalid))
        XCTAssertFalse(viewModel.canSave)
        var checked = await mock.checked
        XCTAssertEqual(checked, [""], "none of those needed the server")

        viewModel.update("@Noura")
        XCTAssertEqual(viewModel.text, "noura", "what the field shows is what would be stored")
        XCTAssertEqual(viewModel.status, .checking)
        await settle(viewModel)
        XCTAssertEqual(viewModel.status, .unavailable(.taken))
        XCTAssertEqual(viewModel.statusLine, "That handle is taken.")

        viewModel.update("admin")
        await settle(viewModel)
        XCTAssertEqual(viewModel.statusLine, "That handle is reserved.")

        viewModel.update("aziz_w")
        await settle(viewModel)
        XCTAssertEqual(viewModel.status, .available)
        XCTAssertTrue(viewModel.canSave)
        checked = await mock.checked
        XCTAssertEqual(checked, ["", "noura", "admin", "aziz_w"])
    }

    func testTheReasonsReadInArabic() async {
        XCTAssertTrue(L10n.use("ar"))
        let (viewModel, _) = make()
        viewModel.update("ab")
        XCTAssertEqual(viewModel.statusLine, "من 3 إلى 20 حرفًا لاتينيًا (a–z) أو أرقامًا أو شرطة سفلية.")
        viewModel.update("taken")
        await settle(viewModel)
        XCTAssertEqual(viewModel.statusLine, "هذا المعرّف مستخدم.")
        viewModel.update("moh")
        await settle(viewModel)
        XCTAssertEqual(viewModel.statusLine, "هذا المعرّف محجوز.")
        viewModel.update("aziz_w")
        await settle(viewModel)
        XCTAssertEqual(viewModel.statusLine, "متاح")
    }

    /// Typing is not a request per key: the server is asked once the typing
    /// stops, about what the field says then.
    func testTypingQuicklyAsksOnce() async {
        let (viewModel, mock) = make(debounce: .milliseconds(150))
        viewModel.update("azi")
        viewModel.update("aziz")
        viewModel.update("aziz_w")
        try? await Task.sleep(nanoseconds: 400_000_000)
        await settle(viewModel)
        let checked = await mock.checked
        XCTAssertEqual(checked, ["aziz_w"])
        XCTAssertEqual(viewModel.status, .available)
    }

    func testTheirOwnHandleIsNeitherAskedNorRefused() async {
        let (viewModel, mock) = make()
        viewModel.update("@" + given.uppercased())
        XCTAssertEqual(viewModel.status, .current)
        XCTAssertTrue(viewModel.canSave, "keeping it is a choice too")
        let checked = await mock.checked
        XCTAssertTrue(checked.isEmpty)
    }

    func testSavingTakesTheHandleAndHandsTheAccountOn() async {
        var handed: AuthUser?
        let (viewModel, mock) = make(onChosen: { handed = $0 })
        viewModel.update("aziz_w")
        await settle(viewModel)
        await viewModel.save()
        let chosen = await mock.chosen
        XCTAssertEqual(chosen, ["aziz_w"])
        XCTAssertEqual(handed?.handle, "aziz_w")
        XCTAssertEqual(handed?.handleChosen, true)
    }

    /// Somebody took it a moment earlier: said on the handle's line, with
    /// fresh suggestions — nothing handed on.
    func testAHandleTakenAMomentEarlierIsSaidWithFreshSuggestions() async {
        var handed = false
        let (viewModel, mock) = make(onChosen: { _ in handed = true })
        await viewModel.load()
        viewModel.update("aziz_w")
        await settle(viewModel)
        await mock.failNextChoose(with: .api(code: .handleTaken, message: "That handle is already taken", status: 409))
        await viewModel.save()
        XCTAssertFalse(handed)
        XCTAssertEqual(viewModel.status, .unavailable(.taken))
        XCTAssertNil(viewModel.saveError, "about the handle, so said on its line")
        for _ in 0..<100 {
            if await mock.checked.last == "aziz_w", await mock.checked.count >= 3 { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        let checked = await mock.checked
        XCTAssertEqual(checked.last, "aziz_w", "asked again for fresh suggestions")
    }

    func testTooManyChangesIsSaidUnderTheButton() async {
        let (viewModel, mock) = make()
        viewModel.update("aziz_w")
        await settle(viewModel)
        await mock.failNextChoose(with: .api(code: .rateLimited, message: "Too many", status: 429))
        await viewModel.save()
        XCTAssertEqual(viewModel.saveError, L10n.t("error.rateLimited"))
        XCTAssertEqual(viewModel.status, .available)
    }

    /// "Keep @user… for now" takes the handle they were given, so the step
    /// is not offered again.
    func testKeepTakesTheGivenHandle() async {
        var handed: AuthUser?
        let (viewModel, mock) = make(onChosen: { handed = $0 })
        await viewModel.load()
        await viewModel.keep()
        let chosen = await mock.chosen
        XCTAssertEqual(chosen, [given])
        XCTAssertEqual(handed?.handle, given)
        XCTAssertEqual(handed?.handleChosen, true)
    }

    /// Never a dead end: Keep goes on even when the server cannot be reached.
    func testKeepGoesOnEvenOffline() async {
        var dismissed = false
        let owner = account()
        let (viewModel, _) = make(service: HandleServiceMock(offline: true, account: { owner }), onDismiss: { dismissed = true })
        await viewModel.load()
        XCTAssertTrue(viewModel.suggestions.isEmpty)
        await viewModel.keep()
        XCTAssertTrue(dismissed)
    }

    func testSettingsStartsOnTheCurrentHandleAndOffersNoKeep() async {
        let (viewModel, _) = make(context: .settings, current: "aziz_sa")
        await viewModel.load()
        XCTAssertEqual(viewModel.text, "aziz_sa")
        XCTAssertEqual(viewModel.status, .current)
        XCTAssertFalse(viewModel.canSave, "saving the same handle would change nothing")
        XCTAssertFalse(viewModel.offersKeep)
        XCTAssertFalse(viewModel.suggestions.isEmpty)
    }

    // MARK: - Settings and the session

    /// Changed in settings: the screen shows it at once, other unsaved edits
    /// stay, and the session is told.
    func testSettingsShowTheNewHandleAndTellTheSession() async throws {
        var told: AuthUser?
        let owner = account(handle: "aziz_sa", chosen: true)
        let viewModel = AccountViewModel(
            service: AccountServiceMock(), analytics: RecordingAnalyticsClient(),
            handles: HandleServiceMock(account: { owner }), onHandleChosen: { told = $0 }
        )
        await viewModel.load()
        viewModel.profileDraft.bio = "Edited, not saved"
        let chooser = try XCTUnwrap(viewModel.makeHandleChooser())
        XCTAssertEqual(chooser.context, .settings)
        XCTAssertEqual(chooser.currentHandle, "aziz_sa")
        viewModel.presentedSheet = .handle

        chooser.update("aziz_w")
        await settle(chooser)
        await chooser.save()

        XCTAssertEqual(viewModel.account?.handle, "aziz_w")
        XCTAssertEqual(viewModel.profileDraft.handle, "aziz_w")
        XCTAssertEqual(viewModel.profileDraft.bio, "Edited, not saved")
        XCTAssertNil(viewModel.presentedSheet)
        XCTAssertEqual(told?.handle, "aziz_w")
        XCTAssertNotNil(viewModel.toast)
    }

    func testWithoutAHandleServiceSettingsKeepTheProfileField() {
        let viewModel = AccountViewModel(service: AccountServiceMock(), analytics: RecordingAnalyticsClient())
        XCTAssertNil(viewModel.handles)
        XCTAssertNil(viewModel.makeHandleChooser())
    }

    /// A registration's code gives the random handle, not yet chosen; a
    /// sign-in gives a chosen one. Once chosen, `/auth/me` agrees.
    func testTheMockedServerGivesANewAccountItsRandomHandleUntilOneIsChosen() async throws {
        let auth = AuthServiceMock(scenario: .unstarted, handleUnchosen: false)
        let signedUp = try await auth.verifyOTP(email: "new@example.com", code: auth.acceptedCode, purpose: .register, password: "Passw0rd!234")
        XCTAssertEqual(signedUp.user.handle, given)
        XCTAssertFalse(signedUp.user.handleChosen)

        let session = AuthSession(service: auth, store: AuthTokenStore(keychain: InMemoryKeychainClient(), storage: InMemoryStorageClient()),
                                  analytics: RecordingAnalyticsClient())
        await session.adopt(signedUp)
        XCTAssertEqual(session.route, .verificationWall(.unstarted))

        let handles = HandleServiceMock(account: { await session.user }, onChosen: { await auth.adoptChosenHandle($0) })
        let fresh = try await handles.choose("aziz_w")
        await session.adoptAccount(fresh)
        XCTAssertEqual(session.user?.handle, "aziz_w")
        XCTAssertEqual(session.user?.handleChosen, true)
        XCTAssertEqual(session.route, .verificationWall(.unstarted), "choosing a handle changes nothing else")

        await session.refreshUser()
        XCTAssertEqual(session.user?.handle, "aziz_w", "the next /auth/me agrees")
        XCTAssertEqual(session.user?.handleChosen, true)

        await session.refreshVerification()
        XCTAssertEqual(session.user?.handleChosen, true, "a status refresh keeps it")

        let signedIn = try await AuthServiceMock(scenario: .verified).signIn(email: "aziz@example.com", password: "x")
        XCTAssertTrue(signedIn.user.handleChosen)
    }
}
