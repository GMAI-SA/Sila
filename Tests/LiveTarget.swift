import XCTest
@testable import Sila

/// Where the live tests run: the staging API, never production.
///
/// Production runs with dev mode off, so `/api/v1/dev/*` (the code peek, the
/// account hook) does not exist there, and nothing here may create accounts,
/// posts or anything else on it. Staging answers on 127.0.0.1:8101 on the
/// server and is reachable only through an SSH tunnel:
///
/// ```
/// ssh -N -L 8101:127.0.0.1:8101 -i ~/.ssh/geniusai_new ubuntu@185.216.21.10 &
/// TEST_RUNNER_SILA_LIVE_API=1 TEST_RUNNER_SILA_API_ORIGIN=http://127.0.0.1:8101 \
///   xcodebuild … test -only-testing:SilaTests/LiveVouchingTests
/// ```
///
/// Suites that sign in as an existing account also need
/// `TEST_RUNNER_SILA_LIVE_EMAIL` / `_PASSWORD` for an account **on staging**.
/// The suites that make their own `@example.com` accounts need nothing else.
///
/// Only `TEST_RUNNER_`-prefixed variables reach the simulator's test process;
/// the prefix is stripped on the way in. The same `SILA_API_ORIGIN` name is
/// what the web repo's live specs read.
enum LiveTarget {

    /// Production's hosts, which a live test never talks to.
    private static let productionHosts = ["gmai.sa"]

    private static var environment: [String: String] { ProcessInfo.processInfo.environment }

    /// `SILA_LIVE_API=1`: live tests are opt-in.
    static var isOptedIn: Bool { environment["SILA_LIVE_API"] == "1" }

    /// The staging API's base (`…/api/v1`), from `SILA_API_ORIGIN`.
    ///
    /// Skips the test when live tests are not opted into, and fails it when
    /// they are but no staging origin is set, or the origin is production's.
    static func api(file: StaticString = #filePath, line: UInt = #line) throws -> URL {
        guard isOptedIn else {
            throw XCTSkip("Live API tests are opt-in — set SILA_LIVE_API=1 and SILA_API_ORIGIN")
        }
        guard let raw = environment["SILA_API_ORIGIN"], !raw.isEmpty else {
            throw LiveTargetError(
                "Live tests run against the staging API: open the tunnel "
                + "(ssh -N -L 8101:127.0.0.1:8101 -i ~/.ssh/geniusai_new ubuntu@185.216.21.10) "
                + "and set TEST_RUNNER_SILA_API_ORIGIN=http://127.0.0.1:8101."
            )
        }
        guard let url = AppConfig.apiBaseURL(origin: raw) else {
            throw LiveTargetError("SILA_API_ORIGIN=\(raw) is not an origin the app accepts (HTTPS, or HTTP to 127.0.0.1).")
        }
        if let host = url.host?.lowercased(),
           productionHosts.contains(where: { host == $0 || host.hasSuffix(".\($0)") }) {
            throw LiveTargetError("Live tests never run against production (SILA_API_ORIGIN=\(raw)).")
        }
        return url
    }

    /// An existing staging account's credentials, or a skip saying which
    /// variables to set.
    static func credentials() throws -> (email: String, password: String) {
        guard let email = environment["SILA_LIVE_EMAIL"], let password = environment["SILA_LIVE_PASSWORD"] else {
            throw XCTSkip("Set SILA_LIVE_EMAIL and SILA_LIVE_PASSWORD for an account on the staging API")
        }
        return (email, password)
    }

    /// The app's own transport, pointed at staging.
    static func network() -> URLSessionNetworkClient {
        // `api()` has already passed in the suite's setUp, or the test would
        // not be running; the placeholder only keeps this non-throwing.
        URLSessionNetworkClient(baseURL: (try? api()) ?? URL(fileURLWithPath: "/live-target-unset"))
    }

    /// A staging dev route (`/api/v1/dev/…`), over the tunnel.
    ///
    /// - Parameters:
    ///   - path: The route under `/dev`, e.g. `otp/peek`.
    ///   - query: Query items.
    ///   - body: A JSON body; its presence makes the request a `POST`.
    static func dev(_ path: String, query: [URLQueryItem] = [], body: [String: Any]? = nil) async throws -> [String: Any] {
        guard !path.contains("purge-test-users") else {
            // Shared by every suite on staging: removing other runs' accounts
            // mid-test is never a helper's call.
            throw LiveTargetError("the test-user purge is not run from the iOS tests")
        }
        let base = try api().appendingPathComponent("dev")
        var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw LiveTargetError("dev \(path) \(status): \(String(decoding: data, as: UTF8.self))")
        }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// A link staging minted, on the app's own web origin.
    ///
    /// Staging mints links on whatever web origin it is configured with; the
    /// app opens links on ``AppConfig/webBaseURLString``. The path and query
    /// are what the app reads, so those are kept.
    static func onApp(_ minted: URL) -> URL {
        guard var components = URLComponents(string: AppConfig.webBaseURLString),
              let source = URLComponents(url: minted, resolvingAgainstBaseURL: false) else {
            return minted
        }
        components.path = source.path
        components.query = source.query
        return components.url ?? minted
    }
}

/// A live test that cannot run as configured. Fails the test, loudly.
struct LiveTargetError: LocalizedError, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
    var errorDescription: String? { description }
}
