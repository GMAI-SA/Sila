import Foundation

/// The production ``NetworkClient``, backed by `URLSession`.
///
/// Responsibilities are deliberately narrow: build the `URLRequest`, perform
/// it, and translate transport/HTTP failures into ``APIError``. It knows
/// nothing about auth, retries or refresh — that belongs to the Auth module.
public final class URLSessionNetworkClient: NetworkClient {

    private let baseURL: URL
    private let session: URLSession

    /// Told whenever a request comes back `403 account_suspended`.
    ///
    /// The one piece of routing this layer does, and it is here rather than in
    /// the view models on purpose. A suspended account is refused by *every*
    /// endpoint except two, so the alternative is a `catch` clause bolted onto
    /// every screen and a suspended account walking straight past whichever one
    /// its author forgot. One transport, one interception, no gaps.
    private let suspension: SuspensionReporting?

    /// Told whenever a request comes back `403 unverified`.
    ///
    /// Here for the same reason as ``suspension``, and since contract v9 for
    /// the same *shape* of reason: verification is now a condition of holding
    /// an account rather than a permission on top of one, so an unverified
    /// session is refused by every route bar four. One interception, no gaps.
    private let verification: VerificationGateReporting?

    /// Creates a client.
    /// - Parameters:
    ///   - baseURL: Defaults to ``AppConfig/apiBaseURL``.
    ///   - session: Injectable for tests. Defaults to an ephemeral-friendly default session.
    ///   - suspension: Told about `403 account_suspended`. `nil` in tests and
    ///     previews, where there is no app shell to route.
    ///   - verification: Told about `403 unverified`. `nil` for the same reason.
    public init(
        baseURL: URL = AppConfig.apiBaseURL,
        session: URLSession? = nil,
        suspension: SuspensionReporting? = nil,
        verification: VerificationGateReporting? = nil
    ) {
        self.baseURL = baseURL
        self.suspension = suspension
        self.verification = verification
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = AppConfig.requestTimeout
            configuration.waitsForConnectivity = false
            self.session = URLSession(configuration: configuration)
        }
    }

    public func send<Response: Decodable>(
        _ request: APIRequest,
        as type: Response.Type
    ) async throws -> Response {
        let data = try await perform(request)
        if data.isEmpty {
            throw APIError.decoding("Expected \(Response.self) but the response body was empty.")
        }
        do {
            return try JSONCoding.decoder.decode(Response.self, from: data)
        } catch {
            throw APIError.decoding("Could not decode \(Response.self): \(error)")
        }
    }

    public func send(_ request: APIRequest) async throws {
        _ = try await perform(request)
    }

    public func sendData(_ request: APIRequest) async throws -> Data {
        try await perform(request)
    }

    // MARK: - Plumbing

    private func perform(_ request: APIRequest) async throws -> Data {
        let urlRequest = try makeURLRequest(request)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch let error as URLError {
            throw APIError.transport(error.localizedDescription)
        } catch {
            throw APIError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw APIError.transport("The server returned a non-HTTP response.")
        }

        guard (200..<300).contains(http.statusCode) else {
            let error = Self.makeError(status: http.statusCode, data: data)
            // Reported *and* thrown. The caller still gets its error — it may
            // need to stop a spinner or roll a button back — but the app shell
            // has already been told to stop showing that screen at all.
            if error.code == .accountSuspended {
                suspension?.accountSuspended()
            }
            if error.code == .unverified {
                verification?.verificationRequired()
            }
            throw error
        }

        return data
    }

    private func makeURLRequest(_ request: APIRequest) throws -> URLRequest {
        let path = request.path.hasPrefix("/") ? String(request.path.dropFirst()) : request.path
        let resolved = baseURL.appendingPathComponent(path)

        var url = resolved
        if !request.query.isEmpty,
           var components = URLComponents(url: resolved, resolvingAgainstBaseURL: false) {
            components.queryItems = request.query
            url = components.url ?? resolved
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.timeoutInterval = AppConfig.requestTimeout
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")

        if let body = request.body {
            urlRequest.httpBody = body
            // A multipart body carries its boundary in the header; everything
            // else is JSON, which is what every pre-v5 call assumed.
            urlRequest.setValue(
                request.contentType ?? "application/json",
                forHTTPHeaderField: "Content-Type"
            )
        }
        if let token = request.accessToken, !token.isEmpty {
            urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return urlRequest
    }

    /// Translates an error body into the richest ``APIError`` we can manage.
    static func makeError(status: Int, data: Data) -> APIError {
        if let envelope = try? JSONDecoder().decode(APIErrorEnvelope.self, from: data) {
            return .api(
                code: APIErrorCode(serverCode: envelope.detail.code),
                message: envelope.detail.message,
                status: status
            )
        }
        if let envelope = try? JSONDecoder().decode(APIErrorStringEnvelope.self, from: data) {
            return .http(status: status, message: envelope.detail)
        }
        if status == 401 { return .unauthenticated }
        let raw = String(data: data, encoding: .utf8) ?? ""
        return .http(status: status, message: raw)
    }
}
