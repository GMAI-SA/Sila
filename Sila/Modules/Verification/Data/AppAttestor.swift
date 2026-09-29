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
/// noticed when it fails and replaced.
///
/// The key's life:
/// 1. `generateKey`, id stored as *not yet attested*;
/// 2. `POST /device/attest/challenge`, `attestKey` over the SHA-256 of the
///    challenge's UTF-8 bytes, `POST /device/attest`;
///    - `201`, or `409 key_exists` (an earlier answer lost on the way back):
///      stored as *attested*;
///    - `DCError.serverUnavailable`: the key is kept and attested later;
///    - any other App Attest error: the key is discarded (Apple's rule);
///    - `400 attestation_invalid`: the key is discarded, and none is tried
///      again on this install for ``refusalCoolDown`` — the genuine app on a
///      genuine device is refused only when the two sides disagree about
///      something, and a new key every submission would not change that;
///    - anything else (offline, `429`, a `5xx`): the key is discarded — it
///      may never have reached the server, and a key is attested once.
/// 3. Before each submission: `POST /device/assert/challenge`, the client
///    data of ``AppAttestClientData``, `generateAssertion`.
public actor AppAttestor: DocumentAttesting {

    /// What the keychain holds for one account.
    struct KeyRecord: Codable, Equatable, Sendable {
        /// The key's id; `nil` after a refusal.
        var keyId: String?
        /// Whether the server accepted the key.
        var attested: Bool
        /// When the server last refused an attestation from this install.
        var refusedAt: Date?
    }

    /// How long to wait after the server refused an attestation before
    /// making another key.
    public static let refusalCoolDown: TimeInterval = 24 * 3600
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

    public func prepare() async {
        guard service.isSupported, let account = await account() else { return }
        _ = await attestedKey(for: account)
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
        // Twice at most: a key the keychain remembers but the Secure Enclave
        // no longer has is replaced once, here, rather than cost this
        // submission its assertion.
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
                challenge = try await fetchChallenge("/device/assert/challenge")
            } catch {
                signingFailed(Self.reason(error))
                return nil
            }
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
    private func attestedKey(for account: String) async -> String? {
        if let running = attesting[account] {
            return await running.value
        }
        // Unstructured on purpose: a caller that stops waiting (a screen
        // closed, a submission out of time) must not abandon a key halfway
        // between Apple and the server.
        let task = Task { await self.establishKey(for: account) }
        attesting[account] = task
        let key = await task.value
        attesting[account] = nil
        return key
    }

    private func establishKey(for account: String) async -> String? {
        let stored = record(for: account)
        if stored?.attested == true, let keyId = stored?.keyId {
            return keyId
        }
        if let refusedAt = stored?.refusedAt, now().timeIntervalSince(refusedAt) < Self.refusalCoolDown {
            return nil
        }
        var keyId = stored?.keyId
        // Twice at most: a stored key that App Attest no longer knows is
        // replaced by a fresh one straight away.
        for _ in 0..<2 {
            let isFresh = keyId == nil
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
            }
            switch await attest(current, for: account) {
            case .attested:
                return current
            case .later:
                return nil
            case .discardKey:
                forget(current, of: account)
                guard !isFresh else { return nil }
                keyId = nil
            }
        }
        return nil
    }

    private enum Attestation {
        /// The server holds the key.
        case attested
        /// Nothing more now; the stored key (or refusal) stands.
        case later
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
        } catch let error where Self.status(of: error) == 409 {
            // `key_exists`: already on file — an earlier answer that never
            // arrived. If it is this account's, its assertions verify.
            track(.attest, "ok", reason: "key_exists")
        } catch let error where Self.status(of: error) == 400 {
            // `attestation_invalid`. The reason is in the server's log and on
            // no screen: nobody here can act on it.
            track(.attest, "refused", reason: "http_400")
            store(KeyRecord(keyId: nil, attested: false, refusedAt: now()), for: account)
            return .later
        } catch {
            // Maybe it arrived, maybe not; a key is attested once. A new one
            // next time — a spare key on the server is cleared with the
            // account's least recently used.
            track(.attest, "failed", reason: Self.reason(error))
            forget(keyId, of: account)
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

    private struct ChallengeResponse: Decodable {
        let challenge: String
    }

    private func fetchChallenge(_ path: String) async throws -> String {
        let token = try await tokens.accessToken()
        let request = APIRequest(path: path, method: .post, accessToken: token)
        return try await network.send(request, as: ChallengeResponse.self).challenge
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
    }

    private func track(_ step: Step, _ result: String, reason: String? = nil) {
        var properties = ["step": step.rawValue, "result": result]
        if let reason { properties["reason"] = reason }
        analytics.track(.deviceAttestation, properties: properties)
    }
}
