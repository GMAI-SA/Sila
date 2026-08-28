import Foundation

/// The production ``NetworkClient``, backed by `URLSession`.
///
/// Responsibilities are deliberately narrow: build the `URLRequest`, perform
/// it, and translate transport/HTTP failures into ``APIError``. It knows
/// nothing about auth, retries or refresh — that belongs to the Auth module.
public final class URLSessionNetworkClient: NetworkClient {

    private let baseURL: URL
    private let session: URLSession

    /// Creates a client.
    /// - Parameters:
    ///   - baseURL: Defaults to ``AppConfig/apiBaseURL``.
    ///   - session: Injectable for tests. Defaults to an ephemeral-friendly default session.
    public init(baseURL: URL = AppConfig.apiBaseURL, session: URLSession? = nil) {
        self.baseURL = baseURL
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
            throw Self.makeError(status: http.statusCode, data: data)
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
