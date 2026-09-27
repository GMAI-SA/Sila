import XCTest
@testable import Sila

/// Contract v24 (§11 included) against the deployed backend, through the
/// app's own services and decoders: a link minted with who the person is, a
/// claim that names the field that did not match, a confirmation, the tag
/// and the limited tier, the tag taken off, and a link closed by three
/// mismatches.
///
/// **Disposable accounts only.** Every account here is registered by the
/// test itself as `itest-ios-…@example.com` through the dev routes the
/// backend's integration suite uses, and that suite's purge removes them.
/// Vouching is closed in production except for exactly these accounts in dev
/// mode. The test never reads or changes anybody else's account or vouch,
/// and it leaves nothing live: the vouch it confirms is taken off again, and
/// the other link ends closed.
///
/// The dev routes answer only on the host's loopback, so they are reached
/// through a tunnel; everything the app itself calls goes to the public API.
///
/// ```
/// ssh -N -L 18100:127.0.0.1:8100 ubuntu@<host> &
/// TEST_RUNNER_SILA_LIVE_API=1 TEST_RUNNER_SILA_DEV_API=http://127.0.0.1:18100/api/v1 \
///   xcodebuild … test -only-testing:SilaTests/LiveVouchingTests
/// ```
final class LiveVouchingTests: XCTestCase {

    private let password = "Passw0rd!234"
    private var devBase: URL!

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["SILA_LIVE_API"] == "1", let dev = env["SILA_DEV_API"].flatMap(URL.init(string:)) else {
            throw XCTSkip("Live dev-route tests are opt-in — set SILA_LIVE_API=1 and SILA_DEV_API")
        }
        devBase = dev
    }

    // MARK: - Disposable accounts

    private struct Disposable {
        let email: String
        let handle: String
        let token: String
        let auth: AuthService
        let vouching: VouchingService
        let notifications: NotificationsService
    }

    private func dev(_ path: String, query: [URLQueryItem] = [], body: [String: Any]? = nil) async throws -> [String: Any] {
        var components = URLComponents(url: devBase.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        XCTAssertEqual(status, 200, "\(path): \(String(decoding: data, as: UTF8.self))")
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// Registers and confirms the address with the code the dev route shows.
    /// A voucher is then made verified forty days ago — the pipeline's stand-in
    /// the backend suite uses — because a voucher must have been verified for
    /// thirty.
    private func disposable(voucher: Bool) async throws -> Disposable {
        let tag = UUID().uuidString.prefix(10).lowercased()
        let email = "itest-ios-\(voucher ? "v" : "p")\(tag)@example.com"
        let auth = AuthService(
            network: URLSessionNetworkClient(),
            store: AuthTokenStore(keychain: InMemoryKeychainClient(), storage: InMemoryStorageClient()),
            biometrics: StubBiometricAuthenticator(),
            analytics: RecordingAnalyticsClient()
        )
        _ = try await auth.register(email: email, password: password)
        let peek = try await dev("dev/otp/peek", query: [URLQueryItem(name: "email", value: email)])
        let code = try XCTUnwrap(peek["code"] as? String, "no code recorded for \(email)")
        let pair = try await auth.verifyOTP(email: email, code: code, purpose: .register)
        var handle = try await auth.currentUser().handle ?? pair.user.handle ?? ""
        if voucher {
            let set = try await dev("dev/user/set", body: [
                "email": email, "verification_status": "verified", "country_code": "SA", "verified_days_ago": 40,
            ])
            handle = (set["handle"] as? String) ?? handle
        }
        let tokens = StaticAccessTokenProvider(token: pair.token.accessToken)
        return Disposable(
            email: email,
            handle: handle,
            token: pair.token.accessToken,
            auth: auth,
            vouching: VouchingService(network: URLSessionNetworkClient(), tokens: tokens, analytics: RecordingAnalyticsClient()),
            notifications: NotificationsService(network: URLSessionNetworkClient(), tokens: tokens, analytics: RecordingAnalyticsClient())
        )
    }

    /// The token at the end of a minted link, read by the app's own parser —
    /// the one a tap on the link goes through.
    private func token(of minted: MintedInvite) throws -> String {
        guard case let .vouchInvite(token) = try XCTUnwrap(DeepLink.parse(minted.url), "the app cannot read \(minted.url)") else {
            XCTFail("\(minted.url) is not a vouch link to the app")
            return ""
        }
        return token
    }

    private func rows(_ person: Disposable) async throws -> [UserNotification] {
        try await person.notifications.fetchNotifications(cursor: nil, limit: 50, unreadOnly: false).notifications
    }

    // MARK: - The whole of one vouch

    func testALinkIsMintedClaimedAfterAMismatchConfirmedAndTakenOff() async throws {
        let voucher = try await disposable(voucher: true)
        let person = try await disposable(voucher: false)
        let name = "Itest Person \(UUID().uuidString.prefix(4))"
        let written = VouchDetails(fullName: name, nationality: "SA", dateOfBirth: "1995-04-12")

        // The voucher may vouch: verified forty days, one slot, the flag open
        // for this dev-mode account.
        let before = try await voucher.vouching.overview()
        XCTAssertTrue(before.canVouch, "the disposable voucher cannot vouch: \(String(describing: before.reason))")
        XCTAssertEqual(before.slots.total, 1, "one slot until a first person verifies")

        let minted = try await voucher.vouching.mintInvite(label: "live test", details: written)
        XCTAssertEqual(minted.invite.state, .open)
        XCTAssertEqual(minted.invite.details?.fullName, name, "the voucher's own list carries what they wrote")
        let link = try token(of: minted)

        // The landing is public and names the voucher, and nothing they wrote.
        let landing = try await VouchingService(
            network: URLSessionNetworkClient(), tokens: StaticAccessTokenProvider(token: nil), analytics: RecordingAnalyticsClient()
        ).landing(token: link)
        XCTAssertEqual(landing.voucher.handle, voucher.handle)
        XCTAssertTrue(landing.voucher.isVerified)
        XCTAssertNotNil(landing.expiresAt)

        // One letter off: the name is named, the value never is.
        do {
            _ = try await person.vouching.claim(
                token: link, details: VouchDetails(fullName: name + "x", nationality: "SA", dateOfBirth: "1995-04-12"))
            XCTFail("a wrong name was accepted")
        } catch let APIError.detailsMismatch(fields, left, message) {
            XCTAssertEqual(fields, ["full_name"])
            XCTAssertEqual(left, 2)
            XCTAssertFalse(message.contains(name), "the server's sentence repeats what the voucher wrote")
        }

        // Spacing and case are the server's to fold: the right name matches.
        let claimed = try await person.vouching.claim(
            token: link, details: VouchDetails(fullName: "  " + name.uppercased(), nationality: "sa", dateOfBirth: "1995-04-12"))
        XCTAssertEqual(claimed?.status, .pending)
        XCTAssertEqual(claimed?.voucherHandle, voucher.handle)
        let waiting = try await person.auth.currentUser()
        XCTAssertEqual(waiting.standing, .noStanding, "a pending claim is still the wall")
        XCTAssertEqual(waiting.vouch?.isPending, true, "and /auth/me says what it is waiting for")

        // The voucher is told, and confirms who it was.
        let told = try await rows(voucher)
        XCTAssertTrue(told.contains { $0.kind == .vouchClaimed && $0.vouchId == claimed?.id },
                      "no vouch_claimed row the app can read: \(told.map(\.kind))")
        let list = try await voucher.vouching.overview()
        let pending = try XCTUnwrap(list.pending.first { $0.id == claimed?.id }, "the claim is not in the voucher's list")
        XCTAssertEqual(pending.details?.fullName, name)
        XCTAssertNotNil(pending.confirmBy)
        let confirmed = try await voucher.vouching.confirm(vouchId: pending.id)
        XCTAssertEqual(confirmed.status, .active)

        // The person is a member now: the tag, the 30 days, the limited tier.
        let vouched = try await person.auth.currentUser()
        XCTAssertEqual(vouched.standing, .vouched)
        XCTAssertEqual(vouched.vouch?.status, .active)
        let days = try XCTUnwrap(vouched.vouch?.expiresAt).timeIntervalSinceNow / 86_400
        XCTAssertEqual(days, 30, accuracy: 0.1, "thirty days, no more")
        let mine = try await person.vouching.myVouch()
        XCTAssertEqual(mine.standing, .vouched)
        XCTAssertEqual(mine.rights?.directMessages, false)
        XCTAssertEqual(mine.rights?.hostRooms, false)
        XCTAssertEqual(mine.rights?.vouchForOthers, false)
        XCTAssertEqual(mine.rights?.allows("post_international"), true)
        let theirOwn = try await person.vouching.overview()
        XCTAssertFalse(theirOwn.canVouch)
        XCTAssertEqual(theirOwn.reason?.code, "self_verification_required", "depth exactly one")
        let personRows = try await rows(person)
        XCTAssertTrue(personRows.contains { $0.kind == .vouchConfirmed }, "no vouch_confirmed row the app can read")

        // The tag as others see it: the voucher's handle and the country, as
        // text — never the seal, never the flag's code.
        let tagged = try XCTUnwrap(personRows.first { $0.kind == .vouchConfirmed })
        XCTAssertEqual(tagged.actor.handle, voucher.handle)
        let onProfile = try await ProfileService(
            network: URLSessionNetworkClient(),
            tokens: StaticAccessTokenProvider(token: voucher.token),
            analytics: RecordingAnalyticsClient()
        ).fetchProfile(handle: person.handle)
        let tag = try XCTUnwrap(onProfile.user.vouchedBy, "the vouched person's profile carries no tag")
        XCTAssertEqual(tag.handle, voucher.handle)
        XCTAssertEqual(tag.country, "SA")
        XCTAssertFalse(onProfile.user.isVerified)
        XCTAssertNil(onProfile.user.countryCode)

        // Taken off again: back to the wall, and nothing is left live.
        try await person.vouching.removeMyVouch()
        let after = try await person.auth.currentUser()
        XCTAssertEqual(after.standing, .noStanding)
        XCTAssertNil(after.vouch)
        let ended = try await voucher.vouching.overview()
        XCTAssertTrue(ended.vouches.isEmpty, "a vouch is still live after the tag came off")
        XCTAssertEqual(ended.ended.first { $0.id == claimed?.id }?.endReason, "removed")

        // Back at the wall, the wall can say why (§15): taken off by the
        // person, and — a confirmed vouch having ended — the fortnight's wait
        // before anybody may vouch again, so verification is the way on.
        let why = try await person.vouching.myVouch()
        XCTAssertNil(why.vouch)
        let lastEnded = try XCTUnwrap(why.lastEnded, "GET /me/vouch says nothing about the vouch that just ended")
        XCTAssertEqual(lastEnded.id, claimed?.id)
        XCTAssertEqual(lastEnded.endReason, "removed")
        XCTAssertEqual(lastEnded.handle, voucher.handle)
        XCTAssertNotNil(lastEnded.endedAt)
        XCTAssertEqual(lastEnded.vouchAgain, "vouch_too_soon")
        L10n.use("en")
        defer { L10n.use(nil) }
        let card = VouchCopy.lastEnded(lastEnded)
        XCTAssertEqual(card.title, "The vouch from @\(voucher.handle) has ended")
        XCTAssertEqual(card.reason, "You took the vouch off.")
        XCTAssertEqual(card.next, "Verify your identity to continue.")
    }

    // MARK: - Three mismatches

    func testThreeMismatchesCloseTheLinkForGood() async throws {
        let voucher = try await disposable(voucher: true)
        let guesser = try await disposable(voucher: false)
        let minted = try await voucher.vouching.mintInvite(
            label: nil, details: VouchDetails(fullName: "Itest Closed \(UUID().uuidString.prefix(4))", nationality: "AE", dateOfBirth: "1990-01-30"))
        let link = try token(of: minted)
        let guess = VouchDetails(fullName: "Somebody Else", nationality: "SA", dateOfBirth: "1990-01-31")

        for expected in [2, 1] {
            do {
                _ = try await guesser.vouching.claim(token: link, details: guess)
                XCTFail("a guess was accepted")
            } catch let APIError.detailsMismatch(fields, left, _) {
                XCTAssertEqual(fields, ["full_name", "nationality", "date_of_birth"], "every field that differs, in order")
                XCTAssertEqual(left, expected)
            }
        }
        do {
            _ = try await guesser.vouching.claim(token: link, details: guess)
            XCTFail("the third guess was not refused")
        } catch let error as APIError {
            XCTAssertEqual(error.code, .inviteClosed)
        }
        do {
            _ = try await guesser.vouching.landing(token: link)
            XCTFail("a closed link still has a landing")
        } catch let error as APIError {
            XCTAssertEqual(error.code, .inviteUnavailable, "one answer for every link that cannot be used")
        }

        // The voucher hears of it, and the link is gone from their open ones.
        let told = try await rows(voucher)
        XCTAssertTrue(told.contains { $0.kind == .vouchInviteClosed }, "no vouch_invite_closed row: \(told.map(\.kind))")
        let list = try await voucher.vouching.overview()
        XCTAssertFalse(list.invites.contains { $0.id == minted.invite.id }, "a closed link is still listed as open")
    }
}
