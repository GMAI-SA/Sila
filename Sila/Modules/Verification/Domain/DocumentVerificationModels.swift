import Foundation

// MARK: - What the person shows

/// The kinds of document the wall accepts on the document route.
public enum DocumentType: String, CaseIterable, Identifiable, Sendable, Equatable {
    case passport
    case nationalId = "national_id"
    case residencePermit = "residence_permit"

    public var id: String { rawValue }

    /// The `document_type` form field.
    public var wireValue: String { rawValue }

    /// Whether the back of the document is photographed as well. A passport's
    /// data page is one side; cards carry information on both.
    public var hasBack: Bool { self != .passport }

    public var title: String {
        switch self {
        case .passport: return L10n.t("document.type.passport.title")
        case .nationalId: return L10n.t("document.type.nationalId.title")
        case .residencePermit: return L10n.t("document.type.residencePermit.title")
        }
    }

    public var detail: String {
        switch self {
        case .passport: return L10n.t("document.type.passport.detail")
        case .nationalId: return L10n.t("document.type.nationalId.detail")
        case .residencePermit: return L10n.t("document.type.residencePermit.detail")
        }
    }

    public var icon: String {
        switch self {
        case .passport: return "book.closed.fill"
        case .nationalId: return "person.text.rectangle.fill"
        case .residencePermit: return "rectangle.and.text.magnifyingglass"
        }
    }
}

/// One step of the selfie sequence. The order is the order the person is
/// asked; the server wants all three reported before it records the
/// sequence as passed.
public enum LivenessChallenge: String, CaseIterable, Sendable, Equatable {
    case lookStraight = "look_straight"
    case turnLeft = "turn_left"
    case turnRight = "turn_right"

    /// The value reported in the `liveness` form field.
    public var wireValue: String { rawValue }

    /// What the person is asked to do.
    public var instruction: String {
        switch self {
        case .lookStraight: return L10n.t("document.liveness.lookStraight")
        case .turnLeft: return L10n.t("document.liveness.turnLeft")
        case .turnRight: return L10n.t("document.liveness.turnRight")
        }
    }
}

// MARK: - What goes over the wire

/// Everything one submission carries, assembled by the flow and encoded once.
///
/// Every image is JPEG data the flow produced itself from the camera — never a
/// file the person picked, so the "photo of a document" is at least a photo
/// this app took. The zone text travels only when its check digits verified
/// on device; an invalid zone is refused before it gets here.
public struct DocumentSubmission: Equatable, Sendable {

    public let documentType: DocumentType
    public let front: Data
    public let back: Data?
    public let selfie: Data
    public let turn: Data?
    public let mrz: MRZ?
    public let challenges: [LivenessChallenge]

    public init(
        documentType: DocumentType,
        front: Data,
        back: Data? = nil,
        selfie: Data,
        turn: Data? = nil,
        mrz: MRZ? = nil,
        challenges: [LivenessChallenge] = []
    ) {
        self.documentType = documentType
        self.front = front
        self.back = back
        self.selfie = selfie
        self.turn = turn
        self.mrz = mrz
        self.challenges = challenges
    }

    /// The server's pre-decode limit per image, mirrored so an oversized
    /// capture is shrunk here rather than refused after uploading.
    public static let maximumBytesPerImage = 5 * 1024 * 1024

    /// The multipart body for `POST /verification/document`.
    /// - Parameter boundary: Injectable so tests can assert on exact bytes.
    public func form(boundary: String? = nil) -> MultipartFormData {
        var form = boundary.map { MultipartFormData(boundary: $0) } ?? MultipartFormData()
        form.appendField(documentType.wireValue, name: "document_type")
        if let mrz, mrz.isValid {
            form.appendField(mrz.text, name: "mrz")
        }
        if !challenges.isEmpty {
            let list = challenges.map(\.wireValue).map { "\"\($0)\"" }.joined(separator: ",")
            form.appendField("[\(list)]", name: "liveness")
        }
        form.appendFile(front, name: "front", filename: "front.jpg", mimeType: "image/jpeg")
        if let back {
            form.appendFile(back, name: "back", filename: "back.jpg", mimeType: "image/jpeg")
        }
        form.appendFile(selfie, name: "selfie", filename: "selfie.jpg", mimeType: "image/jpeg")
        if let turn {
            form.appendFile(turn, name: "turn", filename: "turn.jpg", mimeType: "image/jpeg")
        }
        return form
    }
}

// MARK: - What comes back

/// Where a submission stands.
public enum DocumentCaseStatus: String, Codable, Equatable, Sendable {
    /// Waiting for a reviewer.
    case submitted
    /// The badge is on the account.
    case approved
    /// Declined, with a reason the wall shows.
    case rejected

    /// Unknown future values decode as ``submitted`` — "still waiting" is the
    /// safe reading of a status this build does not know.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = DocumentCaseStatus(rawValue: raw) ?? .submitted
    }
}

/// `POST /verification/document` and `GET /verification/document`.
///
/// Carries nothing read off the document except the nationality the badge
/// will show. The document number, the name, the birth date never come back.
public struct DocumentCase: Decodable, Equatable, Sendable {

    public let id: String
    public let status: DocumentCaseStatus
    public let documentType: String
    /// ISO alpha-2 read from the zone, or `nil` when there was no readable zone
    /// (a reviewer reads the document by eye instead).
    public let nationality: String?
    public let mrzValid: Bool
    public let livenessPassed: Bool
    public let submittedAt: Date?
    public let reviewedAt: Date?
    public let rejectionReason: String?
    /// The account's overall stage after this call.
    public let verificationStatus: VerificationStatus?

    public init(
        id: String,
        status: DocumentCaseStatus,
        documentType: String,
        nationality: String? = nil,
        mrzValid: Bool = false,
        livenessPassed: Bool = false,
        submittedAt: Date? = nil,
        reviewedAt: Date? = nil,
        rejectionReason: String? = nil,
        verificationStatus: VerificationStatus? = nil
    ) {
        self.id = id
        self.status = status
        self.documentType = documentType
        self.nationality = nationality
        self.mrzValid = mrzValid
        self.livenessPassed = livenessPassed
        self.submittedAt = submittedAt
        self.reviewedAt = reviewedAt
        self.rejectionReason = rejectionReason
        self.verificationStatus = verificationStatus
    }

    private enum CodingKeys: String, CodingKey {
        case id, status, documentType, nationality, mrzValid, livenessPassed
        case submittedAt, reviewedAt, rejectionReason, verificationStatus
    }

    /// Tolerant decode: `id` and `status` are load-bearing; everything else
    /// degrades to absent rather than failing the flow.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        status = (try? container.decode(DocumentCaseStatus.self, forKey: .status)) ?? .submitted
        documentType = (try? container.decode(String.self, forKey: .documentType)) ?? ""
        nationality = CountryCode.normalised(try? container.decodeIfPresent(String.self, forKey: .nationality))
        mrzValid = (try? container.decode(Bool.self, forKey: .mrzValid)) ?? false
        livenessPassed = (try? container.decode(Bool.self, forKey: .livenessPassed)) ?? false
        submittedAt = try? container.decodeIfPresent(Date.self, forKey: .submittedAt)
        reviewedAt = try? container.decodeIfPresent(Date.self, forKey: .reviewedAt)
        rejectionReason = (try? container.decodeIfPresent(String.self, forKey: .rejectionReason)) ?? nil
        verificationStatus = try? container.decodeIfPresent(VerificationStatus.self, forKey: .verificationStatus)
    }
}
