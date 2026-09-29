import CryptoKit
import DeviceCheck
import Foundation

// MARK: - The seam over DCAppAttestService

/// The three calls Sila makes to App Attest, behind a protocol so every rule
/// below is testable without a Secure Enclave. The real one is
/// ``DeviceCheckAppAttest``; tests script their own.
public protocol AppAttestProviding: Sendable {
    /// `DCAppAttestService.shared.isSupported` — false on the simulator, on
    /// devices without a Secure Enclave, and in most app extensions.
    var isSupported: Bool { get }
    /// Makes a key pair in the Secure Enclave and answers its id (base64).
    func generateKey() async throws -> String
    /// Has Apple certify the key, over `clientDataHash`.
    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data
    /// Signs `clientDataHash` with the key.
    func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data
}

/// ``AppAttestProviding`` backed by `DCAppAttestService.shared`.
public struct DeviceCheckAppAttest: AppAttestProviding {

    public init() {}

    public var isSupported: Bool { DCAppAttestService.shared.isSupported }

    public func generateKey() async throws -> String {
        try await DCAppAttestService.shared.generateKey()
    }

    public func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data {
        try await DCAppAttestService.shared.attestKey(keyId, clientDataHash: clientDataHash)
    }

    public func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data {
        try await DCAppAttestService.shared.generateAssertion(keyId, clientDataHash: clientDataHash)
    }
}

// MARK: - What the document route asks of it

/// Proves a document submission came from the genuine Sila app on a real
/// Apple device, over exactly the pictures being uploaded (contract v32).
///
/// Never in the way: nothing here throws, and a device that cannot attest —
/// the simulator, an old phone, Apple's servers out of reach, a refusal —
/// answers `nil` and the submission goes without, for a person to review.
public protocol DocumentAttesting: Sendable {
    /// Readies this account's attested key ahead of a submission, so the
    /// submission itself only has to sign. Safe to call any number of times.
    func prepare() async
    /// The assertion over `submission`, or `nil` to submit without one.
    /// Answers within a bounded time whatever the network does.
    func proof(for submission: DocumentSubmission) async -> DeviceProof?
}

/// The production ``DocumentAttesting``.
///
/// **One key per account per install** (Apple: "for each user account on
/// each device"). The key lives in the Secure Enclave; its id is kept in the
/// keychain under the account's id, readable only on this device and never
/// in a backup — a key does not survive a reinstall, a restore or a new
/// phone, and the keychain item must not outlive it. A reinstall's keychain
/// is emptied at launch (``AuthTokenStore``); a key that is gone anyway is
/// noticed when it fails and replaced. Every key made counts toward Apple's
/// count of keys on the phone (contract v32 §8), so a key is replaced only
/// when it cannot be used.
///
/// The key's life:
/// 1. `generateKey`, id stored as *not yet attested*;
/// 2. `POST /device/attest/challenge`, `attestKey` over the SHA-256 of the
///    challenge's UTF-8 bytes, `POST /device/attest`;
///    - `201`, or `409 key_exists` (an earlier answer lost on the way back):
///      stored as *attested*;
///    - `400 challenge_stale` (the challenge expired, was replaced or was
///      spent): nothing was said about the device — again at once with a
///      fresh challenge, the same key where Apple attests it again, else a
///      new one; at most ``attestationRounds`` rounds, then next time;
///    - no answer (offline, a `5xx`): the server may hold the key, so it is
///      asked (the key-status route below) before the key is attested again
///      with a fresh challenge — within the same rounds, and after a relaunch;
///    - `400 attestation_invalid`: the key is discarded, and none is tried
///      again on this install for ``refusalCoolDown`` — the genuine app on a
///      genuine device is refused only when the two sides disagree about
///      something, and a new key every submission would not change that.
///      Only this answer pauses attestation;
///    - anything else (`429`, signed out, another refusal): the key is kept
///      and attested next time;
///    - `DCError.serverUnavailable`: the key is kept and attested later;
///      any other App Attest error: the key is discarded (Apple's rule).
/// 3. Before each submission: `POST /device/assert/challenge {"key_id"}`,
///    the client data of ``AppAttestClientData``, `generateAssertion`. The
///    key rides along so the server can say `404 key_unknown` when it no
///    longer holds it (let go since); the key is then dropped and a new one
///    attested, once, on the spot. Opening the document flow asks the same
///    once a launch, so a key the server let go is replaced while the person
///    is still at the camera rather than on the submission's clock.
public actor AppAttestor: DocumentAttesting {

    /// What the keychain holds for one account.
    struct KeyRecord: Codable, Equatable, Sendable {
        /// The key's id; `nil` after a refusal.
        var keyId: String?
        /// Whether the server accepted the key.
        var attested: Bool
        /// When the server last refused an attestation from this install.
        var refusedAt: Date?
        /// The key went to `POST /device/attest` and no answer came back:
        /// the server may hold it, and is asked before it is attested again.
        var unanswered: Bool?
    }

    /// How long to wait after the server refused an attestation before
    /// making another key.
    public static let refusalCoolDown: TimeInterval = 24 * 3600
    /// The most challenges one attempt to attest asks for when a challenge
    /// goes stale or an answer is lost, before leaving it for next time.
    public static let attestationRounds = 3
    /// How long a submission waits for its assertion before going without.
    /// The key is normally attested before the person reaches the camera,
    /// which leaves a challenge and an on-device signature.
    public static let submissionBudget: TimeInterval = 15

    private let service: AppAttestProviding
    private let network: NetworkClient
    private let tokens: AccessTokenProviding
    private let keychain: KeychainClient
    private let analytics: AnalyticsClient
    private let account: @Sendable () async -> String?
    private let budget: @Sendable () async -> Void
    private let now: @Sendable () -> Date

    /// Kept beside the keychain, so a keychain that cannot be written this
    /// minute does not cost the key.
    private var records: [String: KeyRecord] = [:]
    /// The attestation under way, per account: one at a time, however many
    /// callers ask.
    private var attesting: [String: Task<String?, Never>] = [:]
    /// Keys the server said it holds (or accepted) since launch.
    private var confirmed: Set<String> = []

    /// - Parameters:
    ///   - service: App Attest.
    ///   - network: HTTP transport.
    ///   - tokens: Supplies the bearer token.
    ///   - keychain: Where each account's key id is kept.
    ///   - analytics: Outcomes only — never a key, a challenge or a byte of
    ///     the submission.
    ///   - account: The signed-in account's id, or `nil` when nobody is.
    ///   - budget: Returns when a submission has waited long enough.
    ///   - now: Clock, for the refusal cool-down.
    public init(
        service: AppAttestProviding = DeviceCheckAppAttest(),
        network: NetworkClient,
        tokens: AccessTokenProviding,
        keychain: KeychainClient,
        analytics: AnalyticsClient,
        account: @escaping @Sendable () async -> String?,
        budget: @escaping @Sendable () async -> Void = { await Deadline.sleep(AppAttestor.submissionBudget) },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.service = service
        self.network = network
        self.tokens = tokens
        self.keychain = keychain
        self.analytics = analytics
        self.account = account
        self.budget = budget
        self.now = now
    }

    /// The keychain item for `account`'s key.
    static func keychainKey(for account: String) -> KeychainKey {
        KeychainKey("appattest.key.\(account)")
    }

    // MARK: DocumentAttesting

    /// Attests the key if there is none yet, and otherwise asks the server
    /// once a launch whether it still holds it.
    public func prepare() async {
        guard service.isSupported, let account = await account() else { return }
        _ = await attestedKey(for: account, confirming: true)
    }

    public func proof(for submission: DocumentSubmission) async -> DeviceProof? {
        guard service.isSupported else {
            track(.assert, "unsupported")
            return nil
        }
        let work = Task { await self.sign(submission) }
        let budget = self.budget
        let outcome = await withCheckedContinuation { (continuation: CheckedContinuation<Race, Never>) in
            let once = ResumeOnce(continuation)
            let timer = Task {
                await budget()
                once.resume(.timedOut)
            }
            Task {
                once.resume(.finished(await work.value))
                timer.cancel()
            }
        }
        switch outcome {
        case let .finished(proof):
            return proof
        case .timedOut:
            // The submission goes now. An attestation still under way carries
            // on by itself and is there for the next one.
            work.cancel()
            track(.assert, "failed", reason: "timeout")
            return nil
        }
    }

    private enum Race: Sendable {
        case finished(DeviceProof?)
        case timedOut
    }

    // MARK: Signing a submission

    private func sign(_ submission: DocumentSubmission) async -> DeviceProof? {
        guard let account = await account() else {
            track(.assert, "failed", reason: "signed_out")
            return nil
        }
        // Twice at most: a key the server no longer holds, or one the
        // keychain remembers but the Secure Enclave no longer has, is
        // replaced once, here, rather than cost this submission its assertion.
        for attempt in 0..<2 {
            guard let keyId = await attestedKey(for: account) else {
                signingFailed("no_key")
                return nil
            }
            // Out of time while the key was being attested: the submission
            // has gone without, and a challenge asked for now would only
            // replace one nobody will present.
            guard !Task.isCancelled else { return nil }
            let challenge: String
            do {
                challenge = try await fetchAssertChallenge(for: keyId)
            } catch let error where Self.code(of: error) == .keyUnknown {
                // Let go on the server: every signature with it would be in
                // vain. Dropped, and a new key attested.
                track(.status, "forgotten")
                forget(keyId, of: account)
                guard attempt == 0 else {
                    signingFailed("key_unknown")
                    return nil
                }
                continue
            } catch {
                signingFailed(Self.reason(error))
                return nil
            }
            confirmed.insert(keyId)
            do {
                let hash = try AppAttestClientData(challenge: challenge, submission: submission).hash()
                let assertion = try await service.generateAssertion(keyId, clientDataHash: hash)
                guard !Task.isCancelled else { return nil }
                track(.assert, "ok")
                return DeviceProof(keyID: keyId, assertion: assertion.base64EncodedString())
            } catch {
                signingFailed(Self.reason(error))
                guard Self.isInvalidKey(error), attempt == 0 else { return nil }
                forget(keyId, of: account)
            }
        }
        return nil
    }

    /// Records a failed signing — unless the submission already stopped
    /// waiting, which ``proof(for:)`` has recorded as a timeout.
    private func signingFailed(_ reason: String) {
        guard !Task.isCancelled else { return }
        track(.assert, "failed", reason: reason)
    }

    // MARK: The key

    /// This account's attested key, attesting one first when there is none.
    /// `confirming` also asks the server whether an attested key is still on
    /// file, once a launch.
    private func attestedKey(for account: String, confirming: Bool = false) async -> String? {
        if let running = attesting[account] {
            return await running.value
        }
        // Unstructured on purpose: a caller that stops waiting (a screen
        // closed, a submission out of time) must not abandon a key halfway
        // between Apple and the server.
        let task = Task { await self.establishKey(for: account, confirming: confirming) }
        attesting[account] = task
        let key = await task.value
        attesting[account] = nil
        return key
    }

    private func establishKey(for account: String, confirming: Bool) async -> String? {
        if let stored = record(for: account), stored.attested, let keyId = stored.keyId {
            guard confirming, !confirmed.contains(keyId) else { return keyId }
            switch await keyStatus(keyId) {
            case .onFile, .unknown:
                // Held, or nobody could say: used as it is. The submission's
                // own challenge asks again.
                return keyId
            case .forgotten:
                // Let go on the server: replaced below.
                forget(keyId, of: account)
            }
        }
        let stored = record(for: account)
        if let refusedAt = stored?.refusedAt, now().timeIntervalSince(refusedAt) < Self.refusalCoolDown {
            return nil
        }
        var keyId = stored?.keyId
        var mayBeOnFile = stored?.unanswered == true
        // A key made in this call that Apple has not attested yet is not
        // replaced when Apple refuses it (a new key would likely meet the
        // same refusal, and each one counts on the phone); any other key
        // Apple refuses — a stored one, or one being attested again after a
        // stale challenge — is replaced once, at once.
        var isFresh = false
        var attestedByApple = false
        var replaced = false
        for _ in 0..<Self.attestationRounds {
            let current: String
            if let keyId {
                current = keyId
            } else {
                do {
                    current = try await service.generateKey()
                } catch {
                    track(.attest, "failed", reason: Self.reason(error))
                    return nil
                }
                store(KeyRecord(keyId: current, attested: false, refusedAt: nil), for: account)
                keyId = current
                isFresh = true
                attestedByApple = false
                mayBeOnFile = false
            }
            if mayBeOnFile {
                // Its answer was lost: the server may have kept it.
                switch await keyStatus(current) {
                case .onFile:
                    store(KeyRecord(keyId: current, attested: true, refusedAt: nil), for: account)
                    return current
                case .forgotten:
                    // Never arrived: attested again below, with a fresh challenge.
                    store(KeyRecord(keyId: current, attested: false, refusedAt: nil), for: account)
                    mayBeOnFile = false
                case .unknown:
                    // Asked again next time, before anything else.
                    return nil
                }
            }
            switch await attest(current, for: account) {
            case .attested:
                return current
            case .later:
                return nil
            case let .again(lost):
                attestedByApple = true
                mayBeOnFile = lost
            case .discardKey:
                forget(current, of: account)
                guard !replaced, !isFresh || attestedByApple else { return nil }
                replaced = true
                keyId = nil
            }
        }
        // Out of rounds: the key stays — not attested, and no cool-down,
        // since nothing was said about the device — and is tried next time.
        return nil
    }

    private enum Attestation {
        /// The server holds the key.
        case attested
        /// Nothing more now; the stored key (or refusal) stands.
        case later
        /// Again with a fresh challenge: the challenge went stale, or the
        /// answer was `lost` (the server may hold the key).
        case again(lost: Bool)
        /// App Attest refused the key: make another.
        case discardKey
    }

    private func attest(_ keyId: String, for account: String) async -> Attestation {
        let challenge: String
        do {
            challenge = try await fetchChallenge("/device/attest/challenge")
        } catch {
            // Nothing happened to the key; it is attested next time.
            track(.attest, "failed", reason: Self.reason(error))
            return .later
        }

        let attestation: Data
        do {
            attestation = try await service.attestKey(keyId, clientDataHash: Data(SHA256.hash(data: Data(challenge.utf8))))
        } catch {
            track(.attest, "failed", reason: Self.reason(error))
            // Apple: on serverUnavailable try again later with the same key;
            // on anything else discard it and make a new one.
            return Self.isServerUnavailable(error) ? .later : .discardKey
        }

        do {
            let token = try await tokens.accessToken()
            let request = try APIRequest.json(
                "/device/attest",
                body: AttestBody(keyId: keyId, attestation: attestation.base64EncodedString(), challenge: challenge),
                accessToken: token
            )
            _ = try await network.sendData(request)
            track(.attest, "ok")
            confirmed.insert(keyId)
        } catch let error where Self.status(of: error) == 409 {
            // `key_exists`: already on file — an earlier answer that never
            // arrived. If it is this account's, its assertions verify; the
            // next status check says if not.
            track(.attest, "ok", reason: "key_exists")
        } catch let error where Self.code(of: error) == .attestationInvalid {
            // The server's verdict on the attestation itself. The reason is in
            // the server's log and on no screen: nobody here can act on it.
            track(.attest, "refused", reason: "http_400")
            store(KeyRecord(keyId: nil, attested: false, refusedAt: now()), for: account)
            return .later
        } catch let error where Self.code(of: error) == .challengeStale {
            // Expired (the phone locked on the way), replaced (another device
            // of the account asked meanwhile) or spent: not the device's fault.
            track(.attest, "again", reason: "stale")
            return .again(lost: false)
        } catch let error where Self.isLostAnswer(error) {
            // Maybe it arrived, maybe not: remembered, so the server is asked
            // before the key is attested again — now or after a relaunch.
            track(.attest, "again", reason: Self.reason(error))
            store(KeyRecord(keyId: keyId, attested: false, refusedAt: nil, unanswered: true), for: account)
            return .again(lost: true)
        } catch {
            // Not kept (rate-limited, signed out, refused for something other
            // than the device): the key stays and is attested next time.
            track(.attest, "failed", reason: Self.reason(error))
            return .later
        }
        store(KeyRecord(keyId: keyId, attested: true, refusedAt: nil), for: account)
        return .attested
    }

    private struct AttestBody: Encodable {
        let keyId: String
        let attestation: String
        let challenge: String
    }

    private struct KeyBody: Encodable {
        let keyId: String
    }

    private struct ChallengeResponse: Decodable {
        let challenge: String
    }

    private func fetchChallenge(_ path: String) async throws -> String {
        let token = try await tokens.accessToken()
        let request = APIRequest(path: path, method: .post, accessToken: token)
        return try await network.send(request, as: ChallengeResponse.self).challenge
    }

    /// An assertion challenge for `keyId`. The key rides along so the
    /// server answers `404 key_unknown`, and issues nothing, when this
    /// account no longer holds it.
    private func fetchAssertChallenge(for keyId: String) async throws -> String {
        let token = try await tokens.accessToken()
        let request = try APIRequest.json("/device/assert/challenge", body: KeyBody(keyId: keyId), accessToken: token)
        return try await network.send(request, as: ChallengeResponse.self).challenge
    }

    private enum KeyStatus {
        /// The server holds it for this account.
        case onFile
        /// `404 key_unknown`: never arrived, or let go since.
        case forgotten
        /// Nobody could say (offline, rate-limited): nothing changes.
        case unknown
    }

    /// Whether the server still holds `keyId` for this account. The
    /// challenge it issues on the way is left unused; a submission asks for
    /// its own right before it signs.
    private func keyStatus(_ keyId: String) async -> KeyStatus {
        do {
            _ = try await fetchAssertChallenge(for: keyId)
            confirmed.insert(keyId)
            track(.status, "ok")
            return .onFile
        } catch let error where Self.code(of: error) == .keyUnknown {
            track(.status, "forgotten")
            return .forgotten
        } catch {
            track(.status, "failed", reason: Self.reason(error))
            return .unknown
        }
    }

    // MARK: The keychain

    private func record(for account: String) -> KeyRecord? {
        if let kept = records[account] { return kept }
        let loaded = (try? keychain.load(Self.keychainKey(for: account), as: KeyRecord.self)) ?? nil
        records[account] = loaded
        return loaded
    }

    private func store(_ record: KeyRecord, for account: String) {
        records[account] = record
        try? keychain.save(record, for: Self.keychainKey(for: account))
    }

    /// Drops `keyId` — only if it is still the one kept for `account`.
    private func forget(_ keyId: String, of account: String) {
        confirmed.remove(keyId)
        guard record(for: account)?.keyId == keyId else { return }
        records[account] = KeyRecord(keyId: nil, attested: false, refusedAt: nil)
        try? keychain.delete(Self.keychainKey(for: account))
    }

    // MARK: Reading errors

    static func isServerUnavailable(_ error: Error) -> Bool {
        (error as? DCError)?.code == .serverUnavailable
    }

    static func isInvalidKey(_ error: Error) -> Bool {
        (error as? DCError)?.code == .invalidKey
    }

    /// The HTTP status of a refusal, when the server answered one.
    static func status(of error: Error) -> Int? {
        switch error as? APIError {
        case let .api(_, _, status)?: return status
        case let .http(status, _)?: return status
        default: return nil
        }
    }

    /// The server's code, when it sent one.
    static func code(of error: Error) -> APIErrorCode? {
        (error as? APIError)?.code
    }

    /// A request that may have reached the server without its answer
    /// reaching the phone: the connection failed, or something between
    /// them answered a `5xx`.
    static func isLostAnswer(_ error: Error) -> Bool {
        switch error as? APIError {
        case .transport?: return true
        case let .api(_, _, status)?: return status >= 500
        case let .http(status, _)?: return status >= 500
        default: return false
        }
    }

    /// A short, fixed word for what went wrong — for analytics.
    static func reason(_ error: Error) -> String {
        if let error = error as? DCError {
            return "dc_\(error.code.rawValue)"
        }
        if let status = status(of: error) {
            return "http_\(status)"
        }
        switch error as? APIError {
        case .transport?: return "transport"
        case .cancelled?: return "cancelled"
        case .unauthenticated?: return "signed_out"
        case .decoding?: return "decoding"
        default: return error is CancellationError ? "cancelled" : "other"
        }
    }

    // MARK: Analytics

    private enum Step: String {
        case attest
        case assert
        /// Whether the server still holds the key.
        case status
    }

    private func track(_ step: Step, _ result: String, reason: String? = nil) {
        var properties = ["step": step.rawValue, "result": result]
        if let reason { properties["reason"] = reason }
        analytics.track(.deviceAttestation, properties: properties)
    }
}
