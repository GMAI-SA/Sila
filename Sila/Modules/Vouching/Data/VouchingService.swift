import Foundation

/// The production ``VouchingServiceProtocol``.
///
/// Talks to `/vouching/*`, `/vouch/*`, `/me/vouch` and the public landing
/// through the injected ``NetworkClient``. Holds no session state: the bearer
/// token is fetched per call, and the landing is read without one — a link
/// is opened by people who have not joined yet.
///
/// Analytics carry the outcome and the server's refusal code, never a
/// detail anybody typed.
public final class VouchingService: VouchingServiceProtocol {

    private let network: NetworkClient
    private let tokens: AccessTokenProviding
    private let analytics: AnalyticsClient

    public init(network: NetworkClient, tokens: AccessTokenProviding, analytics: AnalyticsClient) {
        self.network = network
        self.tokens = tokens
        self.analytics = analytics
    }

    // MARK: The voucher

    public func overview() async throws -> VouchingOverview {
        let token = try await tokens.accessToken()
        return try await network.send(APIRequest(path: "/vouching", accessToken: token), as: VouchingOverview.self)
    }

    public func mintInvite(label: String?, details: VouchDetails) async throws -> MintedInvite {
        let token = try await tokens.accessToken()
        let note = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = try APIRequest.json(
            "/vouching/invites",
            body: MintBody(
                label: (note?.isEmpty == false) ? note : nil,
                attestations: VoucherAttestations(knowsPersonally: true, adult: true, realName: true, singleAccount: true),
                details: details
            ),
            accessToken: token
        )
        do {
            let minted = try await network.send(request, as: MintedInvite.self)
            analytics.track(.vouchLinkCreated)
            return minted
        } catch {
            analytics.track(.vouchLinkRefused, properties: ["reason": Self.code(error)])
            throw error
        }
    }

    public func burnInvite(id: UUID) async throws {
        let token = try await tokens.accessToken()
        try await network.send(APIRequest(path: "/vouching/invites/\(Self.path(id))", method: .delete, accessToken: token))
        analytics.track(.vouchLinkBurned)
    }

    public func confirm(vouchId: UUID) async throws -> Vouch {
        try await act(.post, "/vouching/vouches/\(Self.path(vouchId))/confirm", event: .vouchConfirmed)
    }

    public func decline(vouchId: UUID) async throws -> Vouch {
        try await act(.post, "/vouching/vouches/\(Self.path(vouchId))/decline", event: .vouchDeclined)
    }

    public func withdraw(vouchId: UUID) async throws -> Vouch {
        try await act(.delete, "/vouching/vouches/\(Self.path(vouchId))", event: .vouchWithdrawn)
    }

    public func answer(vouchId: UUID, action: VouchAnswer, statement: String) async throws -> Vouch {
        let token = try await tokens.accessToken()
        let request = try APIRequest.json(
            "/vouching/vouches/\(Self.path(vouchId))/answer",
            body: AnswerBody(action: action.rawValue, statement: statement.trimmingCharacters(in: .whitespacesAndNewlines)),
            accessToken: token
        )
        let vouch = try await network.send(request, as: Vouch.self)
        analytics.track(.vouchAnswered, properties: ["result": action.rawValue])
        return vouch
    }

    // MARK: The link

    public func landing(token: String) async throws -> VouchInviteLanding {
        // No bearer token: the landing is public, and a guest opens it.
        let request = APIRequest(path: "/public/vouch-invites/\(token)")
        do {
            let landing = try await network.send(request, as: VouchInviteLanding.self)
            analytics.track(.vouchLinkOpened, properties: ["result": "open"])
            return landing
        } catch {
            analytics.track(.vouchLinkOpened, properties: ["result": Self.code(error)])
            throw error
        }
    }

    // MARK: The person

    public func claim(token: String, details: VouchDetails) async throws -> VouchState? {
        let access = try await tokens.accessToken()
        let request = try APIRequest.json(
            "/vouch/invites/\(token)/claim",
            body: ClaimBody(
                attestations: VoucheeAttestations(adult: true, realName: true, singleAccount: true, terms: true),
                details: details
            ),
            accessToken: access
        )
        do {
            let response = try await network.send(request, as: VouchClaimResponse.self)
            analytics.track(.vouchClaimed)
            return response.vouch
        } catch {
            // Which refusal, never which field: `details_mismatch` is
            // recorded as that and nothing more.
            analytics.track(.vouchClaimRefused, properties: ["reason": Self.code(error)])
            throw error
        }
    }

    public func myVouch() async throws -> MyVouch {
        let token = try await tokens.accessToken()
        return try await network.send(APIRequest(path: "/me/vouch", accessToken: token), as: MyVouch.self)
    }

    public func removeMyVouch() async throws {
        let token = try await tokens.accessToken()
        try await network.send(APIRequest(path: "/me/vouch", method: .delete, accessToken: token))
        analytics.track(.vouchRemoved)
    }

    // MARK: Helpers

    private func act(_ method: HTTPMethod, _ path: String, event: AnalyticsEvent) async throws -> Vouch {
        let token = try await tokens.accessToken()
        do {
            let vouch = try await network.send(APIRequest(path: path, method: method, accessToken: token), as: Vouch.self)
            analytics.track(event)
            return vouch
        } catch {
            analytics.track(event, properties: ["result": "refused", "reason": Self.code(error)])
            throw error
        }
    }

    private static func path(_ id: UUID) -> String { id.uuidString.lowercased() }

    private static func code(_ error: Error) -> String {
        (error as? APIError)?.code?.rawValue ?? "transport"
    }
}

// MARK: - Bodies

private struct MintBody: Encodable {
    let label: String?
    let attestations: VoucherAttestations
    let details: VouchDetails
}

private struct ClaimBody: Encodable {
    let attestations: VoucheeAttestations
    let details: VouchDetails
}

private struct AnswerBody: Encodable {
    let action: String
    let statement: String
}
