import Foundation

/// The production ``VerificationServiceProtocol``.
///
/// Talks to `/verification/*` through the injected ``NetworkClient``. Like
/// every other service it holds no session state: the bearer token is fetched
/// per call from ``AccessTokenProviding``.
///
/// **Privacy.** The national ID passes through ``startNafath(nationalID:)``
/// into the request body and nowhere else; the zone passes through
/// ``submitDocument(_:)`` the same way. The analytics events emitted here
/// deliberately carry no properties derived from either — not the number, not
/// a hash, not a prefix, not the nationality.
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

    // MARK: The claim

    public func setNationality(_ code: String) async throws -> VerificationStatusReport {
        let token = try await tokens.accessToken()
        let request = try APIRequest.json(
            "/verification/nationality",
            body: NationalityBody(countryCode: code.uppercased()),
            accessToken: token
        )
        return try await network.send(request, as: VerificationStatusReport.self)
    }

    // MARK: Nafath

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

    // MARK: Document + selfie

    public func submitDocument(_ submission: DocumentSubmission) async throws -> DocumentCase {
        let token = try await tokens.accessToken()
        let request = APIRequest.multipart(
            "/verification/document",
            method: .post,
            form: submission.form(),
            accessToken: token
        )
        do {
            let documentCase = try await network.send(request, as: DocumentCase.self)
            analytics.track(.documentSubmitted, properties: [
                "document_type": submission.documentType.wireValue,
                "mrz": submission.mrz?.isValid == true ? "read" : "none",
                "liveness": String(submission.challenges.count)
            ])
            return documentCase
        } catch {
            let code = (error as? APIError)?.code?.rawValue ?? "transport"
            analytics.track(.documentSubmitRefused, properties: ["code": code])
            throw error
        }
    }

    // MARK: Contesting a decision

    public func appealVerification(message: String) async throws -> VerificationAppealReceipt {
        let token = try await tokens.accessToken()
        let request = try APIRequest.json(
            "/verification/appeal",
            method: .post,
            body: AppealRequest(message: message),
            accessToken: token
        )
        let data = try await network.sendData(request)
        analytics.track(.appealSubmitted)
        // The server answers `{id, status}` with no timestamp; the appeal is on
        // file the moment this returns, so "now" is the honest date — and an
        // unreadable body is still an appeal that reached the server.
        guard !data.isEmpty,
              let decoded = try? JSONCoding.decoder.decode(VerificationAppealReceipt.self, from: data)
        else {
            return VerificationAppealReceipt(status: .pending, submittedAt: Date())
        }
        return VerificationAppealReceipt(id: decoded.id, status: decoded.status, submittedAt: decoded.submittedAt ?? Date())
    }

    public func latestDocumentCase() async throws -> DocumentCase? {
        let token = try await tokens.accessToken()
        let request = APIRequest(path: "/verification/document", accessToken: token)
        do {
            return try await network.send(request, as: DocumentCase.self)
        } catch let error as APIError where error.code == .notFound {
            return nil
        } catch APIError.http(status: 404, message: _) {
            return nil
        }
    }
}
