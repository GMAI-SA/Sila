import Foundation
import Observation

/// Which credential form is open, if any.
///
/// Each one is a separate sheet rather than a section of the long screen,
/// because each one needs the current password and a form that asks for a
/// password inline, next to six other controls, teaches people to type it
/// without noticing what they are confirming.
public enum AccountSheet: String, Identifiable, Hashable, Sendable {
    /// `POST /me/password`.
    case password
    /// `POST /me/email/request` → `POST /me/email/confirm`.
    case email
    /// `PUT /me/phone`.
    case phone
    /// `POST /me/delete`.
    case delete

    public var id: String { rawValue }

    /// Sheet title.
    public var title: String {
        switch self {
        case .password: return "Change password"
        case .email: return "Change email"
        case .phone: return "Contact number"
        case .delete: return "Delete account"
        }
    }
}

/// How far through the two-step email change the user is.
public enum EmailChangeStage: Equatable, Sendable {
    /// Nothing sent yet: password and new address.
    case entry
    /// A code is sitting in the new mailbox.
    case awaitingCode(sentTo: String)
    /// The server accepted the code.
    case confirmed(address: String)
}

/// Drives ``AccountScreen``.
///
/// Three things shape its structure.
///
/// **The current password is state on the form, never on the model.** Every
/// credential call carries one, each form collects its own, and every form
/// clears it the moment the sheet closes or the call succeeds.
///
/// **`account_deactivated` is a route, not an error.** Any call may answer it,
/// and when one does the view model switches ``route`` to
/// ``AccountRoute/recovery`` instead of publishing an error string. Somebody
/// inside their grace period who signs in to undo a deletion must land on the
/// button that undoes it — a generic "something went wrong, try again" would
/// strand them until the purge ran and the choice stopped existing.
///
/// **What the screen shows after a write is what the server returned.** Every
/// mutating call replaces ``account`` with the response, so the UI never claims
/// a value it only hoped was stored.
@MainActor
@Observable
public final class AccountViewModel {

    // MARK: - Loaded state

    /// The account as the server last described it.
    public private(set) var account: Account?
    /// Which surface the user should be on.
    ///
    /// Settable within the module so a test can prove a **403** produced the
    /// recovery route rather than the load that came before it. Nothing outside
    /// the module can write it: routing is derived from what the server said.
    public internal(set) var route: AccountRoute = .settings
    /// `true` during the initial load.
    public private(set) var isLoading = false
    /// `true` once a load has finished, successfully or not.
    public private(set) var hasLoaded = false
    /// Why the screen could not load, when it could not.
    public private(set) var loadError: String?
    /// Banner message.
    public var toast: SLToastMessage?

    // MARK: - Profile

    /// The working copy the profile fields edit.
    public var profileDraft = ProfileDraft()
    /// `true` while the profile is being written.
    public private(set) var isSavingProfile = false
    /// Why the last profile save failed.
    public private(set) var profileError: String?

    // MARK: - Avatar

    /// `true` while a picture is being uploaded or removed.
    public private(set) var isWorkingOnAvatar = false
    /// Why the last picture was refused — by this client or by the server.
    public private(set) var avatarError: String?

    // MARK: - Password

    /// Current password, as typed in the password sheet.
    public var passwordCurrent = ""
    /// New password.
    public var passwordNew = ""
    /// New password, again.
    public var passwordRepeat = ""
    /// `true` while the change is in flight.
    public private(set) var isChangingPassword = false
    /// Why the last attempt failed.
    public private(set) var passwordError: String?
    /// Set once the server has accepted the change.
    public private(set) var passwordChanged: PasswordChangeResult?

    // MARK: - Email

    /// Current password, as typed in the email sheet.
    public var emailPassword = ""
    /// The address the user wants to move to.
    public var emailNew = ""
    /// The six-digit code, once one has been sent.
    public var emailCode = ""
    /// How far through the change the user is.
    public private(set) var emailStage: EmailChangeStage = .entry
    /// `true` while a call is in flight.
    public private(set) var isWorkingOnEmail = false
    /// Why the last attempt failed.
    public private(set) var emailError: String?

    // MARK: - Phone

    /// Current password, as typed in the phone sheet.
    public var phonePassword = ""
    /// The number as typed.
    public var phoneDraft = ""
    /// `true` while a call is in flight.
    public private(set) var isSavingPhone = false
    /// Why the last attempt failed.
    public private(set) var phoneError: String?

    // MARK: - Export

    /// `true` while the export is downloading.
    public private(set) var isExporting = false
    /// The downloaded export, written to a file so it can be shared out.
    public private(set) var exportFile: URL?
    /// Why the export failed.
    public private(set) var exportError: String?

    // MARK: - Deletion

    /// The two-part gate in front of `POST /me/delete`.
    public var deletion = DeletionConfirmation()
    /// `true` while the deletion request is in flight.
    public private(set) var isDeleting = false
    /// Why the last attempt failed.
    public private(set) var deletionError: String?
    /// What the server scheduled, once it has.
    public private(set) var deletionSchedule: DeletionSchedule?

    // MARK: - Recovery

    /// `true` while the cancellation is in flight.
    public private(set) var isCancellingDeletion = false
    /// Why the cancellation failed.
    public private(set) var recoveryError: String?

    // MARK: - Presentation

    /// Which credential sheet is up.
    public var presentedSheet: AccountSheet?

    // MARK: - Collaborators

    private let service: AccountServiceProtocol
    private let analytics: AnalyticsClient
    private let onSignOut: (@MainActor () -> Void)?

    /// - Parameters:
    ///   - service: Account backend.
    ///   - analytics: Event sink.
    ///   - onSignOut: Ends the session. Offered — never performed automatically
    ///     — after a password change, because the server revokes every refresh
    ///     token including this device's, so the session is already terminal
    ///     even though the current access token has not expired yet.
    public init(
        service: AccountServiceProtocol,
        analytics: AnalyticsClient,
        onSignOut: (@MainActor () -> Void)? = nil
    ) {
        self.service = service
        self.analytics = analytics
        self.onSignOut = onSignOut
    }

    // MARK: - Derived state

    /// `true` when the profile fields differ from what the server holds.
    public var hasProfileChanges: Bool {
        guard let account else { return false }
        return profileDraft.normalised != ProfileDraft(account: account)
    }

    /// Why the profile cannot be saved yet, or `nil`.
    public var profileValidationError: String? { profileDraft.validationError }

    /// `true` when Save should be tappable.
    public var canSaveProfile: Bool {
        hasProfileChanges && profileValidationError == nil && !isSavingProfile
    }

    /// Characters left in the bio, which may be negative.
    public var bioRemaining: Int {
        AccountLimits.maximumBioLength - profileDraft.bio.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).count
    }

    /// The number as it should be read on screen, or `nil`.
    public var displayPhone: String? { PhoneNumber.display(account?.phone) }

    /// `true` when there is a number to remove.
    public var hasPhone: Bool { account?.phone != nil }

    /// Whether the delete button may do anything. Both halves of the gate.
    public var canConfirmDeletion: Bool { deletion.isConfirmable && !isDeleting }

    /// Why the delete button is still inert, or `nil`.
    public var deletionBlockingReason: String? { deletion.blockingReason }

    /// Whole days left before the purge, or `nil`.
    public func daysUntilPurge(now: Date = Date()) -> Int? {
        account?.daysUntilPurge(now: now)
    }

    /// Whether the password form is complete and self-consistent.
    public var canChangePassword: Bool {
        !passwordCurrent.isEmpty
            && passwordNew.count >= AccountLimits.minimumPasswordLength
            && passwordNew == passwordRepeat
            && !isChangingPassword
    }

    /// Why the password form is not ready, or `nil`.
    public var passwordValidationError: String? {
        if passwordNew.isEmpty && passwordRepeat.isEmpty { return nil }
        if passwordNew.count < AccountLimits.minimumPasswordLength {
            return "Passwords are at least \(AccountLimits.minimumPasswordLength) characters."
        }
        if passwordNew.count > AccountLimits.maximumPasswordLength {
            return "Passwords are at most \(AccountLimits.maximumPasswordLength) characters."
        }
        if !passwordRepeat.isEmpty && passwordNew != passwordRepeat {
            return "Those two don't match."
        }
        return nil
    }

    /// Whether an email change may be started.
    public var canRequestEmailChange: Bool {
        !emailPassword.isEmpty && emailNew.contains("@") && !isWorkingOnEmail
    }

    /// Whether the code may be submitted.
    public var canConfirmEmailChange: Bool {
        emailCode.count == AppConfig.otpLength && !isWorkingOnEmail
    }

    /// Whether the phone form may be submitted.
    public var canSavePhone: Bool {
        !phonePassword.isEmpty && !phoneDraft.isEmpty && !isSavingPhone
    }

    // MARK: - Loading

    /// Loads the account. Safe to call on every appearance.
    public func load() async {
        guard !hasLoaded, !isLoading else { return }
        await reload()
    }

    /// Loads unconditionally — the retry path.
    public func reload() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }

        do {
            let loaded = try await service.fetchAccount()
            adopt(loaded)
            hasLoaded = true
            analytics.track(.accountLoaded, properties: [
                "pending_deletion": String(loaded.isPendingDeletion)
            ])
        } catch {
            // A 403 here would be surprising — `GET /me/account` admits a
            // deactivated account — but if it happens it is still a route.
            if handledDeactivation(error) { hasLoaded = true; return }
            loadError = APIError.wrapping(error).userMessage
        }
    }

    // MARK: - Profile

    /// Writes the changed profile fields and adopts what the server stored.
    public func saveProfile() async {
        guard let account, canSaveProfile else { return }
        let draft = profileDraft.normalised
        profileDraft = draft
        let update = ProfileUpdate.difference(from: account, to: draft)
        guard !update.isEmpty else { return }

        isSavingProfile = true
        profileError = nil
        defer { isSavingProfile = false }

        do {
            adopt(try await service.updateProfile(update))
            toast = .success("Profile saved.")
        } catch {
            guard !handledDeactivation(error) else { return }
            // The edits stay where they are: throwing away someone's work to
            // make a screen agree with the server is the worse failure.
            profileError = APIError.wrapping(error).userMessage
            toast = .error(profileError ?? "Couldn't save your profile.")
        }
    }

    /// Throws away the unsaved profile edits.
    public func discardProfileChanges() {
        guard let account else { return }
        profileDraft = ProfileDraft(account: account)
        profileError = nil
    }

    // MARK: - Avatar

    /// Uploads a picked image, refusing an oversized one before it is sent.
    ///
    /// The size check is the client's, not the server's echo: uploading five
    /// megabytes over a phone connection in order to be told it was too big is
    /// a minute of somebody's data allowance spent on a refusal that was
    /// predictable before the first byte left.
    /// - Parameter data: Bytes from `PhotosPicker`.
    public func setAvatar(data: Data) async {
        avatarError = nil

        if let rejection = AvatarUpload.rejection(for: data) {
            avatarError = rejection.message
            analytics.track(.accountAvatarRejected, properties: [
                "reason": rejection == .empty ? "empty" : "too_large",
                "bytes": String(data.count)
            ])
            toast = .error(rejection.message)
            return
        }

        isWorkingOnAvatar = true
        defer { isWorkingOnAvatar = false }

        do {
            adopt(try await service.uploadAvatar(AvatarImage(data: data)))
            toast = .success("Picture updated. Location data was removed.")
        } catch {
            guard !handledDeactivation(error) else { return }
            avatarError = APIError.wrapping(error).userMessage
            toast = .error(avatarError ?? "Couldn't set that picture.")
        }
    }

    /// Removes the profile picture.
    public func removeAvatar() async {
        guard account?.avatarPath != nil else { return }
        isWorkingOnAvatar = true
        avatarError = nil
        defer { isWorkingOnAvatar = false }

        do {
            adopt(try await service.removeAvatar())
            toast = .success("Picture removed.")
        } catch {
            guard !handledDeactivation(error) else { return }
            avatarError = APIError.wrapping(error).userMessage
            toast = .error(avatarError ?? "Couldn't remove your picture.")
        }
    }

    // MARK: - Password

    /// Changes the password.
    public func changePassword() async {
        guard canChangePassword else { return }
        isChangingPassword = true
        passwordError = nil
        defer { isChangingPassword = false }

        do {
            passwordChanged = try await service.changePassword(
                currentPassword: passwordCurrent,
                newPassword: passwordNew
            )
            // Nothing typed here is needed again, and it is the most sensitive
            // thing this process holds.
            passwordCurrent = ""
            passwordNew = ""
            passwordRepeat = ""
        } catch {
            guard !handledDeactivation(error) else { return }
            passwordError = APIError.wrapping(error).userMessage
        }
    }

    /// What the screen says once the password has been changed.
    ///
    /// The server revokes **every** refresh token, this device's included, so
    /// "other sessions" understates it: this session keeps working only until
    /// the current access token expires. Saying so is better than letting
    /// somebody be dropped to the sign-in screen an hour later with no idea why.
    public var passwordChangeOutcome: String {
        "Your password is changed. Every signed-in device was signed out — "
            + "including this one, which will ask for your new password the next "
            + "time it refreshes the session."
    }

    // MARK: - Email

    /// Sends a code to the new address.
    public func requestEmailChange() async {
        guard canRequestEmailChange else { return }
        isWorkingOnEmail = true
        emailError = nil
        defer { isWorkingOnEmail = false }

        let wanted = emailNew.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        do {
            let sent = try await service.requestEmailChange(
                currentPassword: emailPassword,
                newEmail: wanted
            )
            emailStage = .awaitingCode(sentTo: sent.to.isEmpty ? wanted : sent.to)
            emailPassword = ""
            emailCode = ""
        } catch {
            guard !handledDeactivation(error) else { return }
            emailError = APIError.wrapping(error).userMessage
        }
    }

    /// Submits the code from the new mailbox.
    public func confirmEmailChange() async {
        guard case let .awaitingCode(address) = emailStage, canConfirmEmailChange else { return }
        isWorkingOnEmail = true
        emailError = nil
        defer { isWorkingOnEmail = false }

        do {
            adopt(try await service.confirmEmailChange(newEmail: address, code: emailCode))
            emailStage = .confirmed(address: address)
            emailCode = ""
            toast = .success("You now sign in with \(address).")
        } catch {
            guard !handledDeactivation(error) else { return }
            let wrapped = APIError.wrapping(error)
            emailError = wrapped.userMessage
            // The address can be claimed while the code sits in an inbox, and
            // the server re-checks at exactly this moment. When that is what
            // happened the code is spent and the whole flow has to start again,
            // so the form goes back rather than leaving a dead code on screen.
            if wrapped.code == .emailTaken {
                emailStage = .entry
                emailNew = ""
                emailCode = ""
                emailError = "Somebody else claimed \(address) while your code was in the "
                    + "inbox, so the change was not made. Your address is unchanged. "
                    + "Try a different one."
            }
        }
    }

    /// Abandons an email change and clears everything it collected.
    public func resetEmailChange() {
        emailStage = .entry
        emailPassword = ""
        emailNew = ""
        emailCode = ""
        emailError = nil
    }

    // MARK: - Phone

    /// Sets the contact number.
    public func savePhone() async {
        guard canSavePhone else { return }
        switch PhoneNumber.validate(phoneDraft) {
        case let .failure(reason):
            phoneError = reason.message
        case let .success(number):
            await writePhone(number, successMessage: "Contact number saved. It is not verified.")
        }
    }

    /// Clears the contact number.
    ///
    /// Still takes the current password: removing a contact detail is a change
    /// to the account, and the rule does not bend for the changes that happen to
    /// be subtractive.
    public func removePhone() async {
        guard !phonePassword.isEmpty, !isSavingPhone else { return }
        await writePhone(nil, successMessage: "Contact number removed.")
    }

    private func writePhone(_ number: String?, successMessage: String) async {
        isSavingPhone = true
        phoneError = nil
        defer { isSavingPhone = false }

        do {
            adopt(try await service.setPhone(currentPassword: phonePassword, phone: number))
            phonePassword = ""
            phoneDraft = ""
            presentedSheet = nil
            toast = .success(successMessage)
        } catch {
            guard !handledDeactivation(error) else { return }
            phoneError = APIError.wrapping(error).userMessage
        }
    }

    // MARK: - Export

    /// Downloads the export and writes it somewhere it can be shared from.
    public func exportAccount() async {
        guard !isExporting else { return }
        isExporting = true
        exportError = nil
        defer { isExporting = false }

        do {
            let data = try await service.exportData()
            exportFile = try Self.writeExport(data)
        } catch {
            guard !handledDeactivation(error) else { return }
            exportError = APIError.wrapping(error).userMessage
            toast = .error(exportError ?? "Couldn't download your data.")
        }
    }

    /// Writes the export where `ShareLink` can reach it.
    ///
    /// A fixed filename, overwritten each time: an export is a snapshot of an
    /// account, and leaving a pile of stale copies of somebody's whole account
    /// in the caches directory is the opposite of what this feature is for.
    static func writeExport(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sila-account-export.json")
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Forgets the downloaded copy.
    public func clearExport() {
        if let exportFile { try? FileManager.default.removeItem(at: exportFile) }
        exportFile = nil
    }

    // MARK: - Deletion

    /// Requests deletion. Does nothing unless both halves of the gate hold.
    public func requestDeletion() async {
        guard canConfirmDeletion else { return }
        isDeleting = true
        deletionError = nil
        defer { isDeleting = false }

        do {
            let schedule = try await service.requestDeletion(deletion)
            deletionSchedule = schedule
            deletion = DeletionConfirmation()
            presentedSheet = nil
            // The account is deactivated from this moment, so the only screen
            // that can still do anything is the one that undoes it.
            route = .recovery
            if let refreshed = try? await service.fetchAccount() { account = refreshed }
            analytics.track(.accountDeletionRouted, properties: ["source": "requested"])
        } catch {
            guard !handledDeactivation(error) else { return }
            deletionError = APIError.wrapping(error).userMessage
        }
    }

    // MARK: - Recovery

    /// Undoes a pending deletion and returns to the settings surface.
    public func cancelDeletion() async {
        guard !isCancellingDeletion else { return }
        isCancellingDeletion = true
        recoveryError = nil
        defer { isCancellingDeletion = false }

        do {
            let restored = try await service.cancelDeletion()
            account = restored
            profileDraft = ProfileDraft(account: restored)
            deletionSchedule = nil
            route = restored.isPendingDeletion ? .recovery : .settings
            toast = .success("Your account is back. Nothing was lost.")
        } catch {
            let wrapped = APIError.wrapping(error)
            if wrapped.code == .notPendingDeletion {
                // Nothing to cancel: somebody already did, on another device or
                // in another tab. That is the outcome they wanted, so it is
                // reported as one rather than as a failure.
                await reload()
                if route == .recovery { route = .settings }
                toast = .success("This account is not scheduled for deletion.")
                return
            }
            recoveryError = wrapped.userMessage
        }
    }

    /// Leaves the session, from the recovery screen.
    public func signOut() {
        onSignOut?()
    }

    // MARK: - Plumbing

    /// Adopts a server response as the new truth.
    private func adopt(_ loaded: Account) {
        account = loaded
        profileDraft = ProfileDraft(account: loaded)
        route = AccountRouting.route(for: loaded)
        if route == .recovery {
            analytics.track(.accountDeletionRouted, properties: ["source": "loaded"])
        }
    }

    /// Routes a deactivation error and reports whether it did.
    ///
    /// Called by every catch block. It returns `true` when the caller must not
    /// publish an error string, which is the whole mechanism: a deactivated
    /// account never reaches an alert with a Retry button, because retrying
    /// produces the same 403 forever and the person needs the cancel button
    /// instead.
    /// - Returns: `true` when the error was `account_deactivated`.
    @discardableResult
    private func handledDeactivation(_ error: Error) -> Bool {
        guard AccountRouting.route(forError: error) == .recovery else { return false }
        route = .recovery
        presentedSheet = nil
        clearFormErrors()
        analytics.track(.accountDeletionRouted, properties: ["source": "403"])
        return true
    }

    /// Wipes the per-form error strings and every password held in memory.
    private func clearFormErrors() {
        profileError = nil
        avatarError = nil
        passwordError = nil
        emailError = nil
        phoneError = nil
        deletionError = nil
        passwordCurrent = ""
        passwordNew = ""
        passwordRepeat = ""
        emailPassword = ""
        phonePassword = ""
        deletion = DeletionConfirmation()
    }

    /// Clears whatever a sheet collected when it closes.
    ///
    /// Passwords typed into a form the user backed out of have no reason to
    /// outlive the form.
    public func sheetDismissed(_ sheet: AccountSheet) {
        switch sheet {
        case .password:
            passwordCurrent = ""
            passwordNew = ""
            passwordRepeat = ""
            passwordError = nil
            passwordChanged = nil
        case .email:
            // Deliberately keeps ``emailStage``: a code that has already been
            // sent is still valid, and forcing a second one because a sheet was
            // dismissed would waste it.
            emailPassword = ""
            emailError = nil
        case .phone:
            phonePassword = ""
            phoneDraft = ""
            phoneError = nil
        case .delete:
            deletion = DeletionConfirmation()
            deletionError = nil
        }
    }
}
