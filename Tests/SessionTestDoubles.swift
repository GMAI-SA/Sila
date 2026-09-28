import XCTest
@testable import Sila

// Doubles shared by the session tests: a transport a test scripts request by
// request, wire-shaped auth bodies, and leftovers of the test's own.

/// A ``NetworkClient`` whose answers each test writes, request by request.
///
/// Unlike ``StubNetworkClient``'s queue, the handler sees the request, so a
/// test can answer `/auth/refresh` and `/auth/me` differently, delay one of
/// them, or change its mind between calls.
final class ScriptedNetwork: NetworkClient, @unchecked Sendable {

    typealias Handler = @Sendable (APIRequest) async throws -> String

    private let lock = NSLock()
    private var seen: [APIRequest] = []
    private let handler: Handler

    init(_ handler: @escaping Handler) {
        self.handler = handler
    }

    /// Every request so far, in order.
    var requests: [APIRequest] { lock.withLock { seen } }

    /// How many requests went to `path`.
    func count(_ path: String) -> Int {
        requests.filter { $0.path == path }.count
    }

    func send<Response: Decodable>(_ request: APIRequest, as type: Response.Type) async throws -> Response {
        let json = try await answer(request)
        do {
            return try JSONCoding.decoder.decode(Response.self, from: Data(json.utf8))
        } catch {
            // As the real client reports it.
            throw APIError.decoding("Could not decode \(Response.self): \(error)")
        }
    }

    func send(_ request: APIRequest) async throws {
        _ = try await answer(request)
    }

    func sendData(_ request: APIRequest) async throws -> Data {
        Data(try await answer(request).utf8)
    }

    private func answer(_ request: APIRequest) async throws -> String {
        lock.withLock { seen.append(request) }
        return try await handler(request)
    }
}

/// Wire-shaped bodies for the auth endpoints.
enum AuthFixtures {

    static let userID = "11111111-2222-3333-4444-555555555555"

    static func userJSON(status: String = "verified", email: String = "aziz@example.com") -> String {
        """
        {"id": "\(userID)", "email": "\(email)", "email_verified": true,
         "verification_status": "\(status)", "created_at": "2026-01-01T00:00:00Z",
         "handle": "aziz", "country_code": \(status == "verified" ? "\"SA\"" : "null")}
        """
    }

    static func pairJSON(access: String, refresh: String, expiresIn: TimeInterval = 1800) -> String {
        let expiry = ISO8601DateFormatter().string(from: Date().addingTimeInterval(expiresIn))
        return """
        {"access_token": "\(access)", "refresh_token": "\(refresh)", "expires_at": "\(expiry)",
         "user": \(userJSON())}
        """
    }

    static func pair(
        access: String = "access-0",
        refresh: String = "refresh-0",
        expiresIn: TimeInterval = 1800,
        status: VerificationStatus = .verified
    ) -> TokenPair {
        TokenPair(
            token: AuthToken(accessToken: access, refreshToken: refresh, expiresAt: Date().addingTimeInterval(expiresIn)),
            user: AuthUser(
                id: UUID(uuidString: userID)!,
                email: "aziz@example.com",
                displayName: nil,
                emailVerified: true,
                verificationStatus: status,
                createdAt: Date(),
                handle: "aziz",
                countryCode: status == .verified ? "SA" : nil
            )
        )
    }

    /// The server's refusal of a refresh token it has already seen.
    static let refused = APIError.api(code: .unauthorized, message: "Invalid or expired refresh token", status: 401)
}

extension SessionLeftovers {
    /// Leftovers in a directory and cache of the test's own, so a test never
    /// sweeps the host app's.
    static func isolated() -> SessionLeftovers {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("leftovers-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return SessionLeftovers(
            directory: directory,
            responseCache: URLCache(memoryCapacity: 1 << 20, diskCapacity: 0, diskPath: nil),
            videoUploads: directory.appendingPathComponent("VideoUploads", isDirectory: true)
        )
    }
}
