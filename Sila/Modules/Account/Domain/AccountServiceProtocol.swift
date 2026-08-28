import Foundation

/// Everything the Account module can ask the backend to do (contract v5).
///
/// The seam ``AccountScreen`` depends on. ``AccountService`` and
/// ``AccountServiceMock`` are interchangeable behind it, which is what lets the
/// destructive paths — a password change, a deletion — be driven end to end in
/// tests without a live account to break.
///
/// **Every credential-changing method takes the current password.** Not as a
/// convenience for the caller: it is the contract. A session token proves
/// somebody signed in once, not that whoever is holding the phone now is the
/// account holder, and an unattended unlocked device must not be enough to take
/// an account over by swapping its email. The parameter is non-optional on
/// purpose, so there is no overload that quietly skips it.
public protocol AccountServiceProtocol: Sendable {

    /// The whole account, `GET /me/account`.
    ///
    /// Works while the account is pending deletion — it is one of only two
    /// endpoints that do — and reports the deletion timestamps when it is.
    func fetchAccount() async throws -> Account

    /// Writes the profile fields, `PATCH /me/profile`.
    ///
    /// - Parameter update: Only the fields set are sent.
    /// - Returns: The account as the server holds it afterwards.
    /// - Throws: ``APIError`` with ``APIErrorCode/invalidHandle`` (400) or
    ///   ``APIErrorCode/handleTaken`` (409).
    func updateProfile(_ update: ProfileUpdate) async throws -> Account

    /// Replaces the profile picture, `PUT /me/avatar`.
    ///
    /// - Parameter image: Already checked against ``AvatarUpload/maximumBytes``.
    /// - Returns: The account, carrying the new avatar path.
    /// - Throws: ``APIErrorCode/invalidImage`` (400) or
    ///   ``APIErrorCode/imageTooLarge`` (413).
    func uploadAvatar(_ image: AvatarImage) async throws -> Account

    /// Removes the profile picture, `DELETE /me/avatar`.
    func removeAvatar() async throws -> Account

    /// Changes the password, `POST /me/password`.
    ///
    /// Signs every other session out, which is the point: a password change is
    /// what somebody does when they think a session is not theirs.
    /// - Throws: ``APIErrorCode/invalidCredentials`` (403) when the current
    ///   password is wrong, ``APIErrorCode/passwordUnchanged`` (400) when the
    ///   new one matches the old.
    func changePassword(currentPassword: String, newPassword: String) async throws -> PasswordChangeResult

    /// Starts an email change, `POST /me/email/request`.
    ///
    /// The code goes to the **new** address. Sending it to the current mailbox
    /// would only prove control of a mailbox the session already implies.
    /// - Throws: ``APIErrorCode/invalidCredentials`` (403),
    ///   ``APIErrorCode/emailUnchanged`` (400), ``APIErrorCode/emailTaken`` (409).
    func requestEmailChange(currentPassword: String, newEmail: String) async throws -> EmailChangeSent

    /// Finishes an email change, `POST /me/email/confirm`.
    ///
    /// - Throws: the OTP codes, and ``APIErrorCode/emailTaken`` (409) — the
    ///   address is re-checked at this moment, because it can be claimed by
    ///   somebody else while the code sits in an inbox.
    func confirmEmailChange(newEmail: String, code: String) async throws -> Account

    /// Sets or clears the contact number, `PUT /me/phone`.
    ///
    /// - Parameter phone: E.164, or `nil` to remove the number.
    /// - Throws: ``APIErrorCode/invalidCredentials`` (403),
    ///   ``APIErrorCode/invalidPhone`` (400).
    func setPhone(currentPassword: String, phone: String?) async throws -> Account

    /// Downloads the data export, `GET /me/export`.
    ///
    /// - Returns: The response body byte for byte. Deliberately not decoded into
    ///   client types and re-serialised: an export is a copy of what the server
    ///   holds, and re-encoding it would hand the user a document this app
    ///   invented rather than the one the server sent.
    func exportData() async throws -> Data

    /// Requests deletion, `POST /me/delete`.
    ///
    /// - Parameter confirmation: Must already satisfy
    ///   ``DeletionConfirmation/isConfirmable``.
    /// - Throws: ``APIErrorCode/confirmationRequired`` (400) — checked by the
    ///   server *before* the password, so a bad confirmation word is reported
    ///   even when the password is also wrong.
    func requestDeletion(_ confirmation: DeletionConfirmation) async throws -> DeletionSchedule

    /// Undoes a pending deletion, `POST /me/delete/cancel`.
    ///
    /// - Throws: ``APIErrorCode/notPendingDeletion`` (400) when there is nothing
    ///   to cancel.
    func cancelDeletion() async throws -> Account
}
