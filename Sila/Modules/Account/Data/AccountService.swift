import Foundation

/// The production ``AccountServiceProtocol``.
///
/// Talks to contract v5 through the injected ``NetworkClient``. Like every other
/// service it holds no session state: the bearer token is fetched per call from
/// ``AccessTokenProviding``.
public final class AccountService: AccountServiceProtocol {

    private let network: NetworkClient
    private let tokens: AccessTokenProviding
    private let analytics: AnalyticsClient

    /// - Parameters:
    ///   - network: HTTP transport.
    ///   - tokens: Supplies the bearer token.
    ///   - analytics: Event sink.
    public init(network: NetworkClient, tokens: AccessTokenProviding, analytics: AnalyticsClient) {
        self.network = network
        self.tokens = tokens
        self.analytics = analytics
    }

    // MARK: - Profile

    public func fetchAccount() async throws -> Account {
        let token = try await tokens.accessToken()
        return try await network.send(
            APIRequest(path: "/me/account", accessToken: token),
            as: Account.self
        )
    }

    /// - Note: `PATCH /me/profile` answers a `UserSummaryOut`, which carries no
    ///   `bio`, `email` or `phone` — it is the shape written for post authors,
    ///   not for this screen. Rather than fold a partial response into a local
    ///   copy and call the result "saved", the write is followed by a read, so
    ///   what the screen shows afterwards is what the server actually holds.
    public func updateProfile(_ update: ProfileUpdate) async throws -> Account {
        guard !update.isEmpty else { return try await fetchAccount() }
        let token = try await tokens.accessToken()
        try await network.send(
            APIRequest.json("/me/profile", method: .patch, body: update, accessToken: token)
        )
        analytics.track(.accountProfileSaved, properties: [
            "handle": String(update.handle != nil),
            "display_name": String(update.displayName != nil),
            "bio": String(update.bio != nil),
            "is_private": String(update.isPrivate != nil)
        ])
        return try await fetchAccount()
    }

    // MARK: - Avatar

    public func uploadAvatar(_ image: AvatarImage) async throws -> Account {
        let token = try await tokens.accessToken()
        let request = APIRequest.multipart(
            "/me/avatar",
            method: .put,
            form: AvatarUpload.form(for: image),
            accessToken: token
        )
        let account = try await network.send(request, as: Account.self)
        analytics.track(.accountAvatarUploaded, properties: [
            "bytes": String(image.data.count),
            "format": AvatarUpload.sniffFormat(image.data).rawValue
        ])
        return account
    }

    public func removeAvatar() async throws -> Account {
        let token = try await tokens.accessToken()
        let account = try await network.send(
            APIRequest(path: "/me/avatar", method: .delete, accessToken: token),
            as: Account.self
        )
        analytics.track(.accountAvatarRemoved)
        return account
    }

    // MARK: - Credentials

    public func changePassword(
        currentPassword: String,
        newPassword: String
    ) async throws -> PasswordChangeResult {
        let token = try await tokens.accessToken()
        let request = try APIRequest.json(
            "/me/password",
            method: .post,
            body: PasswordChangeRequest(currentPassword: currentPassword, newPassword: newPassword),
            accessToken: token
        )
        let result = try await network.send(request, as: PasswordChangeResult.self)
        analytics.track(.accountPasswordChanged)
        return result
    }

    public func requestEmailChange(
        currentPassword: String,
        newEmail: String
    ) async throws -> EmailChangeSent {
        let token = try await tokens.accessToken()
        let request = try APIRequest.json(
            "/me/email/request",
            method: .post,
            body: EmailChangeRequest(currentPassword: currentPassword, newEmail: newEmail),
            accessToken: token
        )
        let sent = try await network.send(request, as: EmailChangeSent.self)
        analytics.track(.accountEmailChangeRequested)
        return sent
    }

    public func confirmEmailChange(newEmail: String, code: String) async throws -> Account {
        let token = try await tokens.accessToken()
        let request = try APIRequest.json(
            "/me/email/confirm",
            method: .post,
            body: EmailChangeConfirmation(newEmail: newEmail, code: code),
            accessToken: token
        )
        let account = try await network.send(request, as: Account.self)
        analytics.track(.accountEmailChanged)
        return account
    }

    public func setPhone(currentPassword: String, phone: String?) async throws -> Account {
        let token = try await tokens.accessToken()
        let request = try APIRequest.json(
            "/me/phone",
            method: .put,
            body: PhoneUpdate(currentPassword: currentPassword, phone: phone),
            accessToken: token
        )
        let account = try await network.send(request, as: Account.self)
        analytics.track(.accountPhoneChanged, properties: ["cleared": String(phone == nil)])
        return account
    }

    // MARK: - Data

    public func exportData() async throws -> Data {
        let token = try await tokens.accessToken()
        let data = try await network.sendData(
            APIRequest(path: "/me/export", accessToken: token)
        )
        analytics.track(.accountExported, properties: ["bytes": String(data.count)])
        return data
    }

    // MARK: - Deletion

    public func requestDeletion(_ confirmation: DeletionConfirmation) async throws -> DeletionSchedule {
        let token = try await tokens.accessToken()
        let request = try APIRequest.json(
            "/me/delete",
            method: .post,
            body: confirmation.request,
            accessToken: token
        )
        let schedule = try await network.send(request, as: DeletionSchedule.self)
        analytics.track(.accountDeletionRequested, properties: [
            "grace_days": String(schedule.graceDays)
        ])
        return schedule
    }

    public func cancelDeletion() async throws -> Account {
        let token = try await tokens.accessToken()
        let account = try await network.send(
            APIRequest(path: "/me/delete/cancel", method: .post, accessToken: token),
            as: Account.self
        )
        analytics.track(.accountDeletionCancelled)
        return account
    }
}
