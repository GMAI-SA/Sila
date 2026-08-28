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
    /// Pre-encoded body, or `nil`.
    public let body: Data?
    /// Bearer token to attach, or `nil` for anonymous calls.
    public let accessToken: String?
    /// Query items appended to the URL.
    public let query: [URLQueryItem]
    /// `Content-Type` for ``body``.
    ///
    /// `nil` means `application/json`, which is what every call built before
    /// contract v5 assumed. Only the avatar upload sets it, and it sets it to
    /// the multipart type **with the boundary**, because a multipart body is
    /// unparseable without one.
    public let contentType: String?

    /// Creates a request with an already-encoded body.
    public init(
        path: String,
        method: HTTPMethod = .get,
        body: Data? = nil,
        accessToken: String? = nil,
        query: [URLQueryItem] = [],
        contentType: String? = nil
    ) {
        self.path = path
        self.method = method
        self.body = body
        self.accessToken = accessToken
        self.query = query
        self.contentType = contentType
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

    /// Creates a request carrying a `multipart/form-data` body.
    ///
    /// The only endpoint that needs one is `PUT /me/avatar`, but it goes
    /// through the same seam as everything else: a bare `URLSession` upload
    /// would be invisible to ``NetworkClient`` mocks and to the deactivation
    /// interceptor every other call is subject to.
    /// - Parameters:
    ///   - path: Path appended to ``AppConfig/apiBaseURL``.
    ///   - method: HTTP verb. Defaults to `PUT`.
    ///   - form: The assembled form. Its boundary travels in the header.
    ///   - accessToken: Bearer token.
    public static func multipart(
        _ path: String,
        method: HTTPMethod = .put,
        form: MultipartFormData,
        accessToken: String? = nil
    ) -> APIRequest {
        APIRequest(
            path: path,
            method: method,
            body: form.encoded(),
            accessToken: accessToken,
            contentType: form.contentType
        )
    }
}

// MARK: - Multipart

/// Builds an RFC-7578 `multipart/form-data` body.
///
/// Deliberately a value type that produces `Data` eagerly, for the same reason
/// ``APIRequest`` encodes its JSON at construction time: a test can assert on
/// the exact bytes that would go over the wire, and the request stays
/// `Sendable`.
///
/// The boundary is injectable so those assertions can be deterministic.
public struct MultipartFormData: Sendable, Equatable {

    /// Delimiter between parts. Never appears inside binary content in
    /// practice — it carries a UUID.
    public let boundary: String

    /// The parts appended so far, without the closing delimiter.
    private var parts = Data()

    /// Creates an empty form.
    /// - Parameter boundary: Defaults to a fresh random delimiter.
    public init(boundary: String = "SilaFormBoundary-\(UUID().uuidString)") {
        self.boundary = boundary
    }

    /// The `Content-Type` header value, including the boundary.
    public var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    /// Appends a file part.
    ///
    /// - Parameters:
    ///   - data: The bytes, copied in verbatim — nothing re-encodes them.
    ///   - name: The form field name. The account API expects `file`.
    ///   - filename: Reported to the server. It is a label, not a promise: the
    ///     backend decides what the file is by decoding it.
    ///   - mimeType: Declared content type of the part.
    public mutating func appendFile(
        _ data: Data,
        name: String,
        filename: String,
        mimeType: String
    ) {
        parts.append(Data("--\(boundary)\r\n".utf8))
        parts.append(Data(
            "Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".utf8
        ))
        parts.append(Data("Content-Type: \(mimeType)\r\n\r\n".utf8))
        parts.append(data)
        parts.append(Data("\r\n".utf8))
    }

    /// The complete body: every part plus the closing delimiter.
    public func encoded() -> Data {
        var body = parts
        body.append(Data("--\(boundary)--\r\n".utf8))
        return body
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
    /// Sends a request and returns the response body untouched.
    ///
    /// For payloads the client deliberately does not model. `GET /me/export`
    /// is the only one: a data export is a copy of what the server holds, so
    /// decoding it into client types and re-serialising would hand the user a
    /// document this app invented rather than the one the server sent.
    func sendData(_ request: APIRequest) async throws -> Data
}
