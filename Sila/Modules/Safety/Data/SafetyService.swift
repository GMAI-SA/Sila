import Foundation

/// The production ``SafetyServiceProtocol``.
///
/// Talks to the block / mute / report / suspension endpoints through the
/// injected ``NetworkClient``. Like every other service it holds no session
/// state: the bearer token is fetched per call from ``AccessTokenProviding``.
public final class SafetyService: SafetyServiceProtocol {

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

    // MARK: - Blocking

    public func setBlocked(_ blocked: Bool, handle: String) async throws -> Bool {
        let component = try component(handle)
        let token = try await tokens.accessToken()
        let state = try await toggle(
            path: "/users/\(component)/block",
            desired: blocked,
            token: token
        )
        analytics.track(blocked ? .blockAdded : .blockRemoved)
        return state
    }

    public func fetchBlocked() async throws -> [SafetyRelation] {
        let token = try await tokens.accessToken()
        return try await network.send(
            APIRequest(path: "/me/blocks", accessToken: token),
            as: SafetyRelationList.self
        ).relations
    }

    // MARK: - Muting

    public func setMuted(_ muted: Bool, handle: String) async throws -> Bool {
        let component = try component(handle)
        let token = try await tokens.accessToken()
        let state = try await toggle(
            path: "/users/\(component)/mute",
            desired: muted,
            token: token
        )
        analytics.track(muted ? .muteAdded : .muteRemoved)
        return state
    }

    public func fetchMuted() async throws -> [SafetyRelation] {
        let token = try await tokens.accessToken()
        return try await network.send(
            APIRequest(path: "/me/mutes", accessToken: token),
            as: SafetyRelationList.self
        ).relations
    }

    // MARK: - Reporting

    public func submitReport(_ request: ReportRequest) async throws -> ReportReceipt {
        let token = try await tokens.accessToken()
        let receipt = try await network.send(
            try APIRequest.json("/reports", method: .post, body: request, accessToken: token),
            as: ReportReceipt.self
        )
        // The reason travels with the event; the free text never does. What
        // somebody typed into a report is between them and a reviewer.
        analytics.track(.reportSubmitted, properties: [
            "reason": request.reason.rawValue,
            "subject": request.postId == nil ? "user" : "post",
            "support": String(receipt.support != nil)
        ])
        return receipt
    }

    public func fetchReports() async throws -> [Report] {
        let token = try await tokens.accessToken()
        return try await network.send(
            APIRequest(path: "/me/reports", accessToken: token),
            as: ReportList.self
        ).reports
    }

    // MARK: - Suspension

    public func fetchSuspension() async throws -> Suspension {
        let token = try await tokens.accessToken()
        return try await network.send(
            APIRequest(path: "/me/suspension", accessToken: token),
            as: Suspension.self
        )
    }

    public func submitAppeal(message: String) async throws -> SuspensionAppeal {
        let token = try await tokens.accessToken()
        let request = try APIRequest.json(
            "/me/appeal",
            method: .post,
            body: AppealRequest(message: message),
            accessToken: token
        )
        let data = try await network.sendData(request)
        analytics.track(.appealSubmitted)
        // The contract does not pin this response down. An appeal that reached
        // the server is on file whatever came back, so an unreadable body
        // becomes "pending" rather than an error that would invite a second
        // attempt the server would refuse with `already_appealed`.
        guard !data.isEmpty,
              let decoded = try? JSONCoding.decoder.decode(SuspensionAppeal.self, from: data)
        else {
            return SuspensionAppeal(submittedAt: nil, status: .pending)
        }
        return decoded
    }

    // MARK: - Plumbing

    /// Sends an idempotent toggle and reads the state back.
    ///
    /// Uses ``NetworkClient/sendData(_:)`` rather than the decoding overload
    /// because a `204 No Content` is a perfectly good answer to "block this
    /// person" and must not be turned into a decoding error. When the body says
    /// nothing, the state is the one that was asked for — which is not optimism:
    /// the call returned 2xx, and an idempotent write that succeeded leaves
    /// exactly the state it was given.
    private func toggle(path: String, desired: Bool, token: String?) async throws -> Bool {
        let data = try await network.sendData(
            APIRequest(path: path, method: desired ? .post : .delete, accessToken: token)
        )
        guard !data.isEmpty,
              let decoded = try? JSONCoding.decoder.decode(SafetyToggleResponse.self, from: data)
        else {
            return desired
        }
        return decoded.state(requested: desired)
    }

    /// The handle as a safe path component.
    ///
    /// A handle that survives sanitisation as nothing at all is reported as the
    /// 404 it would be anyway — and, more importantly, without building
    /// `/users//block`, which is a different endpoint entirely. Same rule as
    /// ``ProfileService``.
    private func component(_ handle: String) throws -> String {
        let component = Handle.pathComponent(handle)
        guard !component.isEmpty else {
            throw APIError.api(
                code: .userNotFound,
                message: "No account with that handle",
                status: 404
            )
        }
        return component
    }
}
