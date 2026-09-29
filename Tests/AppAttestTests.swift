import CryptoKit
import DeviceCheck
import XCTest
@testable import Sila

// Contract v32 on iOS: the bytes a document submission's assertion signs,
// and the key's life — made once per account on this install, attested with
// a server challenge, used for every submission, and never in the way.

// MARK: - Doubles

/// App Attest without a Secure Enclave: keys are names, attestations and
/// assertions are labelled bytes, and every call is recorded.
final class FakeAppAttest: AppAttestProviding, @unchecked Sendable {

    private let lock = NSLock()
    private var supported = true
    private var keys = (1...9).map { "key-\($0)" }
    private var attestFailures: [Error] = []
    private var assertionFailures: [String: Error] = [:]
    private var gate: Gate?
    private var attestsOnce = false
    private var attestedOnce: Set<String> = []
    private var generatedKeys: [String] = []
    private var attestCalls: [(keyId: String, hash: Data)] = []
    private var assertCalls: [(keyId: String, hash: Data)] = []

    var isSupported: Bool {
        get { lock.withLock { supported } }
        set { lock.withLock { supported = newValue } }
    }

    /// The next attestations fail with these, in order.
    func failAttestations(_ errors: Error...) { lock.withLock { attestFailures = errors } }
    /// Every assertion with `keyId` fails with `error`.
    func failAssertions(of keyId: String, with error: Error) { lock.withLock { assertionFailures[keyId] = error } }
    /// Attestations wait at `gate` until it opens.
    func holdAttestations(at gate: Gate) { lock.withLock { self.gate = gate } }
    /// A key Apple has attested once is refused a second attestation — in
    /// case Apple does; the contract allows either.
    func refuseAttestingTwice() { lock.withLock { attestsOnce = true } }

    var generated: [String] { lock.withLock { generatedKeys } }
    var attested: [(keyId: String, hash: Data)] { lock.withLock { attestCalls } }
    var asserted: [(keyId: String, hash: Data)] { lock.withLock { assertCalls } }

    func generateKey() async throws -> String {
        lock.withLock {
            let key = keys.removeFirst()
            generatedKeys.append(key)
            return key
        }
    }

    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data {
        if let gate = lock.withLock({ gate }) { await gate.wait() }
        let failure: Error? = lock.withLock {
            attestCalls.append((keyId, clientDataHash))
            if attestsOnce, attestedOnce.contains(keyId) { return DCError(.invalidKey) }
            let failure = attestFailures.isEmpty ? nil : attestFailures.removeFirst()
            if failure == nil { attestedOnce.insert(keyId) }
            return failure
        }
        if let failure { throw failure }
        return Data("attestation of \(keyId)".utf8)
    }

    func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data {
        let failure: Error? = lock.withLock {
            assertCalls.append((keyId, clientDataHash))
            return assertionFailures[keyId]
        }
        if let failure { throw failure }
        return Data("assertion by \(keyId)".utf8)
    }
}

/// Holds whoever waits until it opens.
final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock {
                if isOpen { return true }
                waiting.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func open() {
        let released = lock.withLock {
            isOpen = true
            defer { waiting = [] }
            return waiting
        }
        released.forEach { $0.resume() }
    }
}

/// A clock a test moves by hand.
final class AttestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_790_000_000)
    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current += seconds } }
}

/// The server's side of contract v32, as far as the app can see it: the
/// keys it holds, and what it answers an attestation.
final class AttestServer: @unchecked Sendable {

    enum AttestAnswer {
        /// `201`: the key is kept.
        case created
        /// `409 key_exists`: the key is on file already.
        case keyExists
        /// `400 attestation_invalid`: the attestation itself is refused.
        case refused
        /// `400 challenge_stale`: expired, replaced or spent; nothing kept.
        case stale
        /// The connection dropped before the request arrived: nothing kept.
        case lost
        /// Kept, and the answer lost on the way back.
        case keptButLost
        /// `429 rate_limited`, counted before anything is checked.
        case rateLimited
        /// A `400` whose code the app does not know.
        case otherRefusal
    }

    private let lock = NSLock()
    private var answer: AttestAnswer = .created
    private var upcoming: [AttestAnswer] = []
    private var challengeFailure: APIError?
    private var issued = 0
    private var held: Set<String> = []
    private var keepsKeys = true

    /// Every attestation from now on answers `answer`.
    func answerAttestations(_ answer: AttestAnswer) { lock.withLock { self.answer = answer; upcoming = [] } }
    /// The next attestations answer these, in order; then the standing answer.
    func answerNextAttestations(_ answers: AttestAnswer...) { lock.withLock { upcoming = answers } }
    func failChallenges(_ error: APIError?) { lock.withLock { challengeFailure = error } }
    /// The server holds `keyId` for the account — attested before the test.
    func hold(_ keyId: String) { lock.withLock { _ = held.insert(keyId) } }
    /// The server lets `keyId` go, as when ten newer keys pushed it out.
    func letGo(_ keyId: String) { lock.withLock { _ = held.remove(keyId) } }
    /// Accepts attestations and holds none of them.
    func forgetEveryKey() { lock.withLock { keepsKeys = false; held = [] } }

    lazy var network = ScriptedNetwork { [unowned self] request in try self.handle(request) }

    private func sentKey(in request: APIRequest) -> String? {
        guard let body = request.body else { return nil }
        return (try? JSONSerialization.jsonObject(with: body) as? [String: String])?["key_id"]
    }

    private func keep(_ keyId: String?) {
        lock.lock()
        defer { lock.unlock() }
        if keepsKeys, let keyId { held.insert(keyId) }
    }

    private func holds(_ keyId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return held.contains(keyId)
    }

    private func nextAnswer() -> AttestAnswer {
        lock.lock()
        defer { lock.unlock() }
        return upcoming.isEmpty ? answer : upcoming.removeFirst()
    }

    private func nextChallenge() -> Int {
        lock.lock()
        defer { lock.unlock() }
        issued += 1
        return issued
    }

    private func failure() -> APIError? {
        lock.lock()
        defer { lock.unlock() }
        return challengeFailure
    }

    private func handle(_ request: APIRequest) throws -> String {
        switch request.path {
        case "/device/attest/challenge", "/device/assert/challenge":
            if let failure = failure() { throw failure }
            // With the key it is about to sign with: is it still on file?
            let named = request.path == "/device/assert/challenge" ? sentKey(in: request) : nil
            if let named, !holds(named) {
                throw APIError.api(code: .keyUnknown, message: "That key is not on file for this account", status: 404)
            }
            let number = nextChallenge()
            let purpose = request.path == "/device/attest/challenge" ? "attest" : "assert"
            return #"{"challenge": "\#(purpose)-challenge_\#(number)", "expires_at": "2026-09-29T10:05:00Z"}"#
        case "/device/attest":
            let keyId = sentKey(in: request)
            switch nextAnswer() {
            case .created:
                keep(keyId)
                return #"{"key_id": "\#(keyId ?? "")", "environment": "production", "created_at": "2026-09-29T10:00:00Z"}"#
            case .keyExists:
                keep(keyId)
                throw APIError.api(code: .keyExists, message: "That key is already attested", status: 409)
            case .refused:
                throw APIError.api(code: .attestationInvalid, message: "The device could not be attested", status: 400)
            case .stale:
                throw APIError.api(code: .challengeStale, message: "Ask for a new challenge", status: 400)
            case .lost:
                throw APIError.transport("The network connection was lost.")
            case .keptButLost:
                keep(keyId)
                throw APIError.transport("The network connection was lost.")
            case .rateLimited:
                throw APIError.api(code: .rateLimited, message: "Too many requests", status: 429)
            case .otherRefusal:
                throw APIError.api(code: .unknown, message: "Something the app does not know", status: 400)
            }
        case "/verification/document":
            return #"{"id": "case-1", "status": "submitted", "document_type": "passport", "verification_status": "pending_review"}"#
        default:
            throw APIError.http(status: 404, message: "Not Found")
        }
    }
}

// MARK: - The client data

final class AppAttestClientDataTests: XCTestCase {

    private func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

    /// Byte for byte the backend's own pin
    /// (`tests/test_app_attest.py::test_the_client_data_is_exactly_the_contracts_bytes`):
    /// keys sorted, no spaces, the strings as sent, the pictures' SHA-256 in
    /// lower-case hex in part order.
    func testTheClientDataIsExactlyTheContractsBytes() throws {
        let liveness = #"{"version":2,"straight":{"yaw":0.01,"pitch":-0.02,"t":0},"sectors":[],"duration":12.5}"#
        let mrz = "P<USAJOHN<<DOE<<<<\nL898902C36USA7408122F1204159<<<<<<<<<<<<<<06"
        let data = AppAttestClientData(
            challenge: "c-1_x", documentType: "passport", documentSource: "camera",
            images: [("front", Data("front bytes".utf8)), ("selfie", Data("selfie bytes".utf8)),
                     ("frames", Data("frame bytes".utf8))],
            liveness: liveness, mrz: mrz
        )
        // The digests are Python's hashlib.sha256(...).hexdigest(), not this
        // file's own arithmetic.
        let expected = #"{"challenge":"c-1_x","document_source":"camera","document_type":"passport","images":["#
            + #"{"part":"front","sha256":"12ca2d2a0f3de8303a9ed1af0a808a2e7fc02c76110d0a33c9326a5ed9be8151"},"#
            + #"{"part":"selfie","sha256":"8b06c528172be4017758538949201af79b084d4622c255dce115329f6d05494a"},"#
            + #"{"part":"frames","sha256":"f9dea2843a6dfb6dafd2a97c8f1848754d9266b82980f2f7fae9fb599266fd0f"}],"#
            + #""liveness":"{\"version\":2,\"straight\":{\"yaw\":0.01,\"pitch\":-0.02,\"t\":0},"#
            + #"\"sectors\":[],\"duration\":12.5}","#
            + #""mrz":"P<USAJOHN<<DOE<<<<\nL898902C36USA7408122F1204159<<<<<<<<<<<<<<06","version":1}"#
        XCTAssertEqual(text(try data.encoded()), expected)
        XCTAssertEqual(try data.hash(), Data(SHA256.hash(data: Data(expected.utf8))), "the hash is of exactly those bytes")
    }

    /// Not sent is the empty string — never `null`, never a missing key.
    func testAFieldNotSentIsTheEmptyString() throws {
        let data = AppAttestClientData(challenge: "c", documentType: "passport", documentSource: nil,
                                       images: [], liveness: nil, mrz: nil)
        XCTAssertEqual(
            text(try data.encoded()),
            #"{"challenge":"c","document_source":"","document_type":"passport","images":[],"liveness":"","mrz":"","version":1}"#
        )
    }

    /// The server's JSON (Python, `ensure_ascii=False`) for the characters
    /// that could ever differ: quotes, backslashes, slashes left alone,
    /// control characters, and anything outside ASCII written as itself.
    /// Expected bytes produced by the server's own `json.dumps` call.
    func testEscapingIsThePythonServersEscaping() throws {
        let odd = "a\"b\\c/d\ne\tf\rg\u{01}h\u{1F}i\u{7F}j\u{E9}k\u{0635}\u{0644}\u{0629}l\u{1F600}m\u{2028}n\u{08}o\u{0C}p"
        let data = AppAttestClientData(challenge: "chal", documentType: "passport", documentSource: "camera",
                                       images: [], liveness: nil, mrz: odd)
        let python = "7b226368616c6c656e6765223a226368616c222c22646f63756d656e745f736f75726365223a2263616d657261222c"
            + "22646f63756d656e745f74797065223a2270617373706f7274222c22696d61676573223a5b5d2c226c6976656e657373"
            + "223a22222c226d727a223a22615c22625c5c632f645c6e655c74665c72675c7530303031685c7530303166697f6ac3a9"
            + "6bd8b5d984d8a96cf09f98806de280a86e5c626f5c6670222c2276657273696f6e223a317d"
        XCTAssertEqual(try data.encoded().map { String(format: "%02x", $0) }.joined(), python)
    }

    /// Pictures are listed in the server's part order whatever order they
    /// are handed in, frames in the order sent, and an empty part is left
    /// out as the server leaves it out.
    func testPicturesAreListedInTheServersOrderAndEmptyOnesAreLeftOut() {
        let data = AppAttestClientData(
            challenge: "c", documentType: "national_id", documentSource: "camera",
            images: [("frames", Data("frame 0".utf8)), ("selfie", Data("selfie bytes".utf8)),
                     ("back", Data()), ("frames", Data("frame 1".utf8)), ("front", Data("front bytes".utf8)),
                     ("turn", Data("turn bytes".utf8))],
            liveness: nil, mrz: nil
        )
        XCTAssertEqual(data.images.map(\.part), ["front", "selfie", "turn", "frames", "frames"])
        XCTAssertEqual(data.images.map(\.sha256), [
            "12ca2d2a0f3de8303a9ed1af0a808a2e7fc02c76110d0a33c9326a5ed9be8151",
            "8b06c528172be4017758538949201af79b084d4622c255dce115329f6d05494a",
            "f081d92ea91c17e60a943d4f17e5ab16f915404988590cbe718c76006b2c8c54",
            "40db78ae029df9f395c8fcd445f1625e2e7bf22e0bc0dc6182ae62fee82319f0",
            "56f5a971b3594642a6a1c07ed7b8a1467240b578ecdbc8bf8f9189e7a1b219bf"
        ])
    }

    // MARK: What is signed is what is sent

    static func sweep() -> LivenessSweep {
        LivenessSweep(
            straight: LivenessSample(yaw: 0.01, pitch: -0.02, t: 0),
            straightFrame: Data("straight".utf8),
            frames: (0..<3).map {
                LivenessFrame(sector: $0, sample: LivenessSample(yaw: 0.3, pitch: 0.1 * Double($0), t: Double($0 + 1)),
                              jpeg: Data("frame \($0)".utf8))
            },
            duration: 9
        )
    }

    static func submission() throws -> DocumentSubmission {
        let zone = try XCTUnwrap(MRZParser.parse(MRZParserTests.passport(number: "X12345678", nationality: "USA")))
        XCTAssertTrue(zone.isValid)
        var submission = DocumentSubmission(
            documentType: .nationalId, front: Data("front bytes".utf8), back: Data("back bytes".utf8),
            selfie: Data("selfie bytes".utf8), mrz: zone, sweep: sweep()
        )
        submission.source = .photos
        return submission
    }

    /// A multipart body read back, as bytes: every part's name, whether it
    /// is a file, and its value, in order.
    static func parts(of body: Data, boundary: String) -> [(name: String, isFile: Bool, value: Data)] {
        let delimiter = Data("--\(boundary)\r\n".utf8)
        let closing = Data("--\(boundary)--\r\n".utf8)
        let blank = Data("\r\n\r\n".utf8)
        var remaining = body
        if remaining.suffix(closing.count) == closing { remaining = remaining.dropLast(closing.count) }
        var chunks: [Data] = []
        while let start = remaining.range(of: delimiter) {
            let after = remaining[start.upperBound...]
            let next = after.range(of: delimiter)
            chunks.append(Data(after[..<(next?.lowerBound ?? after.endIndex)]))
            remaining = next.map { Data(after[$0.lowerBound...]) } ?? Data()
        }
        return chunks.map { chunk in
            let split = chunk.range(of: blank)!
            let headers = String(decoding: chunk[..<split.lowerBound], as: UTF8.self)
            let value = Data(chunk[split.upperBound...].dropLast(2)) // the part's closing CRLF
            let name = headers.components(separatedBy: "name=\"")[1].components(separatedBy: "\"")[0]
            return (name, headers.contains("filename="), value)
        }
    }

    /// Python's `json.dumps(ensure_ascii=False)` for one string — a second,
    /// independent writer to hold the first one to.
    static func pythonString(_ string: String) -> String {
        var out = "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case _ where scalar.value < 0x20: out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }

    /// The server rebuilds the client data from the form that arrived. So
    /// read the form back exactly as the server would — every text field's
    /// string, every file part's bytes in order — build the client data the
    /// server's way from *that*, and it must be the bytes the app signed.
    func testTheSignedBytesAreRebuiltFromTheFormThatIsSent() throws {
        let submission = try Self.submission()
        let proof = DeviceProof(keyID: "a2V5LWlk", assertion: "YXNzZXJ0aW9u")
        let parts = Self.parts(of: submission.form(boundary: "B", device: proof).encoded(), boundary: "B")

        let fields = Dictionary(parts.filter { !$0.isFile }.map { ($0.name, String(decoding: $0.value, as: UTF8.self)) },
                                uniquingKeysWith: { first, _ in first })
        XCTAssertEqual(fields["app_attest_key_id"], "a2V5LWlk")
        XCTAssertEqual(fields["app_attest_assertion"], "YXNzZXJ0aW9u")
        XCTAssertEqual(fields["document_source"], "photos")
        XCTAssertTrue(fields["mrz"]?.contains("\n") == true, "the zone travels with its line break")

        let files = parts.filter(\.isFile)
        XCTAssertEqual(files.map(\.name), ["front", "back", "selfie", "frames", "frames", "frames"])
        let order = AppAttestClientData.partOrder
        let listed = files.enumerated()
            .sorted { (order.firstIndex(of: $0.element.name)!, $0.offset) < (order.firstIndex(of: $1.element.name)!, $1.offset) }
            .map { #"{"part":"\#($0.element.name)","sha256":"\#(SHA256.hash(data: $0.element.value).map { String(format: "%02x", $0) }.joined())"}"# }
        let server = #"{"challenge":"assert-challenge_7","document_source":"# + Self.pythonString(fields["document_source"] ?? "")
            + #","document_type":"# + Self.pythonString(fields["document_type"] ?? "")
            + #","images":["# + listed.joined(separator: ",") + "]"
            + #","liveness":"# + Self.pythonString(fields["liveness"] ?? "")
            + #","mrz":"# + Self.pythonString(fields["mrz"] ?? "")
            + #","version":1}"#

        let signed = try AppAttestClientData(challenge: "assert-challenge_7", submission: submission).encoded()
        XCTAssertEqual(String(decoding: signed, as: UTF8.self), server)
    }

    /// The legacy three-pose form signs its `turn` picture and its list of
    /// challenges, and a form without a zone signs `""` for it.
    func testTheLegacyFormSignsItsTurnAndItsList() throws {
        let submission = DocumentSubmission(
            documentType: .passport, front: Data("front bytes".utf8), selfie: Data("selfie bytes".utf8),
            turn: Data("turn bytes".utf8), challenges: LivenessChallenge.allCases
        )
        let data = AppAttestClientData(challenge: "c", submission: submission)
        XCTAssertEqual(data.images.map(\.part), ["front", "selfie", "turn"])
        XCTAssertEqual(data.liveness, #"["look_straight","turn_left","turn_right"]"#)
        XCTAssertEqual(data.mrz, "")
        XCTAssertEqual(data.documentSource, "camera")
        XCTAssertTrue(String(decoding: try data.encoded(), as: UTF8.self)
            .contains(#""liveness":"[\"look_straight\",\"turn_left\",\"turn_right\"]""#))
    }

    /// Without a proof the form is exactly what it always was.
    func testAFormWithoutAProofCarriesNoAttestFields() throws {
        let submission = try Self.submission()
        let body = String(decoding: submission.form(boundary: "B").encoded(), as: UTF8.self)
        XCTAssertFalse(body.contains("app_attest"))
        XCTAssertEqual(submission.form(boundary: "B").encoded(), submission.form(boundary: "B", device: nil).encoded())
    }
}

// MARK: - The key's life

final class AppAttestorTests: XCTestCase {

    private var service: FakeAppAttest!
    private var server: AttestServer!
    private var keychain: InMemoryKeychainClient!
    private var analytics: RecordingAnalyticsClient!
    private var clock: AttestClock!
    private var account: String? = "aaaaaaaa-0000-4000-8000-000000000001"

    override func setUp() {
        super.setUp()
        service = FakeAppAttest()
        server = AttestServer()
        keychain = InMemoryKeychainClient()
        analytics = RecordingAnalyticsClient()
        clock = AttestClock()
        account = "aaaaaaaa-0000-4000-8000-000000000001"
    }

    private func makeAttestor(budget: @escaping @Sendable () async -> Void = { await Deadline.sleep(15) }) -> AppAttestor {
        let clock = clock!
        let current = account
        return AppAttestor(
            service: service, network: server.network, tokens: StaticAccessTokenProvider(),
            keychain: keychain, analytics: analytics, account: { current },
            budget: budget, now: { clock.now }
        )
    }

    private func stored(for account: String? = nil) throws -> AppAttestor.KeyRecord? {
        try keychain.load(AppAttestor.keychainKey(for: account ?? self.account!), as: AppAttestor.KeyRecord.self)
    }

    private func requests(_ path: String) -> [APIRequest] {
        server.network.requests.filter { $0.path == path }
    }

    private func attestBody(_ index: Int = 0) throws -> [String: String] {
        let body = try XCTUnwrap(requests("/device/attest")[index].body)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
    }

    private func submission() throws -> DocumentSubmission { try AppAttestClientDataTests.submission() }

    /// The `key_id` the `index`th assertion challenge carried.
    private func challengeKey(_ index: Int) throws -> String? {
        let body = try XCTUnwrap(requests("/device/assert/challenge")[index].body)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])["key_id"]
    }

    private func hash(_ challenge: String) -> Data { Data(SHA256.hash(data: Data(challenge.utf8))) }

    private func attestEvents() -> [[String: String]] {
        analytics.recorded.filter { $0.event == .deviceAttestation }.map(\.properties)
    }

    // MARK: The first submission

    /// A key is made, attested over the SHA-256 of the challenge's UTF-8
    /// bytes, sent to the server; then an assertion challenge, and a
    /// signature over the SHA-256 of exactly the client data.
    func testTheFirstSubmissionMakesAttestsAndSigns() async throws {
        let attestor = makeAttestor()
        let submission = try submission()

        let signed = await attestor.proof(for: submission)
        let proof = try XCTUnwrap(signed)

        XCTAssertEqual(service.generated, ["key-1"])
        XCTAssertEqual(service.attested.map(\.keyId), ["key-1"])
        XCTAssertEqual(service.attested.first?.hash, Data(SHA256.hash(data: Data("attest-challenge_1".utf8))))

        let body = try attestBody()
        XCTAssertEqual(body, [
            "key_id": "key-1",
            "attestation": Data("attestation of key-1".utf8).base64EncodedString(),
            "challenge": "attest-challenge_1"
        ])
        XCTAssertEqual(requests("/device/attest").first?.method, .post)
        XCTAssertEqual(requests("/device/attest").first?.accessToken, "test-access-token")
        XCTAssertEqual(requests("/device/assert/challenge").count, 1)
        XCTAssertEqual(requests("/device/assert/challenge").first?.method, .post)
        XCTAssertNil(requests("/device/attest/challenge").first?.body, "the attestation challenge takes no body")
        XCTAssertEqual(try challengeKey(0), "key-1", "the assertion challenge names the key, so the server can say it let it go")

        let expected = try AppAttestClientData(challenge: "assert-challenge_2", submission: submission).hash()
        XCTAssertEqual(service.asserted.map(\.keyId), ["key-1"])
        XCTAssertEqual(service.asserted.first?.hash, expected)
        XCTAssertEqual(proof, DeviceProof(keyID: "key-1", assertion: Data("assertion by key-1".utf8).base64EncodedString()))

        XCTAssertEqual(try stored(), AppAttestor.KeyRecord(keyId: "key-1", attested: true, refusedAt: nil))
        XCTAssertEqual(attestEvents(), [["step": "attest", "result": "ok"], ["step": "assert", "result": "ok"]])
    }

    /// The key is made once per account: the next submission only asks for
    /// a challenge and signs — in this launch and the next.
    func testTheKeyIsMadeOnceAndKeptAcrossLaunches() async throws {
        _ = await makeAttestor().proof(for: try submission())
        let relaunched = makeAttestor()
        let second = await relaunched.proof(for: try submission())
        _ = await relaunched.proof(for: try submission())

        XCTAssertEqual(second?.keyID, "key-1")
        XCTAssertEqual(service.generated, ["key-1"])
        XCTAssertEqual(requests("/device/attest").count, 1)
        XCTAssertEqual(requests("/device/assert/challenge").count, 3, "a fresh challenge for every submission")
        XCTAssertEqual(service.asserted.count, 3)
    }

    /// Another account on this install gets a key of its own — one key per
    /// account per device, and a key belongs to one account on the server.
    func testAnotherAccountGetsAKeyOfItsOwn() async throws {
        let first = await makeAttestor().proof(for: try submission())
        account = "bbbbbbbb-0000-4000-8000-000000000002"
        let second = await makeAttestor().proof(for: try submission())

        XCTAssertEqual(first?.keyID, "key-1")
        XCTAssertEqual(second?.keyID, "key-2")
        XCTAssertEqual(try stored(for: "aaaaaaaa-0000-4000-8000-000000000001")?.keyId, "key-1")
        XCTAssertEqual(try stored()?.keyId, "key-2")
    }

    /// Readied while the person is at the camera, so the submission only signs.
    func testPreparingAttestsAheadAndTheSubmissionOnlySigns() async throws {
        let attestor = makeAttestor()
        await attestor.prepare()
        XCTAssertEqual(requests("/device/attest").count, 1)
        XCTAssertTrue(service.asserted.isEmpty, "nothing is signed until there is something to sign")

        let proof = await attestor.proof(for: try submission())
        XCTAssertEqual(proof?.keyID, "key-1")
        XCTAssertEqual(service.generated, ["key-1"])
        XCTAssertEqual(requests("/device/attest").count, 1)
    }

    /// However many ask at once, one key is made and attested.
    func testCallersAtTheSameTimeShareOneAttestation() async throws {
        let attestor = makeAttestor()
        let submission = try submission()
        async let a: Void = attestor.prepare()
        async let b = attestor.proof(for: submission)
        async let c: Void = attestor.prepare()
        let proof = await b
        _ = await (a, c)

        XCTAssertEqual(proof?.keyID, "key-1")
        XCTAssertEqual(service.generated, ["key-1"])
        XCTAssertEqual(requests("/device/attest").count, 1)
    }

    // MARK: Never in the way

    /// The simulator, an old phone: nothing is asked of App Attest or the
    /// server, and the submission goes without.
    func testAnUnsupportedDeviceSubmitsWithoutAndAsksNothing() async throws {
        service.isSupported = false
        let attestor = makeAttestor()
        await attestor.prepare()
        let proof = await attestor.proof(for: try submission())

        XCTAssertNil(proof)
        XCTAssertTrue(service.generated.isEmpty)
        XCTAssertTrue(server.network.requests.isEmpty)
        XCTAssertEqual(attestEvents(), [["step": "assert", "result": "unsupported"]])
    }

    func testNobodySignedInSendsNothing() async throws {
        account = nil
        let attestor = makeAttestor()
        await attestor.prepare()
        let proof1 = await attestor.proof(for: try submission())
        XCTAssertNil(proof1)
        XCTAssertTrue(service.generated.isEmpty)
        XCTAssertTrue(server.network.requests.isEmpty)
    }

    /// Apple out of reach: the key is kept and attested later, with the same
    /// key (Apple: "retry … using the same key").
    func testAppleOutOfReachKeepsTheKeyForLater() async throws {
        service.failAttestations(DCError(.serverUnavailable))
        let attestor = makeAttestor()

        let proof2 = await attestor.proof(for: try submission())
        XCTAssertNil(proof2)
        XCTAssertEqual(try stored(), AppAttestor.KeyRecord(keyId: "key-1", attested: false, refusedAt: nil))
        XCTAssertTrue(requests("/device/attest").isEmpty)
        XCTAssertEqual(attestEvents().first, ["step": "attest", "result": "failed", "reason": "dc_4"])

        let later = await attestor.proof(for: try submission())
        XCTAssertEqual(later?.keyID, "key-1")
        XCTAssertEqual(service.generated, ["key-1"], "the same key, not a new one")
        XCTAssertEqual(service.attested.map(\.keyId), ["key-1", "key-1"])
    }

    /// Any other App Attest error: the key is discarded and a new one made
    /// next time (Apple's rule).
    func testAnyOtherAttestationErrorDiscardsTheKey() async throws {
        service.failAttestations(DCError(.invalidInput))
        let attestor = makeAttestor()

        let proof3 = await attestor.proof(for: try submission())
        XCTAssertNil(proof3)
        XCTAssertNil(try stored())

        let next = await attestor.proof(for: try submission())
        XCTAssertEqual(next?.keyID, "key-2")
        XCTAssertEqual(service.generated, ["key-1", "key-2"])
    }

    /// A key the keychain remembers but App Attest no longer knows (the
    /// keychain outlived the key) is replaced at once, not a submission later.
    func testAStoredKeyAppAttestNoLongerKnowsIsReplacedAtOnce() async throws {
        try keychain.save(AppAttestor.KeyRecord(keyId: "old-key", attested: false, refusedAt: nil),
                          for: AppAttestor.keychainKey(for: account!))
        service.failAttestations(DCError(.invalidKey))

        let proof = await makeAttestor().proof(for: try submission())

        XCTAssertEqual(proof?.keyID, "key-1")
        XCTAssertEqual(service.attested.map(\.keyId), ["old-key", "key-1"])
        XCTAssertEqual(try stored()?.keyId, "key-1")
    }

    /// The server refused the attestation (`400 attestation_invalid`): no
    /// assertion, the key goes, and no new key is made on this install for a
    /// day — a genuine phone refused is a disagreement a new key per
    /// submission would not settle.
    func testARefusedAttestationWaitsADayBeforeANewKey() async throws {
        server.answerAttestations(.refused)
        let attestor = makeAttestor()

        let proof4 = await attestor.proof(for: try submission())
        XCTAssertNil(proof4)
        XCTAssertEqual(try stored(), AppAttestor.KeyRecord(keyId: nil, attested: false, refusedAt: clock.now))
        XCTAssertTrue(requests("/device/assert/challenge").isEmpty)
        XCTAssertEqual(attestEvents().first, ["step": "attest", "result": "refused", "reason": "http_400"])

        clock.advance(23 * 3600)
        await attestor.prepare()
        let proof5 = await makeAttestor().proof(for: try submission())
        XCTAssertNil(proof5)
        XCTAssertEqual(service.generated, ["key-1"], "no new key within the day, this launch or the next")
        XCTAssertEqual(requests("/device/attest/challenge").count, 1)

        server.answerAttestations(.created)
        clock.advance(2 * 3600)
        let proof = await makeAttestor().proof(for: try submission())
        XCTAssertEqual(proof?.keyID, "key-2")
    }

    /// `409 key_exists`: already on file, an earlier answer lost on the way
    /// back. The key is used; its assertions tell.
    func testKeyExistsIsTakenAsAttested() async throws {
        server.answerAttestations(.keyExists)
        let proof = await makeAttestor().proof(for: try submission())
        XCTAssertEqual(proof?.keyID, "key-1")
        XCTAssertEqual(try stored()?.attested, true)
    }

    /// No challenge (offline, rate-limited): nothing happened to the key, and
    /// it is attested next time.
    func testNoChallengeKeepsTheKey() async throws {
        server.failChallenges(.api(code: .rateLimited, message: "Too many requests", status: 429))
        let attestor = makeAttestor()
        let proof8 = await attestor.proof(for: try submission())
        XCTAssertNil(proof8)
        XCTAssertEqual(try stored(), AppAttestor.KeyRecord(keyId: "key-1", attested: false, refusedAt: nil))
        XCTAssertTrue(service.attested.isEmpty)

        server.failChallenges(nil)
        let proof9 = await attestor.proof(for: try submission())
        XCTAssertEqual(proof9?.keyID, "key-1")
        XCTAssertEqual(service.generated, ["key-1"])
    }

    /// The assertion challenge did not come: the key is fine and stays.
    func testNoAssertionChallengeSendsNoneAndKeepsTheKey() async throws {
        let attestor = makeAttestor()
        await attestor.prepare()
        server.failChallenges(.transport("offline"))
        let proof10 = await attestor.proof(for: try submission())
        XCTAssertNil(proof10)
        XCTAssertEqual(try stored()?.attested, true)
        XCTAssertEqual(attestEvents().last, ["step": "assert", "result": "failed", "reason": "transport"])
    }

    /// An attested key the Secure Enclave no longer has (a restore): replaced
    /// once, here — made, attested, and this submission still signed.
    func testAnAttestedKeyThatIsGoneIsReplacedOnce() async throws {
        try keychain.save(AppAttestor.KeyRecord(keyId: "restored-key", attested: true, refusedAt: nil),
                          for: AppAttestor.keychainKey(for: account!))
        server.hold("restored-key")
        service.failAssertions(of: "restored-key", with: DCError(.invalidKey))

        let proof = await makeAttestor().proof(for: try submission())

        XCTAssertEqual(proof?.keyID, "key-1")
        XCTAssertEqual(service.asserted.map(\.keyId), ["restored-key", "key-1"])
        XCTAssertEqual(try stored(), AppAttestor.KeyRecord(keyId: "key-1", attested: true, refusedAt: nil))
    }

    /// Only once: a new key that fails too sends none.
    func testAKeyIsReplacedAtMostOncePerSubmission() async throws {
        try keychain.save(AppAttestor.KeyRecord(keyId: "restored-key", attested: true, refusedAt: nil),
                          for: AppAttestor.keychainKey(for: account!))
        server.hold("restored-key")
        service.failAssertions(of: "restored-key", with: DCError(.invalidKey))
        service.failAssertions(of: "key-1", with: DCError(.invalidKey))

        let proof11 = await makeAttestor().proof(for: try submission())
        XCTAssertNil(proof11)
        XCTAssertEqual(service.generated, ["key-1"])
    }

    /// Any other signing failure keeps the key: it is not known to be gone.
    func testAnotherSigningFailureKeepsTheKey() async throws {
        let attestor = makeAttestor()
        await attestor.prepare()
        service.failAssertions(of: "key-1", with: DCError(.unknownSystemFailure))
        let proof12 = await attestor.proof(for: try submission())
        XCTAssertNil(proof12)
        XCTAssertEqual(try stored(), AppAttestor.KeyRecord(keyId: "key-1", attested: true, refusedAt: nil))
        XCTAssertEqual(service.generated, ["key-1"])
    }

    /// Apple slow to answer: the submission waits its budget and goes
    /// without; the attestation carries on by itself and is there next time.
    func testASlowAttestationDoesNotHoldTheSubmission() async throws {
        let gate = Gate()
        service.holdAttestations(at: gate)
        let attestor = makeAttestor(budget: { await Deadline.sleep(0.2) })

        let started = Date()
        let proof = await attestor.proof(for: try submission())
        XCTAssertNil(proof)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "went at the budget, not when Apple answered")
        XCTAssertEqual(attestEvents().last, ["step": "assert", "result": "failed", "reason": "timeout"])

        gate.open()
        await attestor.prepare()
        XCTAssertEqual(try stored(), AppAttestor.KeyRecord(keyId: "key-1", attested: true, refusedAt: nil),
                       "the attestation finished on its own")
        let next = await attestor.proof(for: try submission())
        XCTAssertEqual(next?.keyID, "key-1")
        XCTAssertEqual(service.generated, ["key-1"])
    }

    // MARK: A stale challenge or a lost answer is not a refusal

    /// `400 challenge_stale` — the challenge expired while the phone was
    /// locked, or another device of the account replaced it: asked again at
    /// once with a fresh challenge, the same key, and nothing paused.
    func testAStaleChallengeIsAskedAgainAtOnce() async throws {
        server.answerNextAttestations(.stale)
        let proof = await makeAttestor().proof(for: try submission())

        XCTAssertEqual(proof?.keyID, "key-1")
        XCTAssertEqual(service.generated, ["key-1"], "the same key, attested again")
        XCTAssertEqual(service.attested.map(\.keyId), ["key-1", "key-1"])
        XCTAssertEqual(service.attested.map(\.hash), [hash("attest-challenge_1"), hash("attest-challenge_2")],
                       "a fresh challenge the second time")
        XCTAssertEqual(try attestBody(1)["challenge"], "attest-challenge_2")
        XCTAssertEqual(try stored(), AppAttestor.KeyRecord(keyId: "key-1", attested: true, refusedAt: nil))
        XCTAssertEqual(Array(attestEvents().prefix(2)), [
            ["step": "attest", "result": "again", "reason": "stale"],
            ["step": "attest", "result": "ok"]
        ])
    }

    /// Where Apple will not attest the same key twice, the stale round costs
    /// one new key, made at once — the contract's "else a new one".
    func testAStaleChallengeWhereAppleWillNotAttestTheKeyAgainTakesOneNewKey() async throws {
        service.refuseAttestingTwice()
        server.answerNextAttestations(.stale)
        let proof = await makeAttestor().proof(for: try submission())

        XCTAssertEqual(proof?.keyID, "key-2")
        XCTAssertEqual(service.generated, ["key-1", "key-2"])
        XCTAssertEqual(service.attested.map(\.keyId), ["key-1", "key-1", "key-2"])
        XCTAssertEqual(requests("/device/attest").count, 2)
        XCTAssertEqual(try stored(), AppAttestor.KeyRecord(keyId: "key-2", attested: true, refusedAt: nil),
                       "one key for the account: the new one")
    }

    /// Stale every time: a bounded number of fresh challenges, then the key
    /// is left for next time — no refusal recorded, no day's pause, and the
    /// next try (the clock unmoved) uses the same key.
    func testStaleChallengesAreTriedABoundedNumberOfTimesAndPauseNothing() async throws {
        server.answerAttestations(.stale)
        let attestor = makeAttestor()

        let none = await attestor.proof(for: try submission())
        XCTAssertNil(none)
        XCTAssertEqual(AppAttestor.attestationRounds, 3)
        XCTAssertEqual(requests("/device/attest/challenge").count, AppAttestor.attestationRounds)
        XCTAssertEqual(requests("/device/attest").count, AppAttestor.attestationRounds)
        XCTAssertEqual(try stored(), AppAttestor.KeyRecord(keyId: "key-1", attested: false, refusedAt: nil))
        XCTAssertFalse(attestEvents().contains { $0["result"] == "refused" })

        server.answerAttestations(.created)
        let proof = await attestor.proof(for: try submission())
        XCTAssertEqual(proof?.keyID, "key-1", "at once, not a day later")
        XCTAssertEqual(service.generated, ["key-1"])
    }

    /// Only `attestation_invalid` pauses for a day. A `429`, or a `400` the
    /// app does not know, keeps the key and pauses nothing.
    func testOnlyAGenuineRefusalPausesAttestation() async throws {
        for answer in [AttestServer.AttestAnswer.rateLimited, .otherRefusal] {
            service = FakeAppAttest()
            server = AttestServer()
            keychain = InMemoryKeychainClient()
            server.answerAttestations(answer)
            let attestor = makeAttestor()

            let none = await attestor.proof(for: try submission())
            XCTAssertNil(none, "\(answer)")
            XCTAssertEqual(try stored(), AppAttestor.KeyRecord(keyId: "key-1", attested: false, refusedAt: nil), "\(answer)")
            XCTAssertEqual(requests("/device/attest").count, 1, "not asked again at once: \(answer)")

            server.answerAttestations(.created)
            let proof = await attestor.proof(for: try submission())
            XCTAssertEqual(proof?.keyID, "key-1", "\(answer)")
            XCTAssertEqual(service.generated, ["key-1"], "\(answer)")
        }
    }

    /// The attestation arrived and its answer did not: the server is asked
    /// whether it holds the key, it does, and the key is used — no second
    /// attestation, no second key.
    func testALostAnswerThatArrivedIsFoundOnFile() async throws {
        server.answerNextAttestations(.keptButLost)
        let proof = await makeAttestor().proof(for: try submission())

        XCTAssertEqual(proof?.keyID, "key-1")
        XCTAssertEqual(service.attested.map(\.keyId), ["key-1"], "not attested a second time")
        XCTAssertEqual(requests("/device/attest").count, 1)
        XCTAssertEqual(requests("/device/assert/challenge").count, 2, "asked whether it is on file, then the submission's own")
        XCTAssertEqual(try stored(), AppAttestor.KeyRecord(keyId: "key-1", attested: true, refusedAt: nil))
        XCTAssertEqual(attestEvents(), [
            ["step": "attest", "result": "again", "reason": "transport"],
            ["step": "status", "result": "ok"],
            ["step": "assert", "result": "ok"]
        ])
    }

    /// It never arrived: the server says so, and the same key is attested
    /// again with a fresh challenge.
    func testALostAnswerThatNeverArrivedIsAttestedAgainWithAFreshChallenge() async throws {
        server.answerNextAttestations(.lost)
        let proof = await makeAttestor().proof(for: try submission())

        XCTAssertEqual(proof?.keyID, "key-1")
        XCTAssertEqual(service.generated, ["key-1"])
        XCTAssertEqual(service.attested.map(\.keyId), ["key-1", "key-1"])
        XCTAssertEqual(try attestBody(1)["challenge"], "attest-challenge_2")
        XCTAssertEqual(try stored(), AppAttestor.KeyRecord(keyId: "key-1", attested: true, refusedAt: nil))
        XCTAssertTrue(attestEvents().contains(["step": "status", "result": "forgotten"]))
    }

    /// Lost every time: bounded, the key kept and remembered as unanswered —
    /// no refusal — and attested next time.
    func testAnswersLostEveryTimeKeepTheKeyForNextTime() async throws {
        server.answerAttestations(.lost)
        let none = await makeAttestor().proof(for: try submission())

        XCTAssertNil(none)
        XCTAssertEqual(requests("/device/attest").count, AppAttestor.attestationRounds)
        XCTAssertEqual(service.generated, ["key-1"])
        XCTAssertEqual(try stored(), AppAttestor.KeyRecord(keyId: "key-1", attested: false, refusedAt: nil, unanswered: true))

        server.answerAttestations(.created)
        let proof = await makeAttestor().proof(for: try submission())
        XCTAssertEqual(proof?.keyID, "key-1")
        XCTAssertEqual(service.generated, ["key-1"])
    }

    /// After a relaunch, a key whose answer was lost is asked about before
    /// anything else, and used as it is when the server holds it.
    func testAKeyWhoseAnswerWasLostIsAskedAboutAfterARelaunch() async throws {
        try keychain.save(AppAttestor.KeyRecord(keyId: "sent-key", attested: false, refusedAt: nil, unanswered: true),
                          for: AppAttestor.keychainKey(for: account!))
        server.hold("sent-key")

        let proof = await makeAttestor().proof(for: try submission())

        XCTAssertEqual(proof?.keyID, "sent-key")
        XCTAssertTrue(service.attested.isEmpty)
        XCTAssertTrue(service.generated.isEmpty)
        XCTAssertTrue(requests("/device/attest/challenge").isEmpty)
        XCTAssertEqual(try stored(), AppAttestor.KeyRecord(keyId: "sent-key", attested: true, refusedAt: nil))
    }

    // MARK: A key the server let go

    /// The server let the key go (`404 key_unknown` on the assertion
    /// challenge): nothing is signed with it; it is dropped, a new key is
    /// attested, and this submission is signed with that one.
    func testAKeyTheServerLetGoIsReplacedBeforeSigning() async throws {
        let attestor = makeAttestor()
        _ = await attestor.proof(for: try submission())
        server.letGo("key-1")

        let proof = await attestor.proof(for: try submission())

        XCTAssertEqual(proof?.keyID, "key-2")
        XCTAssertEqual(service.generated, ["key-1", "key-2"])
        XCTAssertEqual(service.asserted.map(\.keyId), ["key-1", "key-2"], "nothing signed with a key the server let go")
        XCTAssertEqual(try (0..<3).map { try challengeKey($0) }, ["key-1", "key-1", "key-2"])
        XCTAssertEqual(try stored(), AppAttestor.KeyRecord(keyId: "key-2", attested: true, refusedAt: nil),
                       "one key for the account: the new one")
        XCTAssertTrue(attestEvents().contains(["step": "status", "result": "forgotten"]))
    }

    /// Opening the flow asks too, once a launch: a key let go is replaced
    /// while the person is at the camera, and the submission only signs.
    func testOpeningTheFlowReplacesAKeyTheServerLetGo() async throws {
        _ = await makeAttestor().proof(for: try submission())
        server.letGo("key-1")

        let relaunched = makeAttestor()
        await relaunched.prepare()
        XCTAssertEqual(service.generated, ["key-1", "key-2"], "replaced ahead of the submission")
        XCTAssertEqual(try stored(), AppAttestor.KeyRecord(keyId: "key-2", attested: true, refusedAt: nil))

        let asked = requests("/device/assert/challenge").count
        let attests = requests("/device/attest").count
        let proof = await relaunched.proof(for: try submission())
        XCTAssertEqual(proof?.keyID, "key-2")
        XCTAssertEqual(requests("/device/assert/challenge").count, asked + 1, "the submission only asks its challenge")
        XCTAssertEqual(requests("/device/attest").count, attests)
    }

    /// A key on file is asked about once a launch, however often the flow
    /// opens; one nobody could answer about is kept and holds nothing up.
    func testTheKeyIsAskedAboutOnceALaunchAndAnUnansweredAskKeepsIt() async throws {
        _ = await makeAttestor().proof(for: try submission())

        let relaunched = makeAttestor()
        let asked = requests("/device/assert/challenge").count
        await relaunched.prepare()
        await relaunched.prepare()
        XCTAssertEqual(requests("/device/assert/challenge").count, asked + 1)
        XCTAssertEqual(service.generated, ["key-1"])

        server.failChallenges(.transport("offline"))
        let offline = makeAttestor()
        await offline.prepare()
        XCTAssertEqual(try stored(), AppAttestor.KeyRecord(keyId: "key-1", attested: true, refusedAt: nil))
        XCTAssertEqual(attestEvents().last, ["step": "status", "result": "failed", "reason": "transport"])
        server.failChallenges(nil)
        let proof = await offline.proof(for: try submission())
        XCTAssertEqual(proof?.keyID, "key-1")
    }

    /// Once a submission: a server that holds no key sees one replacement,
    /// and the submission goes without.
    func testAKeyIsReplacedAtMostOnceWhenTheServerKeepsLettingGo() async throws {
        server.forgetEveryKey()
        let proof = await makeAttestor().proof(for: try submission())

        XCTAssertNil(proof)
        XCTAssertEqual(service.generated, ["key-1", "key-2"])
        XCTAssertTrue(service.asserted.isEmpty)
        XCTAssertNil(try stored())
        XCTAssertEqual(attestEvents().last, ["step": "assert", "result": "failed", "reason": "key_unknown"])
    }

    /// The server's App Attest answers are read by their codes.
    func testTheServersAppAttestCodesAreRead() {
        func read(_ status: Int, _ body: String) -> APIError {
            URLSessionNetworkClient.makeError(status: status, data: Data(body.utf8))
        }
        XCTAssertEqual(
            read(400, #"{"detail": {"code": "challenge_stale", "message": "Ask for a new challenge", "reason": "challenge_expired"}}"#),
            .api(code: .challengeStale, message: "Ask for a new challenge", status: 400))
        XCTAssertEqual(
            read(400, #"{"detail": {"code": "attestation_invalid", "message": "The device could not be attested", "reason": "nonce"}}"#),
            .api(code: .attestationInvalid, message: "The device could not be attested", status: 400))
        XCTAssertEqual(
            read(404, #"{"detail": {"code": "key_unknown", "message": "That key is not on file for this account"}}"#),
            .api(code: .keyUnknown, message: "That key is not on file for this account", status: 404))
        XCTAssertEqual(
            read(409, #"{"detail": {"code": "key_exists", "message": "That key is already attested"}}"#),
            .api(code: .keyExists, message: "That key is already attested", status: 409))
    }

    /// Analytics carry outcomes only: never a key, a challenge or anything
    /// about the document.
    func testAnalyticsCarryOutcomesOnly() async throws {
        server.answerAttestations(.lost)
        _ = await makeAttestor().proof(for: try submission())
        server.answerAttestations(.created)
        _ = await makeAttestor().proof(for: try submission())

        XCTAssertFalse(attestEvents().isEmpty)
        for properties in attestEvents() {
            XCTAssertTrue(Set(properties.keys).isSubset(of: ["step", "result", "reason"]), "\(properties)")
            for value in properties.values {
                XCTAssertFalse(value.contains("key-") || value.contains("challenge"), value)
            }
        }
    }
}

// MARK: - The submission

final class AttestedSubmissionTests: XCTestCase {

    private func form(of request: APIRequest) throws -> [String: String] {
        let boundary = try XCTUnwrap(request.contentType?.components(separatedBy: "boundary=").last)
        let parts = AppAttestClientDataTests.parts(of: try XCTUnwrap(request.body), boundary: boundary)
        return Dictionary(parts.filter { !$0.isFile }.map { ($0.name, String(decoding: $0.value, as: UTF8.self)) },
                          uniquingKeysWith: { first, _ in first })
    }

    /// The submission carries the key's id and the assertion, and the
    /// assertion is over the client data of exactly the form that went.
    func testTheSubmissionCarriesTheKeyAndTheAssertion() async throws {
        let server = AttestServer()
        let fake = FakeAppAttest()
        let analytics = RecordingAnalyticsClient()
        let attestor = AppAttestor(service: fake, network: server.network, tokens: StaticAccessTokenProvider(),
                                   keychain: InMemoryKeychainClient(), analytics: analytics, account: { "account-1" })
        let service = VerificationService(network: server.network, tokens: StaticAccessTokenProvider(),
                                          analytics: analytics, attestor: attestor)
        let submission = try AppAttestClientDataTests.submission()

        let documentCase = try await service.submitDocument(submission)

        XCTAssertEqual(documentCase.id, "case-1")
        let paths = server.network.requests.map(\.path)
        XCTAssertEqual(paths, ["/device/attest/challenge", "/device/attest", "/device/assert/challenge", "/verification/document"],
                       "the assertion's challenge is asked for right before the submission")
        let sent = try XCTUnwrap(server.network.requests.last)
        let fields = try form(of: sent)
        XCTAssertEqual(fields["app_attest_key_id"], "key-1")
        XCTAssertEqual(fields["app_attest_assertion"], Data("assertion by key-1".utf8).base64EncodedString())
        XCTAssertEqual(fake.asserted.first?.hash,
                       try AppAttestClientData(challenge: "assert-challenge_2", submission: submission).hash())
        XCTAssertEqual(sent.body, APIRequest.multipart(
            "/verification/document", method: .post,
            form: submission.form(boundary: try XCTUnwrap(sent.contentType?.components(separatedBy: "boundary=").last),
                                  device: DeviceProof(keyID: "key-1", assertion: Data("assertion by key-1".utf8).base64EncodedString()))
        ).body, "the pictures that went are the pictures that were signed")
        XCTAssertTrue(analytics.events.contains(.documentSubmitted))
    }

    /// Whatever App Attest does, the submission goes, as it always went.
    func testASubmissionIsNeverRefusedOverTheDevice() async throws {
        let server = AttestServer()
        server.answerAttestations(.refused)
        let attestor = AppAttestor(service: FakeAppAttest(), network: server.network, tokens: StaticAccessTokenProvider(),
                                   keychain: InMemoryKeychainClient(), analytics: RecordingAnalyticsClient(),
                                   account: { "account-1" })
        let service = VerificationService(network: server.network, tokens: StaticAccessTokenProvider(),
                                          analytics: RecordingAnalyticsClient(), attestor: attestor)

        let documentCase = try await service.submitDocument(try AppAttestClientDataTests.submission())

        XCTAssertEqual(documentCase.status, .submitted)
        let fields = try form(of: try XCTUnwrap(server.network.requests.last))
        XCTAssertNil(fields["app_attest_key_id"])
        XCTAssertNil(fields["app_attest_assertion"])
        XCTAssertEqual(fields["document_type"], "national_id")
    }

    /// A service without an attestor — every build before this one, the
    /// mocks — sends the form it always sent.
    func testWithoutAnAttestorTheFormIsUnchanged() async throws {
        let server = AttestServer()
        let service = VerificationService(network: server.network, tokens: StaticAccessTokenProvider(),
                                          analytics: RecordingAnalyticsClient())
        _ = try await service.submitDocument(try AppAttestClientDataTests.submission())
        await service.prepareDeviceAttestation()
        XCTAssertEqual(server.network.requests.map(\.path), ["/verification/document"])
        XCTAssertNil(try form(of: try XCTUnwrap(server.network.requests.last))["app_attest_key_id"])
    }

    /// The flow readies the key through the service.
    @MainActor
    func testTheFlowReadiesTheKey() async throws {
        let server = AttestServer()
        let fake = FakeAppAttest()
        let attestor = AppAttestor(service: fake, network: server.network, tokens: StaticAccessTokenProvider(),
                                   keychain: InMemoryKeychainClient(), analytics: RecordingAnalyticsClient(),
                                   account: { "account-1" })
        let service = VerificationService(network: server.network, tokens: StaticAccessTokenProvider(),
                                          analytics: RecordingAnalyticsClient(), attestor: attestor)
        let viewModel = DocumentVerificationViewModel(service: service, analytics: RecordingAnalyticsClient(),
                                                      declaredDateOfBirth: "1990-01-01")
        await viewModel.prepareDevice()
        XCTAssertEqual(fake.generated, ["key-1"])
        XCTAssertEqual(server.network.requests.map(\.path), ["/device/attest/challenge", "/device/attest"])
    }
}

// MARK: - Signing

/// The entitlement Xcode Cloud signs: development in Debug, production in
/// Release. Read from the checked-out source.
final class AppAttestEntitlementTests: XCTestCase {

    private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    func testTheEntitlementIsDevelopmentInDebugAndProductionInRelease() throws {
        let entitlementsURL = root.appendingPathComponent("Sila/Resources/Sila.entitlements")
        guard FileManager.default.fileExists(atPath: entitlementsURL.path) else {
            throw XCTSkip("source tree not reachable from this machine")
        }
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: Data(contentsOf: entitlementsURL), format: nil) as? [String: Any]
        )
        XCTAssertEqual(plist["com.apple.developer.devicecheck.appattest-environment"] as? String, "$(APP_ATTEST_ENVIRONMENT)")

        let spec = try String(contentsOf: root.appendingPathComponent("project.yml"), encoding: .utf8)
        let configs = try XCTUnwrap(spec.components(separatedBy: "      configs:\n").dropFirst().first)
        XCTAssertTrue(configs.hasPrefix("""
                Debug:
                  APP_ATTEST_ENVIRONMENT: development
                Release:
                  APP_ATTEST_ENVIRONMENT: production
        """), configs)
    }
}
