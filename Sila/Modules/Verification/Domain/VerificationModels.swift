import Foundation

// MARK: - National ID input

/// Validates what the person typed before it is allowed anywhere near the wire.
///
/// A Saudi National ID or Iqama is exactly ten digits and starts with `1`
/// (citizen) or `2` (resident). Arabic-Indic digits are normalised rather than
/// rejected — the keyboard is a number pad, but paste is paste.
///
/// The number itself is treated as a secret: it is sent once to
/// `POST /verification/nafath/start` and never stored, logged, echoed into an
/// error message, or attached to an analytics event.
public enum NationalID {

    /// The exact length of a National ID / Iqama number.
    public static let length = 10

    /// The digits, with whitespace stripped and Arabic-Indic digits mapped to
    /// Western — the same number, however it was typed.
    public static func normalised(_ raw: String) -> String {
        var digits = ""
        for scalar in raw.unicodeScalars {
            switch scalar.value {
            case 0x30...0x39:               // 0-9
                digits.unicodeScalars.append(scalar)
            case 0x0660...0x0669:           // ٠-٩ (Arabic-Indic)
                digits.append(String(scalar.value - 0x0660))
            case 0x06F0...0x06F9:           // ۰-۹ (Extended Arabic-Indic)
                digits.append(String(scalar.value - 0x06F0))
            default:
                continue
            }
        }
        return digits
    }

    /// `true` when ``normalised(_:)`` yields ten digits starting with 1 or 2.
    public static func isValid(_ raw: String) -> Bool {
        let digits = normalised(raw)
        guard digits.count == length else { return false }
        return digits.first == "1" || digits.first == "2"
    }
}

// MARK: - Wire shapes

/// Result of `POST /verification/nafath/start`.
///
/// Carries everything the waiting screen needs: which request to poll, the
/// two-digit number the person must tap **in the Nafath app**, and when the
/// request stops being worth polling.
public struct NafathStart: Decodable, Equatable, Sendable {

    /// Server-side id of the Nafath request — the path component of the poll.
    public let requestId: String
    /// The number the person must find and tap in the Nafath app. Kept as the
    /// string the server sent so a leading zero survives — "07" is "07", not 7.
    public let randomNumber: String
    /// When the request lapses. Polling past this point answers `expired`.
    public let expiresAt: Date
    /// Which identity provider issued the request (`"nafath"`).
    public let provider: String?

    public init(requestId: String, randomNumber: String, expiresAt: Date, provider: String? = nil) {
        self.requestId = requestId
        self.randomNumber = randomNumber
        self.expiresAt = expiresAt
        self.provider = provider
    }

    private enum CodingKeys: String, CodingKey {
        case requestId, randomNumber, expiresAt, provider
    }

    /// Tolerant decode: `random_number` may arrive as a string or a bare int,
    /// and neither should take the whole flow down.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        requestId = try container.decode(String.self, forKey: .requestId)
        if let text = try? container.decode(String.self, forKey: .randomNumber) {
            randomNumber = text
        } else if let number = try? container.decode(Int.self, forKey: .randomNumber) {
            randomNumber = String(number)
        } else {
            randomNumber = ""
        }
        expiresAt = try container.decode(Date.self, forKey: .expiresAt)
        provider = try? container.decodeIfPresent(String.self, forKey: .provider)
    }
}

/// Where one Nafath request currently stands, as `GET
/// /verification/nafath/{request_id}` reports it.
public enum NafathRequestStatus: String, Codable, Equatable, Sendable {
    /// Nafath has not answered yet — keep polling.
    case pending
    /// The person tapped the right number; the account is verified.
    case approved
    /// Nafath declined the request.
    case rejected
    /// The request lapsed before Nafath answered.
    case expired

    /// Unknown future values decode as ``pending`` — the poll loop is bounded
    /// by `expires_at`, so an unrecognised status waits rather than fails.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = NafathRequestStatus(rawValue: raw) ?? .pending
    }

    /// `true` once polling should stop.
    public var isTerminal: Bool { self != .pending }
}

/// Result of one poll of `GET /verification/nafath/{request_id}`.
public struct NafathPoll: Decodable, Equatable, Sendable {

    /// The request's state.
    public let status: NafathRequestStatus
    /// The account's overall verification stage after this poll.
    public let verificationStatus: VerificationStatus?
    /// The country the verified identity carries — set on approval.
    public let countryCode: String?
    /// Why the request was rejected, when it was and the server said.
    public let rejectionReason: String?

    public init(
        status: NafathRequestStatus,
        verificationStatus: VerificationStatus? = nil,
        countryCode: String? = nil,
        rejectionReason: String? = nil
    ) {
        self.status = status
        self.verificationStatus = verificationStatus
        self.countryCode = countryCode
        self.rejectionReason = rejectionReason
    }

    private enum CodingKeys: String, CodingKey {
        case status, verificationStatus, countryCode, rejectionReason
    }

    /// Tolerant decode: only `status` is load-bearing.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = (try? container.decode(NafathRequestStatus.self, forKey: .status)) ?? .pending
        verificationStatus = try? container.decodeIfPresent(VerificationStatus.self, forKey: .verificationStatus)
        countryCode = (try? container.decodeIfPresent(String.self, forKey: .countryCode)) ?? nil
        rejectionReason = (try? container.decodeIfPresent(String.self, forKey: .rejectionReason)) ?? nil
    }
}

// MARK: - Request bodies

/// The `POST /verification/nafath/start` body. The one and only place the
/// national ID exists outside the text field.
struct NafathStartBody: Encodable {
    let nationalId: String
}
