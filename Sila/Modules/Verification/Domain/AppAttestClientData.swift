import CryptoKit
import Foundation

/// What a document submission's App Attest assertion signs (contract v32 §4).
///
/// The server never receives these bytes: it **rebuilds** them from the
/// request as it arrived — the account's latest assertion challenge, the
/// form's own strings exactly as sent, and the SHA-256 of every uploaded
/// picture — and checks the signature against them. So they have to be
/// exactly the server's bytes: JSON with the keys sorted, no whitespace, `/`
/// not escaped, UTF-8 as is, every string the one the form carries (`""` for
/// a field the form does not carry — never `null`, never a missing key).
///
/// Change one byte of one picture, the order of two frames, the trace, the
/// zone, the document's type or source, and the signature no longer matches:
/// that is the point. Built from ``DocumentSubmission/textFields`` and
/// ``DocumentSubmission/imageParts``, the same values the form is built from.
public struct AppAttestClientData: Encodable, Equatable, Sendable {

    /// One uploaded picture: its form field's name and the SHA-256 of its
    /// bytes, in lower-case hex.
    public struct Image: Encodable, Equatable, Sendable {
        public let part: String
        public let sha256: String

        public init(part: String, sha256: String) {
            self.part = part
            self.sha256 = sha256
        }
    }

    /// The version of this layout the server expects.
    public static let currentVersion = 1

    /// The order the server lists pictures in (`app_attest.IMAGE_PARTS`):
    /// every `frames` part comes last, in the order sent.
    public static let partOrder = ["front", "back", "selfie", "turn", "frames"]

    public let challenge: String
    public let documentSource: String
    public let documentType: String
    public let images: [Image]
    public let liveness: String
    public let mrz: String
    public let version: Int

    /// Spelled out rather than derived: these names are the wire.
    private enum CodingKeys: String, CodingKey {
        case challenge
        case documentSource = "document_source"
        case documentType = "document_type"
        case images
        case liveness
        case mrz
        case version
    }

    /// The server's own builder, field for field
    /// (`app_attest.submission_client_data`).
    ///
    /// - Parameters:
    ///   - challenge: From `POST /device/assert/challenge`, exactly as returned.
    ///   - images: Every picture as uploaded, part name and bytes. A part
    ///     sent empty is left out, as the server leaves it out; the rest are
    ///     listed in ``partOrder``, frames in the order given.
    ///   - documentType, documentSource, liveness, mrz: The form's strings
    ///     exactly as sent, or `nil` for a field not sent.
    public init(
        challenge: String,
        documentType: String?,
        documentSource: String?,
        images: [(part: String, bytes: Data)],
        liveness: String?,
        mrz: String?
    ) {
        self.challenge = challenge
        self.documentType = documentType ?? ""
        self.documentSource = documentSource ?? ""
        self.liveness = liveness ?? ""
        self.mrz = mrz ?? ""
        self.version = Self.currentVersion
        let rank = { (part: String) in Self.partOrder.firstIndex(of: part) ?? Self.partOrder.count }
        self.images = images.enumerated()
            .filter { !$0.element.bytes.isEmpty }
            .sorted { (rank($0.element.part), $0.offset) < (rank($1.element.part), $1.offset) }
            .map { Image(part: $0.element.part, sha256: Self.hex(SHA256.hash(data: $0.element.bytes))) }
    }

    /// The client data of `submission`, over the strings and bytes its form
    /// sends.
    public init(challenge: String, submission: DocumentSubmission) {
        self.init(
            challenge: challenge,
            documentType: submission.fieldValue("document_type"),
            documentSource: submission.fieldValue("document_source"),
            images: submission.imageParts.map { (part: $0.name, bytes: $0.data) },
            liveness: submission.fieldValue("liveness"),
            mrz: submission.fieldValue("mrz")
        )
    }

    /// The canonical bytes: sorted keys, no whitespace, slashes as they are.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// `SHA256(clientData)` — what `generateAssertion` is handed.
    public func hash() throws -> Data {
        Data(SHA256.hash(data: try encoded()))
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// The two form fields that carry a submission's App Attest assertion
/// (`app_attest_key_id`, `app_attest_assertion`).
public struct DeviceProof: Equatable, Sendable {
    /// The attested key's id, as `generateKey` returned it (base64).
    public let keyID: String
    /// The assertion object, base64.
    public let assertion: String

    public init(keyID: String, assertion: String) {
        self.keyID = keyID
        self.assertion = assertion
    }
}
