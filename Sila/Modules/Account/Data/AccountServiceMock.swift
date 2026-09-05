import Foundation

/// Scripted ``AccountServiceProtocol`` for tests, previews and the
/// `-mockAccount` launch argument.
///
/// It enforces the same rules the server does rather than saying yes to
/// everything, because the interesting behaviour on this screen is entirely in
/// the refusals: a wrong password, a taken address, an account that is already
/// being deleted. A mock that accepted every call would demo a settings screen
/// nobody could get wrong.
///
/// In particular it models ``MockScenario/pendingDeletion`` faithfully: every
/// call except `GET /me/account` and `POST /me/delete/cancel` answers
/// `403 account_deactivated`, exactly as `get_current_user` does.
public actor AccountServiceMock: AccountServiceProtocol {

    /// The canned worlds the mock can serve.
    public enum MockScenario: String, CaseIterable, Sendable {
        /// A filled-in account: name, handle, bio, picture and a phone number.
        case populated
        /// A brand-new account — an address and nothing else.
        case fresh
        /// Every call fails with a transport error.
        case offline
        /// The account is inside its deletion grace period.
        ///
        /// The state the recovery screen exists for, and the one that is
        /// otherwise only reachable by really deleting a real account.
        case pendingDeletion
        /// Every credential call rejects the password.
        case wrongPassword
    }

    /// The password ``MockScenario/populated`` accepts.
    public static let correctPassword = "correct-horse-battery"

    /// The scenario currently being played.
    public private(set) var scenario: MockScenario

    /// Artificial latency, in seconds. Tests pass `0`.
    private let latency: Double

    /// The stored account, mutated by every accepted write.
    private var stored: Account

    /// The address a code was sent to, if a change is in flight.
    private var pendingEmail: String?

    /// The code the mock will accept for an email change.
    public static let emailCode = "123456"

    /// Bodies received, in order — the assertion surface for tests.
    public private(set) var receivedProfileUpdates: [ProfileUpdate] = []
    /// Avatar images received, in order.
    public private(set) var receivedAvatars: [AvatarImage] = []
    /// Deletion confirmations received, in order.
    public private(set) var receivedDeletions: [DeletionConfirmation] = []
    /// Phone bodies received, in order.
    public private(set) var receivedPhones: [PhoneUpdate] = []

    /// Creates a mock.
    /// - Parameters:
    ///   - scenario: Which world to serve.
    ///   - latency: Seconds of simulated delay.
    public init(scenario: MockScenario = .populated, latency: Double = 0) {
        self.scenario = scenario
        self.latency = latency
        switch scenario {
        case .fresh: self.stored = Self.freshAccount
        case .pendingDeletion: self.stored = Self.deletingAccount
        default: self.stored = Self.filledIn
        }
    }

    /// Switches scenario mid-flight.
    public func setScenario(_ scenario: MockScenario) {
        self.scenario = scenario
    }

    // MARK: - AccountServiceProtocol

    public func fetchAccount() async throws -> Account {
        try await delay()
        try failIfOffline()
        // Deliberately not gated on deactivation: this is one of the two
        // endpoints the server lets a deactivated account call, and the whole
        // recovery flow depends on it answering.
        return stored
    }

    public func updateProfile(_ update: ProfileUpdate) async throws -> Account {
        receivedProfileUpdates.append(update)
        try await delay()
        try failIfOffline()
        try failIfDeactivated()

        if let handle = update.handle, !handle.isEmpty {
            guard Handle.isValid(handle.lowercased()) else {
                throw APIError.api(
                    code: .invalidHandle,
                    message: "Handles are 3–20 characters of a–z, 0–9 and underscore",
                    status: 400
                )
            }
            guard handle.lowercased() != Self.takenHandle else {
                throw APIError.api(code: .handleTaken, message: "That handle is already taken", status: 409)
            }
        }

        stored = Account(
            id: stored.id,
            email: stored.email,
            handle: update.handle.map { $0.isEmpty ? nil : $0.lowercased() } ?? stored.handle,
            displayName: update.displayName.map { $0.isEmpty ? nil : $0 } ?? stored.displayName,
            bio: update.bio.map { $0.isEmpty ? nil : $0 } ?? stored.bio,
            avatarPath: stored.avatarPath,
            phone: stored.phone,
            countryCode: stored.countryCode,
            verificationStatus: stored.verificationStatus,
            deletionRequestedAt: stored.deletionRequestedAt,
            purgeAfter: stored.purgeAfter,
            isPrivate: update.isPrivate ?? stored.isPrivate
        )
        return stored
    }

    public func uploadAvatar(_ image: AvatarImage) async throws -> Account {
        receivedAvatars.append(image)
        try await delay()
        try failIfOffline()
        try failIfDeactivated()

        // The same two refusals `media.py` makes, in the same order.
        guard !image.data.isEmpty else {
            throw APIError.api(code: .invalidImage, message: "No file was uploaded", status: 400)
        }
        guard image.data.count <= AvatarUpload.maximumBytes else {
            throw APIError.api(code: .imageTooLarge, message: "Images must be under 5MB", status: 413)
        }
        guard AvatarUpload.sniffFormat(image.data) != .unknown else {
            throw APIError.api(
                code: .invalidImage,
                message: "That file could not be read as an image",
                status: 400
            )
        }

        stored = stored.replacingAvatar(with: "/api/v1/media/avatars/\(UUID().uuidString.prefix(8)).jpg")
        return stored
    }

    public func removeAvatar() async throws -> Account {
        try await delay()
        try failIfOffline()
        try failIfDeactivated()
        stored = stored.replacingAvatar(with: nil)
        return stored
    }

    public func changePassword(
        currentPassword: String,
        newPassword: String
    ) async throws -> PasswordChangeResult {
        try await delay()
        try failIfOffline()
        try failIfDeactivated()
        try checkPassword(currentPassword)
        guard currentPassword != newPassword else {
            throw APIError.api(
                code: .passwordUnchanged,
                message: "The new password matches the old one",
                status: 400
            )
        }
        return PasswordChangeResult(changed: true, otherSessionsSignedOut: true)
    }

    public func requestEmailChange(
        currentPassword: String,
        newEmail: String
    ) async throws -> EmailChangeSent {
        try await delay()
        try failIfOffline()
        try failIfDeactivated()
        try checkPassword(currentPassword)

        let wanted = newEmail.lowercased()
        guard wanted != stored.email.lowercased() else {
            throw APIError.api(
                code: .emailUnchanged,
                message: "That is already your email address",
                status: 400
            )
        }
        guard wanted != Self.takenEmail else {
            throw APIError.api(
                code: .emailTaken,
                message: "Another account already uses that address",
                status: 409
            )
        }
        pendingEmail = wanted
        return EmailChangeSent(sent: true, to: wanted)
    }

    public func confirmEmailChange(newEmail: String, code: String) async throws -> Account {
        try await delay()
        try failIfOffline()
        try failIfDeactivated()

        guard pendingEmail == newEmail.lowercased() else {
            throw APIError.api(code: .otpInvalid, message: "No active code — request a new one", status: 400)
        }
        guard code == Self.emailCode else {
            throw APIError.api(code: .otpInvalid, message: "Incorrect code", status: 400)
        }
        // The window the server re-checks for: somebody else can claim the
        // address while the code is sitting in an inbox.
        guard newEmail.lowercased() != Self.claimedDuringConfirmEmail else {
            throw APIError.api(
                code: .emailTaken,
                message: "Another account claimed that address",
                status: 409
            )
        }
        pendingEmail = nil
        stored = stored.replacingEmail(with: newEmail.lowercased())
        return stored
    }

    public func setPhone(currentPassword: String, phone: String?) async throws -> Account {
        receivedPhones.append(PhoneUpdate(currentPassword: currentPassword, phone: phone))
        try await delay()
        try failIfOffline()
        try failIfDeactivated()
        try checkPassword(currentPassword)

        guard let phone, !phone.trimmingCharacters(in: .whitespaces).isEmpty else {
            stored = stored.replacingPhone(with: nil)
            return stored
        }
        let candidate = PhoneNumber.normalised(phone)
        guard PhoneNumber.isE164(candidate) else {
            throw APIError.api(
                code: .invalidPhone,
                message: "Use international format, e.g. +966501234567",
                status: 400
            )
        }
        stored = stored.replacingPhone(with: candidate)
        return stored
    }

    public func exportData() async throws -> Data {
        try await delay()
        try failIfOffline()
        try failIfDeactivated()
        return Data(Self.exportPayload(for: stored).utf8)
    }

    public func requestDeletion(_ confirmation: DeletionConfirmation) async throws -> DeletionSchedule {
        receivedDeletions.append(confirmation)
        try await delay()
        try failIfOffline()
        try failIfDeactivated()

        // The server checks the word before the password, so a bad confirmation
        // is reported as such even when the password is also wrong.
        guard confirmation.typedWord == DeletionConfirmation.requiredWord else {
            throw APIError.api(
                code: .confirmationRequired,
                message: "Send confirm: \"DELETE\" to proceed",
                status: 400
            )
        }
        try checkPassword(confirmation.currentPassword)

        let now = Date()
        let purge = now.addingTimeInterval(Double(DeletionDisclosure.graceDays) * 86_400)
        stored = stored.scheduledForDeletion(at: now, purgeAfter: purge)
        return DeletionSchedule(
            deactivated: true,
            purgeAfter: purge,
            graceDays: DeletionDisclosure.graceDays,
            reversibleUntilPurge: true,
            whatIsKept: Self.whatIsKept
        )
    }

    public func cancelDeletion() async throws -> Account {
        try await delay()
        try failIfOffline()
        guard stored.isPendingDeletion else {
            throw APIError.api(
                code: .notPendingDeletion,
                message: "This account is not scheduled for deletion",
                status: 400
            )
        }
        stored = stored.scheduledForDeletion(at: nil, purgeAfter: nil)
        return stored
    }

    // MARK: - Fixture world

    /// The handle the mock refuses as already taken.
    public static let takenHandle = "aziz"
    /// The address the mock refuses at request time.
    public static let takenEmail = "taken@example.com"
    /// The address the mock accepts a code for and *then* refuses, reproducing
    /// the race the server re-checks for.
    public static let claimedDuringConfirmEmail = "raced@example.com"

    static let whatIsKept =
        "Nothing is retained after the purge date at present. When identity "
        + "verification ships, a one-way hash of the verified identity is kept "
        + "permanently so that a revoked account cannot re-register — that hash "
        + "cannot be reversed into your identity and is not used for anything else."

    /// A filled-in account.
    public static let filledIn = Account(
        id: UUID(uuidString: "6c1b1f7e-5a3d-4b2a-9d21-0c1f2a3b4c5d") ?? UUID(),
        email: "aziz@example.com",
        handle: "aziz_sa",
        displayName: "Aziz Alwakeel",
        bio: "Building things in Riyadh. Opinions are load-bearing.",
        avatarPath: "/api/v1/media/avatars/6c1b1f7e-1a2b3c4d.jpg",
        phone: "+966501234567",
        countryCode: "SA",
        verificationStatus: .verified
    )

    /// A brand-new account with nothing filled in.
    public static let freshAccount = Account(
        id: UUID(uuidString: "11111111-2222-3333-4444-555555555555") ?? UUID(),
        email: "new@example.com",
        handle: "new1",
        verificationStatus: .verified
    )

    /// An account eleven days into its grace period.
    public static let deletingAccount = Account(
        id: UUID(uuidString: "99999999-8888-7777-6666-555555555555") ?? UUID(),
        email: "leaving@example.com",
        handle: "leaving",
        displayName: "On the way out",
        verificationStatus: .verified,
        deletionRequestedAt: Date().addingTimeInterval(-11 * 86_400),
        purgeAfter: Date().addingTimeInterval(19 * 86_400)
    )

    /// A believable `GET /me/export` body, including the server's note about
    /// what is deliberately left out.
    static func exportPayload(for account: Account) -> String {
        """
        {
          "exported_at": "2026-08-28T09:15:00+00:00",
          "account": {"id": "\(account.id.uuidString.lowercased())", "email": "\(account.email)"},
          "posts": [],
          "topic_preferences": [],
          "following": [],
          "note": "Topic labels applied to your posts by automated classification are not included: they are inferences drawn about your posts, not content you provided."
        }
        """
    }

    // MARK: - Plumbing

    private func delay() async throws {
        guard latency > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(latency * 1_000_000_000))
    }

    private func failIfOffline() throws {
        if scenario == .offline {
            throw APIError.transport("The Internet connection appears to be offline.")
        }
    }

    /// Reproduces `get_current_user`: a deactivated account is refused
    /// everywhere except the two recovery endpoints, with a 403 carrying a code
    /// the client is expected to act on rather than display.
    private func failIfDeactivated() throws {
        if stored.isPendingDeletion {
            throw APIError.api(
                code: .accountDeactivated,
                message: "This account is scheduled for deletion. Cancel the deletion to use it again.",
                status: 403
            )
        }
    }

    private func checkPassword(_ password: String) throws {
        let accepted = scenario != .wrongPassword && password == Self.correctPassword
        guard accepted else {
            throw APIError.api(
                code: .invalidCredentials,
                message: "That is not your current password",
                status: 403
            )
        }
    }
}

// MARK: - Fixture editing

extension Account {

    /// A copy with a different avatar path.
    func replacingAvatar(with path: String?) -> Account {
        copy(avatarPath: .some(path))
    }

    /// A copy with a different address.
    func replacingEmail(with email: String) -> Account {
        copy(email: email)
    }

    /// A copy with a different contact number.
    func replacingPhone(with phone: String?) -> Account {
        copy(phone: .some(phone))
    }

    /// A copy with the deletion timestamps set or cleared.
    func scheduledForDeletion(at requested: Date?, purgeAfter: Date?) -> Account {
        copy(deletionRequestedAt: .some(requested), purgeAfter: .some(purgeAfter))
    }

    /// The one place fixture edits are assembled, so a new field on ``Account``
    /// cannot be silently dropped by four separate copy helpers.
    private func copy(
        email: String? = nil,
        avatarPath: String?? = nil,
        phone: String?? = nil,
        deletionRequestedAt: Date?? = nil,
        purgeAfter: Date?? = nil
    ) -> Account {
        Account(
            id: id,
            email: email ?? self.email,
            handle: handle,
            displayName: displayName,
            bio: bio,
            avatarPath: avatarPath ?? self.avatarPath,
            phone: phone ?? self.phone,
            countryCode: countryCode,
            verificationStatus: verificationStatus,
            deletionRequestedAt: deletionRequestedAt ?? self.deletionRequestedAt,
            purgeAfter: purgeAfter ?? self.purgeAfter
        )
    }
}
