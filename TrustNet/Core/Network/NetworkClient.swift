import Foundation

/// HTTP verbs the client supports.
public enum HTTPMethod: String, Sendable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case patch = "PATCH"
    case delete = "DELETE"
}

/// A fully-formed, transport-agnostic API request.
///
/// The body is encoded to `Data` at construction time so the value stays
/// `Sendable` and tests can inspect exactly what would go over the wire.
public struct APIRequest: Sendable, Equatable {

    /// Path appended to ``AppConfig/apiBaseURL`` — e.g. `"/auth/login"`.
    public let path: String
    /// HTTP verb.
    public let method: HTTPMethod
    /// Pre-encoded JSON body, or `nil`.
    public let body: Data?
    /// Bearer token to attach, or `nil` for anonymous calls.
    public let accessToken: String?
    /// Query items appended to the URL.
    public let query: [URLQueryItem]

    /// Creates a request with an already-encoded body.
    public init(
        path: String,
        method: HTTPMethod = .get,
        body: Data? = nil,
        accessToken: String? = nil,
        query: [URLQueryItem] = []
    ) {
        self.path = path
        self.method = method
        self.body = body
        self.accessToken = accessToken
        self.query = query
    }

    /// Creates a request whose body is a JSON-encoded `Encodable`.
    ///
    /// Keys are converted to `snake_case` to match the backend.
    /// - Throws: ``APIError/decoding(_:)`` if encoding fails.
    public static func json<Body: Encodable>(
        _ path: String,
        method: HTTPMethod = .post,
        body: Body,
        accessToken: String? = nil
    ) throws -> APIRequest {
        do {
            let data = try JSONCoding.encoder.encode(body)
            return APIRequest(path: path, method: method, body: data, accessToken: accessToken)
        } catch {
            throw APIError.decoding("Could not encode request body: \(error.localizedDescription)")
        }
    }
}

/// Shared JSON coders configured for the SocialSA backend contract:
/// `snake_case` keys and ISO-8601 UTC timestamps.
public enum JSONCoding {

    /// Decoder used for every response body.
    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { source in
            let container = try source.singleValueContainer()
            let raw = try container.decode(String.self)
            if let date = iso8601WithFractionalSeconds.date(from: raw) { return date }
            if let date = iso8601Plain.date(from: raw) { return date }
            if let date = naiveUTC.date(from: raw) { return date }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unrecognised date format: \(raw)"
            )
        }
        return decoder
    }()

    /// Encoder used for every request body.
    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let iso8601WithFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let iso8601Plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// Some FastAPI endpoints emit naive UTC (`2026-08-28T09:15:00`) with no `Z`.
    private static let naiveUTC: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter
    }()
}

/// The mockable seam between features and the network.
///
/// Nothing in `Modules/` may construct a `URLSession` — every call goes through
/// an injected `NetworkClient`.
public protocol NetworkClient: Sendable {
    /// Sends a request and decodes the JSON response.
    func send<Response: Decodable>(_ request: APIRequest, as type: Response.Type) async throws -> Response
    /// Sends a request that returns no meaningful body (e.g. `204 No Content`).
    func send(_ request: APIRequest) async throws
}
