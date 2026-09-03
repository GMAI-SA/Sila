import Foundation

/// The production ``VerificationServiceProtocol``.
///
/// Talks to `/verification/nafath/*` through the injected ``NetworkClient``.
/// Like every other service it holds no session state: the bearer token is
/// fetched per call from ``AccessTokenProviding``.
///
/// **Privacy.** The national ID passes through ``startNafath(nationalID:)``
/// into the request body and nowhere else. The analytics events emitted here
/// deliberately carry no properties derived from it — not the number, not a
/// hash, not a prefix.
public final class VerificationService: VerificationServiceProtocol {

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

    public func startNafath(nationalID: String) async throws -> NafathStart {
        let token = try await tokens.accessToken()
        let request = try APIRequest.json(
            "/verification/nafath/start",
            body: NafathStartBody(nationalId: NationalID.normalised(nationalID)),
            accessToken: token
        )
        do {
            let start = try await network.send(request, as: NafathStart.self)
            analytics.track(.nafathStarted)
            return start
        } catch {
            // The structured code only. Never the input.
            let code = (error as? APIError)?.code?.rawValue ?? "transport"
            analytics.track(.nafathStartRefused, properties: ["code": code])
            throw error
        }
    }

    public func pollNafath(requestID: String) async throws -> NafathPoll {
        let token = try await tokens.accessToken()
        let request = APIRequest(
            path: "/verification/nafath/\(requestID)",
            accessToken: token
        )
        return try await network.send(request, as: NafathPoll.self)
    }
}
