import XCTest
@testable import Sila

/// Contract v30 on the wire: every frame the server sends read as the
/// contract writes it, every frame the client sends written as it asks, what
/// each close means, the waits between attempts, and the new words.
final class RealtimeProtocolTests: XCTestCase {

    override func tearDown() {
        L10n.use(nil)
        super.tearDown()
    }

    // MARK: - Server frames

    func testReadyIsRead() throws {
        let ready = ScriptedSockets.ready(standing: "none")
        guard case let .ready(read)? = RealtimeFixtures.event(ready) else { return XCTFail("ready not read") }
        XCTAssertEqual(read.standing, "none")
        XCTAssertEqual(read.events, ["account.status"], "the wall hears one thing")
        XCTAssertEqual(read.heartbeatSeconds, 25)
        XCTAssertEqual(read.typingSeconds, 6)
        XCTAssertNotNil(read.tokenExpiresAt)
        XCTAssertEqual(read.userId, UserSummary.mockViewer.id)
    }

    /// `message` is exactly the object the thread returns — so it decodes
    /// through the same type, to the same value.
    func testANewMessageIsTheThreadsOwnObject() throws {
        let id = UUID()
        let frame = RealtimeFixtures.messageNew(id: id, text: "hello, live", alert: true)
        guard case let .messageNew(new)? = RealtimeFixtures.event(frame) else { return XCTFail("message.new not read") }

        let thread = #"{"messages": [\#(RealtimeFixtures.json(RealtimeFixtures.message(id: id, text: "hello, live")))]}"#
        let listed = try JSONCoding.decoder.decode(MessagesEnvelope.self, from: Data(thread.utf8)).messages
        XCTAssertEqual(new.message, listed.first)
        XCTAssertEqual(new.conversationId, RealtimeFixtures.thread)
        XCTAssertEqual(new.conversation, .init(id: RealtimeFixtures.thread, accepted: true, isRequest: false))
        XCTAssertTrue(new.alert)
        XCTAssertEqual(new.message.sender.handle, "noura")
    }

    func testARequestArrivesQuietly() throws {
        let frame = RealtimeFixtures.messageNew(text: "we have never met", isRequest: true, alert: false)
        guard case let .messageNew(new)? = RealtimeFixtures.event(frame) else { return XCTFail() }
        XCTAssertTrue(new.conversation.isRequest)
        XCTAssertFalse(new.conversation.accepted)
        XCTAssertFalse(new.alert)
    }

    func testReceiptsDeletionsTypingAndNotificationsAreRead() throws {
        let thread = RealtimeFixtures.thread.uuidString.lowercased()
        let reader = UUID()
        guard case let .messageRead(read)? = RealtimeFixtures.event([
            "type": "message.read", "at": "2026-09-28T14:45:34+00:00", "conversation_id": thread,
            "reader_id": reader.uuidString.lowercased(), "read_at": "2026-09-28T14:45:34.100000+00:00",
        ]) else { return XCTFail("message.read") }
        XCTAssertEqual(read.readerId, reader)
        XCTAssertEqual(read.conversationId, RealtimeFixtures.thread)

        let gone = UUID()
        guard case let .messageDeleted(deleted)? = RealtimeFixtures.event([
            "type": "message.deleted", "conversation_id": thread, "message_id": gone.uuidString.lowercased(),
        ]) else { return XCTFail("message.deleted") }
        XCTAssertEqual(deleted.messageId, gone)

        guard case let .typing(typing)? = RealtimeFixtures.event([
            "type": "typing", "conversation_id": thread, "user_id": RealtimeFixtures.noura.uuidString,
            "active": true, "expires_in": 6,
        ]) else { return XCTFail("typing") }
        XCTAssertEqual(typing, RealtimeTyping(conversationId: RealtimeFixtures.thread, userId: RealtimeFixtures.noura, active: true, expiresIn: 6))

        guard case let .typing(stopped)? = RealtimeFixtures.event([
            "type": "typing", "conversation_id": thread, "user_id": RealtimeFixtures.noura.uuidString,
            "active": false, "expires_in": 0,
        ]) else { return XCTFail("typing stopped") }
        XCTAssertFalse(stopped.active)

        let row = UUID()
        guard case let .notificationNew(note)? = RealtimeFixtures.event([
            "type": "notification.new", "id": row.uuidString.lowercased(), "kind": "follow", "unread_count": 3,
        ]) else { return XCTFail("notification.new") }
        XCTAssertEqual(note, RealtimeNotificationNew(id: row, kind: "follow", unreadCount: 3))
    }

    /// `me` is what `/auth/me` returns, and decodes into the same account.
    func testTheAccountStatusIsTheAccountItself() throws {
        let me: [String: Any] = [
            "id": "11111111-2222-3333-4444-555555555555",
            "email": "person@example.com",
            "display_name": "Person",
            "email_verified": true,
            "verification_status": "pending_review",
            "created_at": "2026-09-01T10:00:00+00:00",
            "handle": "person",
            "country_code": NSNull(),
            "standing": "none",
            "vouch": NSNull(),
        ]
        guard case let .accountStatus(account)? = RealtimeFixtures.event(["type": "account.status", "me": me]) else {
            return XCTFail("account.status not read")
        }
        let direct = try JSONCoding.decoder.decode(AuthUser.self, from: Data(RealtimeFixtures.json(me).utf8))
        XCTAssertEqual(account, direct)
        XCTAssertEqual(account.verificationStatus, .pendingReview)
    }

    func testProtocolFramesAndStrangersAreToldApart() {
        guard case .ping? = RealtimeFrame.parse(#"{"type":"ping","at":"2026-09-28T14:45:33+00:00"}"#) else { return XCTFail() }
        guard case .reauthRequired? = RealtimeFrame.parse(#"{"type":"reauth_required","token_expires_at":"2026-09-28T15:15:33+00:00"}"#) else { return XCTFail() }
        guard case let .authOK(standing, _)? = RealtimeFrame.parse(#"{"type":"auth_ok","standing":"vouched"}"#) else { return XCTFail() }
        XCTAssertEqual(standing, "vouched")
        guard case let .error(code, ref, conversation)? = RealtimeFrame.parse(
            #"{"type":"error","code":"self_verification_required","ref":"typing"}"#
        ) else { return XCTFail() }
        XCTAssertEqual(code, "self_verification_required")
        XCTAssertEqual(ref, "typing")
        XCTAssertNil(conversation)
        guard case let .unknown(type)? = RealtimeFrame.parse(#"{"type":"presence.online"}"#) else { return XCTFail() }
        XCTAssertEqual(type, "presence.online", "a later contract's event is ignored, not an error")
        XCTAssertNil(RealtimeFrame.parse("[1, 2]"))
        XCTAssertNil(RealtimeFrame.parse(#"{"no":"type"}"#))
        XCTAssertNil(RealtimeFrame.parse(#"{"type":"message.new","message":{"id":"x"}}"#), "a broken event is dropped")
    }

    // MARK: - Client frames

    func testTheClientSendsExactlyWhatTheContractAsks() {
        XCTAssertEqual(frameObject(RealtimeOutgoing.auth(token: "abc")) as NSDictionary, ["type": "auth", "token": "abc"] as NSDictionary)
        XCTAssertEqual(frameObject(RealtimeOutgoing.pong) as NSDictionary, ["type": "pong"] as NSDictionary)
        let thread = UUID()
        XCTAssertEqual(
            frameObject(RealtimeOutgoing.typing(conversationId: thread, active: true)) as NSDictionary,
            ["type": "typing", "conversation_id": thread.uuidString.lowercased()] as NSDictionary
        )
        XCTAssertEqual(
            frameObject(RealtimeOutgoing.typing(conversationId: thread, active: false)) as NSDictionary,
            ["type": "typing", "conversation_id": thread.uuidString.lowercased(), "active": false] as NSDictionary
        )
        XCTAssertLessThan(RealtimeOutgoing.auth(token: String(repeating: "t", count: 900)).count, 4096)
    }

    // MARK: - Closes

    func testEveryCloseHasItsAnswer() {
        typealias D = RealtimeCloseDecision
        XCTAssertEqual(D.decide(errorCode: "account_suspended", closeCode: 4403), .stop(.suspended))
        XCTAssertEqual(D.decide(errorCode: "account_deactivated", closeCode: 4403), .stop(.deactivated))
        for code in ["token_expired", "unauthorized", "different_account"] {
            XCTAssertEqual(D.decide(errorCode: code, closeCode: 4401), .renewToken, code)
        }
        for code in ["realtime_unavailable", "busy", "too_slow"] {
            XCTAssertEqual(D.decide(errorCode: code, closeCode: 1013), .retry(.unavailable), code)
        }
        XCTAssertEqual(D.decide(errorCode: "too_many_connections", closeCode: 4429), .retry(.later(60)))
        XCTAssertEqual(D.decide(errorCode: "rate_limited", closeCode: 4429), .retry(.later(60)))
        for code in ["auth_timeout", "heartbeat_timeout", "auth_required", "frame_too_large", "server_error"] {
            XCTAssertEqual(D.decide(errorCode: code, closeCode: 4408), .retry(.backoff), code)
        }
        // No error frame: the close code alone.
        for code in [1000, 1001, 1006, 1012, 1003, 1009, 4400, 4408] {
            XCTAssertEqual(D.decide(errorCode: nil, closeCode: code), .retry(.backoff), "\(code)")
        }
        XCTAssertEqual(D.decide(errorCode: nil, closeCode: 1013), .retry(.unavailable))
        XCTAssertEqual(D.decide(errorCode: nil, closeCode: 4401), .renewToken)
        XCTAssertEqual(D.decide(errorCode: nil, closeCode: 4429), .retry(.later(60)))
        XCTAssertEqual(D.decide(errorCode: nil, closeCode: 4403), .stop(.refused))
        // Refused at the handshake (a foreign origin, a server with no socket).
        XCTAssertEqual(D.decide(errorCode: nil, closeCode: 1006, handshakeStatus: 403), .retry(.unavailable))
        XCTAssertEqual(D.decide(errorCode: nil, closeCode: 1006, handshakeStatus: 404), .retry(.unavailable))
    }

    func testTheWaitsAreTheContracts() {
        // At the middle of the jitter, every wait is exactly its step.
        let plain = (0..<8).map { RealtimeBackoff.delay(.backoff, attempt: $0, jitter: 0.5) }
        XCTAssertEqual(plain, [1, 2, 5, 10, 30, 60, 60, 60])
        let unavailable = (0..<7).map { RealtimeBackoff.delay(.unavailable, attempt: $0, jitter: 0.5) }
        XCTAssertEqual(unavailable, [30, 60, 120, 240, 300, 300, 300], "30 s, then up to five minutes")
        XCTAssertEqual(RealtimeBackoff.delay(.later(60), attempt: 3, jitter: 0.5), 60)
        // Between half and one and a half times the step (2026-09-28 review:
        // "up to 30 % more" brought every phone back in the same few
        // seconds); the five-minute ceiling holds with it.
        XCTAssertEqual(RealtimeBackoff.delay(.backoff, attempt: 0, jitter: 0), 0.5, accuracy: 0.0001)
        XCTAssertEqual(RealtimeBackoff.delay(.backoff, attempt: 0, jitter: 1), 1.5, accuracy: 0.0001)
        XCTAssertEqual(RealtimeBackoff.delay(.backoff, attempt: 9, jitter: 1), 90, accuracy: 0.0001)
        XCTAssertEqual(RealtimeBackoff.delay(.unavailable, attempt: 0, jitter: 0), 15, accuracy: 0.0001)
        XCTAssertEqual(RealtimeBackoff.delay(.unavailable, attempt: 0, jitter: 1), 45, accuracy: 0.0001)
        XCTAssertEqual(RealtimeBackoff.delay(.unavailable, attempt: 9, jitter: 1), 300)
        XCTAssertEqual(RealtimeBackoff.delay(.backoff, attempt: 2, jitter: 5), 7.5, accuracy: 0.0001)
        XCTAssertEqual(RealtimeBackoff.resetAfter, 60)
    }

    func testTheRefreshAfterA1013WaitsARandomMomentOfUpToTenSeconds() {
        XCTAssertEqual(RealtimeBackoff.unavailableRefreshPause(jitter: 0), 0)
        XCTAssertEqual(RealtimeBackoff.unavailableRefreshPause(jitter: 0.25), 2.5, accuracy: 0.0001)
        XCTAssertEqual(RealtimeBackoff.unavailableRefreshPause(jitter: 1), 10)
        XCTAssertEqual(RealtimeBackoff.unavailableRefreshPause(jitter: 7), 10)
    }

    // MARK: - Where

    func testTheSocketLivesBesideTheAPIAndItsURLCarriesNothing() {
        XCTAssertEqual(
            AppConfig.realtimeURL(for: URL(string: "https://sila.gmai.sa/api/v1")!).absoluteString,
            "wss://sila.gmai.sa/api/v1/realtime"
        )
        XCTAssertEqual(
            AppConfig.realtimeURL(for: URL(string: "http://127.0.0.1:8101/api/v1")!).absoluteString,
            "ws://127.0.0.1:8101/api/v1/realtime",
            "staging through the tunnel"
        )
        XCTAssertEqual(AppConfig.realtimeURL(for: URL(string: "https://sila.gmai.sa/api/v1")!).scheme, "wss",
                       "production's socket is encrypted, like its API")
        XCTAssertNil(AppConfig.realtimeURL.query)
    }

    // MARK: - Words (contract v30 §6)

    func testTheNewWordsInBothLanguages() {
        XCTAssertTrue(L10n.use("en"))
        XCTAssertEqual(L10n.t("messages.typing"), "typing…")
        // The catalog's own sentences; `L10n.t` isolates the name when it
        // fills it in, so an Arabic name in an English sentence keeps its order.
        XCTAssertEqual(L10n.t("messages.typing.row"), "%@ is typing…")
        XCTAssertEqual(L10n.t("messages.bubble.read"), "Read")
        XCTAssertTrue(L10n.use("ar"))
        XCTAssertEqual(L10n.t("messages.typing"), "يكتب…")
        XCTAssertEqual(L10n.t("messages.typing.row"), "%@ يكتب…")
        XCTAssertEqual(L10n.t("messages.bubble.read"), "تمت القراءة")
    }
}
