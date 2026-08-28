import Foundation

// MARK: - The account

/// Everything `GET /me/account` holds about the person (contract v5).
///
/// Two absences here are deliberate and load-bearing.
///
/// **There is no `phoneVerified`.** The wire carries `phone_verified`, and it is
/// always `false` because this deployment has no SMS provider — nothing about a
/// typed-in number proves anybody holds that line. Decoding it into a property
/// would put a boolean on the model that a future view could bind a checkmark
/// to. On a platform whose entire premise is *proven* identity, an unverified
/// number rendered like a verified one is not a cosmetic mistake, so the field
/// is read off the wire and dropped rather than stored. See ``PhoneNumber``.
///
/// **``avatarPath`` is not a `URL`.** The server sends a root-relative path
/// (`/api/v1/media/avatars/…`), which decodes into a `URL` no image loader can
/// fetch. It is kept as the string the server sent and resolved against the API
/// origin at render time by ``avatarURL``.
public struct Account: Equatable, Sendable, Decodable, Identifiable {

    public let id: UUID
    /// The address that signs in. Changed only through the two-step flow.
    public let email: String
    /// Unique lowercase handle, `[a-z0-9_]{3,20}`.
    public let handle: String?
    /// Chosen name, or `nil`.
    public let displayName: String?
    /// Free text, up to ``AccountLimits/maximumBioLength`` characters.
    public let bio: String?
    /// Root-relative avatar path exactly as stored, or `nil`.
    public let avatarPath: String?
    /// Contact number in E.164, or `nil`. **Never verified** — see the type doc.
    public let phone: String?
    /// The country-verified flag, or `nil`. Written only by verification.
    public let countryCode: String?
    /// Identity-verification stage.
    public let verificationStatus: VerificationStatus
    /// When deletion was requested, or `nil` when none is pending.
    public let deletionRequestedAt: Date?
    /// When the data is destroyed for good, or `nil`.
    public let purgeAfter: Date?

    /// Creates an account record.
    public init(
        id: UUID,
        email: String,
        handle: String? = nil,
        displayName: String? = nil,
        bio: String? = nil,
        avatarPath: String? = nil,
        phone: String? = nil,
        countryCode: String? = nil,
        verificationStatus: VerificationStatus = .unstarted,
        deletionRequestedAt: Date? = nil,
        purgeAfter: Date? = nil
    ) {
        self.id = id
        self.email = email
        self.handle = handle
        self.displayName = displayName
        self.bio = bio
        self.avatarPath = avatarPath
        self.phone = phone
        self.countryCode = CountryCode.normalised(countryCode)
        self.verificationStatus = verificationStatus
        self.deletionRequestedAt = deletionRequestedAt
        self.purgeAfter = purgeAfter
    }

    /// Explicit keys are mandatory because ``init(from:)`` is custom; the raw
    /// values are the camel-cased forms `.convertFromSnakeCase` produces.
    ///
    /// `phone_verified` is intentionally absent — see the type documentation.
    private enum CodingKeys: String, CodingKey {
        case id, email, handle, displayName, bio, phone, countryCode, verificationStatus
        case avatarPath = "avatarUrl"
        case deletionRequestedAt, purgeAfter
    }

    /// Tolerant decoder: a settings screen that refuses to open because one
    /// optional field is malformed is strictly worse than one that opens with
    /// that field blank.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let uuid = try? container.decode(UUID.self, forKey: .id) {
            id = uuid
        } else {
            id = UUID(uuidString: (try? container.decode(String.self, forKey: .id)) ?? "") ?? UUID()
        }
        email = (try? container.decode(String.self, forKey: .email)) ?? ""
        handle = Account.nonEmpty(try? container.decodeIfPresent(String.self, forKey: .handle))
        displayName = Account.nonEmpty(try? container.decodeIfPresent(String.self, forKey: .displayName))
        bio = Account.nonEmpty(try? container.decodeIfPresent(String.self, forKey: .bio))
        avatarPath = Account.nonEmpty(try? container.decodeIfPresent(String.self, forKey: .avatarPath))
        phone = Account.nonEmpty(try? container.decodeIfPresent(String.self, forKey: .phone))
        countryCode = CountryCode.normalised(
            (try? container.decodeIfPresent(String.self, forKey: .countryCode)) ?? nil
        )
        verificationStatus =
            (try? container.decode(VerificationStatus.self, forKey: .verificationStatus)) ?? .unstarted
        deletionRequestedAt = (try? container.decodeIfPresent(Date.self, forKey: .deletionRequestedAt)) ?? nil
        purgeAfter = (try? container.decodeIfPresent(Date.self, forKey: .purgeAfter)) ?? nil
    }

    private static func nonEmpty(_ value: String??) -> String? {
        guard let inner = value ?? nil else { return nil }
        return inner.isEmpty ? nil : inner
    }

    // MARK: Derived

    /// The avatar as something that can actually be loaded, or `nil`.
    ///
    /// ``avatarPath`` is root-relative, so it is resolved against the API's
    /// origin rather than handed to an image view as-is.
    public var avatarURL: URL? { AppConfig.mediaURL(avatarPath) }

    /// The handle with its `@`, when there is one.
    public var atHandle: String? {
        guard let handle, !handle.isEmpty else { return nil }
        return "@\(handle)"
    }

    /// Two-letter monogram for ``SLAvatar``.
    public var initials: String {
        if let displayName, !displayName.isEmpty {
            let letters = displayName.split(separator: " ").prefix(2).compactMap(\.first)
            if !letters.isEmpty { return String(letters).uppercased() }
        }
        return String(email.prefix(2)).uppercased()
    }

    /// `true` while the account is inside its deletion grace period.
    ///
    /// Derived from either timestamp, not from both: `GET /me/account` is one of
    /// only two endpoints a deactivated account may call, and treating a half-set
    /// pair as "not deleting" would strand somebody outside the one screen that
    /// can undo it.
    public var isPendingDeletion: Bool { deletionRequestedAt != nil || purgeAfter != nil }

    /// Whole days left before the purge, floored at zero, or `nil`.
    /// - Parameter now: Injected so the calculation is testable.
    public func daysUntilPurge(now: Date = Date()) -> Int? {
        guard let purgeAfter else { return nil }
        let seconds = purgeAfter.timeIntervalSince(now)
        guard seconds > 0 else { return 0 }
        return Int((seconds / 86_400).rounded(.down))
    }
}

/// Limits the server enforces, mirrored so the client can say "too long" before
/// spending a round trip on a rejection.
public enum AccountLimits {
    /// `display_name` max length.
    public static let maximumDisplayNameLength = 80
    /// `handle` length range, on top of the `[a-z0-9_]` rule.
    public static let handleLengthRange = 3...20
    /// `bio` max length.
    public static let maximumBioLength = 160
    /// Minimum accepted by `POST /me/password`.
    public static let minimumPasswordLength = 8
    /// Maximum accepted by `POST /me/password`.
    public static let maximumPasswordLength = 128
}

// MARK: - Profile edits

/// The `PATCH /me/profile` body.
///
/// Every field is optional and the synthesised encoder omits the `nil`s, which
/// is what makes the call a partial update: a field left out is left alone.
public struct ProfileUpdate: Encodable, Equatable, Sendable {

    /// New display name, or `nil` to leave it alone.
    public var displayName: String?
    /// New handle, or `nil` to leave it alone.
    public var handle: String?
    /// New bio, or `nil` to leave it alone.
    public var bio: String?

    public init(displayName: String? = nil, handle: String? = nil, bio: String? = nil) {
        self.displayName = displayName
        self.handle = handle
        self.bio = bio
    }

    /// `true` when the body would change nothing.
    public var isEmpty: Bool { displayName == nil && handle == nil && bio == nil }

    /// The fields of `edited` that differ from `stored`.
    ///
    /// Only differences are sent. The server treats an empty string as "clear
    /// it", so a cleared field is sent as `""` rather than omitted — omitting it
    /// would silently keep the old value the user just deleted.
    /// - Parameters:
    ///   - edited: What the form currently holds, already trimmed.
    ///   - stored: The last state the server confirmed.
    public static func difference(from stored: Account, to edited: ProfileDraft) -> ProfileUpdate {
        var update = ProfileUpdate()
        if edited.displayName != (stored.displayName ?? "") {
            update.displayName = edited.displayName
        }
        if edited.handle != (stored.handle ?? "") {
            update.handle = edited.handle
        }
        if edited.bio != (stored.bio ?? "") {
            update.bio = edited.bio
        }
        return update
    }
}

/// The editable profile fields, trimmed the way the server trims them.
public struct ProfileDraft: Equatable, Sendable {

    /// Display name as typed.
    public var displayName: String
    /// Handle as typed. Lowercased before it is compared or sent.
    public var handle: String
    /// Bio as typed.
    public var bio: String

    public init(displayName: String = "", handle: String = "", bio: String = "") {
        self.displayName = displayName
        self.handle = handle
        self.bio = bio
    }

    /// The draft that matches an account exactly.
    public init(account: Account) {
        self.displayName = account.displayName ?? ""
        self.handle = account.handle ?? ""
        self.bio = account.bio ?? ""
    }

    /// A copy with whitespace stripped and the handle lowercased — the exact
    /// values the server would store, so an unedited round trip is not
    /// mistaken for a change.
    public var normalised: ProfileDraft {
        ProfileDraft(
            displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines),
            handle: handle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            bio: bio.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// Why the draft cannot be sent, or `nil` when it can.
    ///
    /// A blank handle is fine — it means "don't change it" and is dropped by
    /// ``ProfileUpdate/difference(from:to:)`` unless the account never had one.
    public var validationError: String? {
        let clean = normalised
        if clean.displayName.count > AccountLimits.maximumDisplayNameLength {
            return "Display names are at most \(AccountLimits.maximumDisplayNameLength) characters."
        }
        if clean.bio.count > AccountLimits.maximumBioLength {
            return "Bios are at most \(AccountLimits.maximumBioLength) characters."
        }
        if !clean.handle.isEmpty, !Handle.isValid(clean.handle) {
            return "Handles are 3–20 characters of letters, numbers and underscores."
        }
        return nil
    }
}

/// The handle rule, mirrored from the server's `^[a-z0-9_]{3,20}$`.
public enum Handle {

    /// `true` when the server's regex would accept this handle.
    /// - Parameter handle: Already lowercased and trimmed.
    public static func isValid(_ handle: String) -> Bool {
        guard AccountLimits.handleLengthRange.contains(handle.count) else { return false }
        return handle.unicodeScalars.allSatisfy { scalar in
            ("a"..."z").contains(String(scalar))
                || ("0"..."9").contains(String(scalar))
                || scalar == "_"
        }
    }
}

// MARK: - Phone

/// Why a typed phone number was refused.
public enum PhoneEntryError: Error, Equatable, Sendable {
    /// Nothing was typed.
    case empty
    /// Not E.164 — missing the `+`, or the wrong number of digits.
    case notE164

    /// A sentence safe to put under the field.
    public var message: String {
        switch self {
        case .empty:
            return "Type a number, or remove the one on file."
        case .notE164:
            return "Use international format, starting with a plus and a country "
                + "code — for example +966501234567."
        }
    }
}

/// Validation, normalisation and display for the contact number.
///
/// **A number here is never verification of anything.** There is no SMS provider
/// in this deployment, so the server stores what was typed and reports
/// `phone_verified: false` forever. Every piece of copy this type produces says
/// so, and none of it hands back a badge, a checkmark or a colour: on Sila a
/// green tick means an identity was checked by a human or a government, and a
/// number somebody typed into a form must never borrow that meaning.
public enum PhoneNumber {

    /// The exact normalisation the server applies before validating: spaces and
    /// dashes removed, nothing else.
    ///
    /// Stripping more than the server does would let the client accept a number
    /// the server then rejects — brackets and dots are refused here for the same
    /// reason they are refused there.
    /// - Parameter raw: Exactly what the user typed.
    public static func normalised(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
    }

    /// `true` when the server's shape check would pass.
    ///
    /// Mirrors `phone.startswith("+") and phone[1:].isdigit() and 8 <= len(phone) <= 16`
    /// — note the length counts the leading `+`.
    /// - Parameter candidate: An already-``normalised(_:)`` string.
    public static func isE164(_ candidate: String) -> Bool {
        guard candidate.hasPrefix("+") else { return false }
        let digits = candidate.dropFirst()
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return false }
        return (8...16).contains(candidate.count)
    }

    /// Validates a typed number.
    /// - Parameter raw: Exactly what the user typed.
    /// - Returns: The E.164 string to send, or why it was refused.
    public static func validate(_ raw: String) -> Result<String, PhoneEntryError> {
        let candidate = normalised(raw)
        guard !candidate.isEmpty else { return .failure(.empty) }
        guard isE164(candidate) else { return .failure(.notE164) }
        return .success(candidate)
    }

    /// A stored number spaced out for reading.
    ///
    /// Grouped in threes from the left, after the `+`. Deliberately **not**
    /// grouped by country convention: this client does not know which digits are
    /// the country code, and inventing a split would be a guess rendered as a
    /// fact. The grouping is purely visual — ``normalised(_:)`` turns it back
    /// into exactly the stored string.
    /// - Parameter e164: A stored number, or `nil`.
    public static func display(_ e164: String?) -> String? {
        guard let e164, isE164(normalised(e164)) else { return e164 }
        let digits = Array(normalised(e164).dropFirst())
        var groups: [String] = []
        var index = 0
        while index < digits.count {
            groups.append(String(digits[index..<min(index + 3, digits.count)]))
            index += 3
        }
        return "+" + groups.joined(separator: " ")
    }

    /// What the screen says about the number's standing, whatever is on file.
    ///
    /// Constant, and never derived from the wire's `phone_verified`: if the
    /// server ever started sending `true` without an SMS provider behind it,
    /// this build would still not call the number verified.
    public static let unverifiedCaption =
        "Contact detail only. Sila has not checked that this number is yours — "
        + "there is no SMS confirmation, so it is not part of your verified identity."
}

// MARK: - Avatars

/// An image chosen for upload, with the facts about it the form needs.
public struct AvatarImage: Equatable, Sendable {

    /// The bytes, exactly as read from the photo library.
    public let data: Data
    /// The name reported to the server. A label, not a promise.
    public let filename: String
    /// Declared type of the part, sniffed from the bytes.
    public let mimeType: String

    public init(data: Data, filename: String, mimeType: String) {
        self.data = data
        self.filename = filename
        self.mimeType = mimeType
    }

    /// Builds an image from picked bytes, naming it from what the bytes are.
    /// - Parameters:
    ///   - data: Bytes from `PhotosPicker`.
    ///   - basename: Filename stem. Defaults to `avatar`.
    public init(data: Data, basename: String = "avatar") {
        let format = AvatarUpload.sniffFormat(data)
        self.data = data
        self.filename = "\(basename).\(format.fileExtension)"
        self.mimeType = format.mimeType
    }
}

/// Why an image cannot be uploaded.
public enum AvatarRejection: Error, Equatable, Sendable {
    /// Nothing was read from the picked item.
    case empty
    /// Over ``AvatarUpload/maximumBytes``.
    case tooLarge(bytes: Int)

    /// A sentence safe to put in front of a user, naming the actual size so
    /// "too big" is actionable rather than a scold.
    public var message: String {
        switch self {
        case .empty:
            return "That photo couldn't be read. Pick another one."
        case let .tooLarge(bytes):
            let megabytes = Double(bytes) / (1024 * 1024)
            return String(
                format: "That photo is %.1f MB. Profile pictures must be under %d MB — "
                    + "pick a smaller one, or crop it first.",
                megabytes,
                AvatarUpload.maximumBytes / (1024 * 1024)
            )
        }
    }
}

/// Client-side rules for `PUT /me/avatar`, and the body it sends.
public enum AvatarUpload {

    /// The server's pre-decode limit, mirrored so an oversized photo is refused
    /// here instead of after uploading five megabytes to earn a 413.
    public static let maximumBytes = 5 * 1024 * 1024

    /// The form field name the endpoint expects.
    public static let fieldName = "file"

    /// What the server does to every upload, in plain language.
    ///
    /// Shown next to the picker rather than buried, because two of these are
    /// facts about the user's privacy and not housekeeping: a phone photo
    /// carries the coordinates it was taken at, and "set a photo" is not a
    /// sentence anybody reads as "publish where I was standing".
    public static let processingDisclosure =
        "Sila re-encodes your picture on the server: it is cropped square, resized "
        + "to 512×512 and saved as a new JPEG. Location data and every other EXIF "
        + "tag your camera attached is dropped in the process — the original file "
        + "is never stored or served."

    /// Checks an image against the client-side limits.
    /// - Parameter data: The picked bytes.
    /// - Returns: `nil` when the upload may proceed.
    public static func rejection(for data: Data) -> AvatarRejection? {
        if data.isEmpty { return .empty }
        if data.count > maximumBytes { return .tooLarge(bytes: data.count) }
        return nil
    }

    /// Builds the exact `multipart/form-data` body `PUT /me/avatar` expects.
    /// - Parameters:
    ///   - image: The picked image.
    ///   - boundary: Injectable so tests can assert on deterministic bytes.
    public static func form(for image: AvatarImage, boundary: String? = nil) -> MultipartFormData {
        var form = boundary.map { MultipartFormData(boundary: $0) } ?? MultipartFormData()
        form.appendFile(
            image.data,
            name: fieldName,
            filename: image.filename,
            mimeType: image.mimeType
        )
        return form
    }

    /// An image format identified from its leading bytes.
    public enum Format: String, Sendable, Equatable, CaseIterable {
        case jpeg, png, gif, webp, heic, unknown

        /// The `Content-Type` for this part.
        ///
        /// ``unknown`` declares `application/octet-stream` rather than guessing
        /// `image/jpeg`: the server decides what a file is by decoding it, and a
        /// header that claims otherwise is only a claim the client made up.
        public var mimeType: String {
            switch self {
            case .jpeg: return "image/jpeg"
            case .png: return "image/png"
            case .gif: return "image/gif"
            case .webp: return "image/webp"
            case .heic: return "image/heic"
            case .unknown: return "application/octet-stream"
            }
        }

        /// Extension used in the reported filename.
        public var fileExtension: String {
            switch self {
            case .jpeg: return "jpg"
            case .unknown: return "bin"
            default: return rawValue
            }
        }
    }

    /// Identifies an image from its magic bytes.
    ///
    /// The bytes are the only honest source: `PhotosPicker` reports a uniform
    /// type the system inferred, and the filename is whatever we choose to call
    /// it. Neither is evidence.
    /// - Parameter data: The picked bytes.
    public static func sniffFormat(_ data: Data) -> Format {
        let bytes = [UInt8](data.prefix(16))
        guard bytes.count >= 4 else { return .unknown }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return .jpeg }
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return .png }
        if bytes.starts(with: [0x47, 0x49, 0x46, 0x38]) { return .gif }
        if bytes.count >= 12,
           bytes.starts(with: [0x52, 0x49, 0x46, 0x46]),
           Array(bytes[8..<12]) == [0x57, 0x45, 0x42, 0x50] {
            return .webp
        }
        // ISO-BMFF: a length prefix, then "ftyp", then the brand.
        if bytes.count >= 12, Array(bytes[4..<8]) == [0x66, 0x74, 0x79, 0x70] {
            let brand = String(decoding: bytes[8..<12], as: UTF8.self)
            if brand.hasPrefix("hei") || brand.hasPrefix("mif") || brand.hasPrefix("msf") {
                return .heic
            }
        }
        return .unknown
    }
}

// MARK: - Credential change bodies

/// The `POST /me/password` body.
public struct PasswordChangeRequest: Encodable, Equatable, Sendable {
    public let currentPassword: String
    public let newPassword: String

    public init(currentPassword: String, newPassword: String) {
        self.currentPassword = currentPassword
        self.newPassword = newPassword
    }
}

/// What `POST /me/password` answers.
public struct PasswordChangeResult: Decodable, Equatable, Sendable {
    /// Whether the password was replaced.
    public let changed: Bool
    /// Whether every other session was revoked. The server always does this.
    public let otherSessionsSignedOut: Bool

    public init(changed: Bool = true, otherSessionsSignedOut: Bool = true) {
        self.changed = changed
        self.otherSessionsSignedOut = otherSessionsSignedOut
    }

    private enum CodingKeys: String, CodingKey {
        case changed, otherSessionsSignedOut
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        changed = (try? container.decode(Bool.self, forKey: .changed)) ?? true
        otherSessionsSignedOut =
            (try? container.decode(Bool.self, forKey: .otherSessionsSignedOut)) ?? true
    }
}

/// The `POST /me/email/request` body.
public struct EmailChangeRequest: Encodable, Equatable, Sendable {
    public let currentPassword: String
    public let newEmail: String

    public init(currentPassword: String, newEmail: String) {
        self.currentPassword = currentPassword
        self.newEmail = newEmail
    }
}

/// What `POST /me/email/request` answers — the address the code went to.
public struct EmailChangeSent: Decodable, Equatable, Sendable {
    /// Whether the mail was handed to the provider.
    public let sent: Bool
    /// The address the code was sent to. The **new** one, always.
    public let to: String

    public init(sent: Bool = true, to: String) {
        self.sent = sent
        self.to = to
    }

    private enum CodingKeys: String, CodingKey { case sent, to }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sent = (try? container.decode(Bool.self, forKey: .sent)) ?? true
        to = (try? container.decode(String.self, forKey: .to)) ?? ""
    }
}

/// The `POST /me/email/confirm` body.
public struct EmailChangeConfirmation: Encodable, Equatable, Sendable {
    public let newEmail: String
    public let code: String

    public init(newEmail: String, code: String) {
        self.newEmail = newEmail
        self.code = code
    }
}

/// The `PUT /me/phone` body. `phone: nil` clears the number.
public struct PhoneUpdate: Encodable, Equatable, Sendable {
    public let currentPassword: String
    /// E.164, or `nil` to remove the number entirely.
    public let phone: String?

    public init(currentPassword: String, phone: String?) {
        self.currentPassword = currentPassword
        self.phone = phone
    }

    /// `nil` must reach the server as an explicit JSON `null`, because that is
    /// how "clear it" is said. The synthesised encoder omits `nil`s, so the
    /// field is written by hand.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(currentPassword, forKey: .currentPassword)
        try container.encode(phone, forKey: .phone)
    }

    /// Plain camel-case names; ``JSONCoding/encoder`` converts them to
    /// `snake_case` like every other body.
    private enum CodingKeys: String, CodingKey {
        case currentPassword, phone
    }
}

// MARK: - Deletion

/// The `POST /me/delete` body.
public struct DeletionRequest: Encodable, Equatable, Sendable {
    public let currentPassword: String
    /// Must be exactly ``DeletionConfirmation/requiredWord``.
    public let confirm: String

    public init(currentPassword: String, confirm: String) {
        self.currentPassword = currentPassword
        self.confirm = confirm
    }
}

/// The two things that must both be true before the delete button does anything.
///
/// A value type rather than a pair of view flags so the gate is one testable
/// rule instead of a condition spread across a screen: this is the last barrier
/// in front of an action that takes somebody's account away, and it should not
/// be possible to weaken it by editing a `.disabled(…)` modifier.
public struct DeletionConfirmation: Equatable, Sendable {

    /// The word that must be typed, exactly. Case-sensitive.
    public static let requiredWord = "DELETE"

    /// The account password, as typed.
    public var currentPassword: String
    /// The confirmation word, as typed.
    public var typedWord: String

    public init(currentPassword: String = "", typedWord: String = "") {
        self.currentPassword = currentPassword
        self.typedWord = typedWord
    }

    /// `true` only when both conditions hold.
    ///
    /// The word is compared byte for byte with **no trimming**: `"DELETE "` and
    /// `"delete"` do not pass. Trimming would mean a stray space typed by
    /// someone who has not finished reading the screen counts as consent, and
    /// the server refuses those anyway with `confirmation_required`.
    ///
    /// The password is only checked for emptiness, and is **not** trimmed
    /// either — a password may legitimately be nothing but spaces.
    public var isConfirmable: Bool {
        !currentPassword.isEmpty && typedWord == Self.requiredWord
    }

    /// What is still missing, for the hint under the button, or `nil`.
    public var blockingReason: String? {
        if currentPassword.isEmpty && typedWord != Self.requiredWord {
            return "Enter your password and type \(Self.requiredWord) to continue."
        }
        if currentPassword.isEmpty {
            return "Enter your current password to continue."
        }
        if typedWord != Self.requiredWord {
            return "Type \(Self.requiredWord) in capitals, exactly, to continue."
        }
        return nil
    }

    /// The body to send once ``isConfirmable`` holds.
    public var request: DeletionRequest {
        DeletionRequest(currentPassword: currentPassword, confirm: typedWord)
    }
}

/// What `POST /me/delete` answers.
public struct DeletionSchedule: Decodable, Equatable, Sendable {
    /// Whether the account is now deactivated. Immediately true.
    public let deactivated: Bool
    /// When the data is destroyed for good, or `nil` if the server omitted it.
    public let purgeAfter: Date?
    /// Length of the grace period in days.
    public let graceDays: Int
    /// Whether signing in and cancelling still works.
    public let reversibleUntilPurge: Bool
    /// The server's own statement of what outlives the purge.
    ///
    /// Rendered verbatim rather than paraphrased: it is the answer to "what do
    /// you keep about me", and a client-side reword is a client-side promise.
    public let whatIsKept: String

    public init(
        deactivated: Bool = true,
        purgeAfter: Date? = nil,
        graceDays: Int = DeletionDisclosure.graceDays,
        reversibleUntilPurge: Bool = true,
        whatIsKept: String = ""
    ) {
        self.deactivated = deactivated
        self.purgeAfter = purgeAfter
        self.graceDays = graceDays
        self.reversibleUntilPurge = reversibleUntilPurge
        self.whatIsKept = whatIsKept
    }

    private enum CodingKeys: String, CodingKey {
        case deactivated, purgeAfter, graceDays, reversibleUntilPurge, whatIsKept
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        deactivated = (try? container.decode(Bool.self, forKey: .deactivated)) ?? true
        purgeAfter = (try? container.decodeIfPresent(Date.self, forKey: .purgeAfter)) ?? nil
        graceDays = (try? container.decode(Int.self, forKey: .graceDays)) ?? DeletionDisclosure.graceDays
        reversibleUntilPurge = (try? container.decode(Bool.self, forKey: .reversibleUntilPurge)) ?? true
        whatIsKept = (try? container.decode(String.self, forKey: .whatIsKept)) ?? ""
    }
}

/// What deleting an account actually does, said before it is done.
///
/// Held as constants so the wording is asserted in tests rather than left to
/// drift: this is the only place a person finds out that deletion is immediate
/// to everyone else, that it takes every session with it, and that they have a
/// month to change their mind. A confirmation screen that omits any of the four
/// is asking for consent to something it has not described.
public enum DeletionDisclosure {

    /// The grace period the backend applies.
    public static let graceDays = 30

    /// Effect one: the account stops working straight away.
    public static let immediate =
        "Your account is deactivated the moment you confirm. To everyone else on "
        + "Sila it is already gone."

    /// Effect two: every device is signed out.
    public static let sessions =
        "Every session is signed out, on this device and every other one. Signing "
        + "back in is what you would do to undo this."

    /// Effect three: the posts disappear from everywhere.
    public static let posts =
        "Your posts leave every feed, every search result and every thread, and "
        + "your profile stops resolving."

    /// Effect four: it is reversible, and for how long.
    public static let recoverable =
        "Nothing is destroyed for \(graceDays) days. Sign in during that time and "
        + "choose Cancel deletion and everything comes back exactly as it was."

    /// Effect five: after the grace period it is final.
    public static let permanent =
        "After \(graceDays) days your account, your posts, your reactions, your "
        + "follows and your settings are deleted outright. Posts are deleted, not "
        + "anonymised. That cannot be undone."

    /// The four consequences the confirmation screen must state, in order.
    public static let consequences = [immediate, sessions, posts, recoverable]

    /// The nudge shown above the button — export first, it costs nothing.
    public static let exportFirst =
        "Download a copy of your data first if you want to keep it. It takes a "
        + "moment and you cannot ask for it afterwards."
}

// MARK: - Where the user should be

/// The screen the Account module should be showing.
///
/// A deactivated account is a **state**, not a failure: the credentials are
/// good, the server is working, and the person is inside a window that exists
/// precisely so they can change their mind. Rendering that as an error alert
/// with a Retry button would loop somebody through the same 403 until the purge
/// ran, which is the one outcome the grace period exists to prevent.
public enum AccountRoute: Equatable, Sendable {
    /// The normal settings surface.
    case settings
    /// The account is pending deletion; only recovery is offered.
    case recovery
}

/// Decides between the settings surface and the recovery screen.
public enum AccountRouting {

    /// The route implied by a failed call.
    /// - Parameter error: Anything a service can throw.
    /// - Returns: ``AccountRoute/recovery`` for `account_deactivated`; `nil`
    ///   when the error is an ordinary failure the screen should report.
    public static func route(forError error: Error) -> AccountRoute? {
        guard APIError.wrapping(error).code == .accountDeactivated else { return nil }
        return .recovery
    }

    /// The route implied by a loaded account.
    ///
    /// `GET /me/account` is one of only two endpoints a deactivated account may
    /// call, so it answers `200` with the deletion timestamps set rather than
    /// `403`. Reading them here means the recovery screen appears on the way in,
    /// without waiting for some later call to fail.
    /// - Parameter account: The freshly loaded account.
    public static func route(for account: Account) -> AccountRoute {
        account.isPendingDeletion ? .recovery : .settings
    }
}
