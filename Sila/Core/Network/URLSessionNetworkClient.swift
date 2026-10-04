import Foundation

/// The production ``NetworkClient``, backed by `URLSession`.
///
/// Responsibilities are deliberately narrow: build the `URLRequest`, perform
/// it, and translate transport/HTTP failures into ``APIError``. It knows
/// nothing about auth, retries or refresh — that belongs to the Auth module.
public final class URLSessionNetworkClient: NetworkClient {

    private let baseURL: URL
    /// The transport. Internal so a test can assert how it is configured.
    let session: URLSession

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
    ///   - session: Injectable for tests. Defaults to a session built from
    ///     ``makeConfiguration()``, which caches nothing.
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
        self.session = session ?? URLSession(configuration: Self.makeConfiguration())
    }

    /// How every default client's session is configured.
    static func makeConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        // Nothing the API answers is written to disk. With the default
        // configuration every small authenticated GET went into the shared
        // `Cache.db` — `/auth/me` with the email and the verified legal name
        // (hidden or not), conversations, messages, notifications — because
        // the backend sends no `Cache-Control` and URLCache keeps a response
        // that does not say `no-store`. That file has only default data
        // protection and outlives a sign-out, so the next person on the phone
        // could read the last one's messages out of it.
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = AppConfig.requestTimeout
        // A phone changes networks constantly — leaving Wi-Fi for cellular,
        // walking out of a lift. Failing the instant there is no route
        // turned every one of those moments into an error somebody had to
        // dismiss; waiting for the route to come back, briefly, turns them
        // into a pause nobody notices. The resource timeout is the cap on
        // that wait, so an offline phone still hears "no connection"
        // rather than nothing.
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForResource = AppConfig.connectivityWait
        return configuration
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

    public func sendNotingRetryAfter<Response: Decodable>(
        _ request: APIRequest,
        as type: Response.Type
    ) async throws -> Response {
        let data = try await perform(request, notingRetryAfter: true)
        if data.isEmpty {
            throw APIError.decoding("Expected \(Response.self) but the response body was empty.")
        }
        do {
            return try JSONCoding.decoder.decode(Response.self, from: data)
        } catch {
            throw APIError.decoding("Could not decode \(Response.self): \(error)")
        }
    }

    public func upload<Response: Decodable>(
        _ request: APIRequest,
        as type: Response.Type,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> Response {
        let data = try await perform(request, progress: progress)
        if data.isEmpty {
            throw APIError.decoding("Expected \(Response.self) but the response body was empty.")
        }
        do {
            return try JSONCoding.decoder.decode(Response.self, from: data)
        } catch {
            throw APIError.decoding("Could not decode \(Response.self): \(error)")
        }
    }

    // MARK: - Plumbing

    private func perform(
        _ request: APIRequest,
        notingRetryAfter: Bool = false,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> Data {
        var urlRequest = try makeURLRequest(request)

        let data: Data
        let response: URLResponse
        do {
            if let progress, let body = urlRequest.httpBody {
                // An upload task, so the bytes can be counted as they go;
                // the same request otherwise, through the same refusals.
                urlRequest.httpBody = nil
                let delegate = UploadProgressReporter(progress)
                (data, response) = try await session.upload(for: urlRequest, from: body, delegate: delegate)
            } else {
                (data, response) = try await session.data(for: urlRequest)
            }
        } catch let error as URLError {
            // -999: the app cancelled its own request. Not a network failure.
            throw error.code == .cancelled ? APIError.cancelled : .transport(error.localizedDescription)
        } catch is CancellationError {
            throw APIError.cancelled
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
            // A vouched account reaching for something only a verified one
            // may do: an offer to verify, never the wall (contract v24 §4).
            if case let .api(.selfVerificationRequired, message, _) = error {
                verification?.selfVerificationRequired(message: message)
            }
            if notingRetryAfter,
               let seconds = RetryAfterRefusal.seconds(fromHeader: http.value(forHTTPHeaderField: "Retry-After")) {
                throw RetryAfterRefusal(error: error, seconds: seconds)
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
            let code = APIErrorCode(serverCode: envelope.detail.code)
            if code == .detailsMismatch {
                // Which fields, never what the voucher wrote in them.
                return .detailsMismatch(
                    fields: envelope.detail.mismatchedFields ?? [],
                    attemptsLeft: max(0, envelope.detail.attemptsLeft ?? 0),
                    message: envelope.detail.message
                )
            }
            let message: String
            switch code {
            case .validationError:
                // A validation reply's wording is rebuilt here from the field
                // that failed; the server's sentence is for developers.
                message = Self.validationMessage(envelope.detail.fields ?? [])
            case .videoNotAllowed:
                // One code, two situations: the server has no video yet, or
                // this account is not verified. The words follow the reason.
                message = envelope.detail.reason == "not_available"
                    ? L10n.t("video.error.notAvailable")
                    : L10n.t("video.error.notVerified")
            case .videoProcessingFailed:
                // Posting a failed video: the failure's own words.
                message = VideoCopy.failure(code: envelope.detail.failureCode)
            default:
                message = envelope.detail.message
            }
            return .api(code: code, message: message, status: status)
        }
        if let envelope = try? JSONDecoder().decode(APIValidationListEnvelope.self, from: data) {
            return .api(code: .validationError, message: Self.validationMessage(envelope.detail), status: status)
        }
        if let envelope = try? JSONDecoder().decode(APIErrorStringEnvelope.self, from: data) {
            return .http(status: status, message: envelope.detail)
        }
        if status == 401 { return .unauthenticated }
        if status == 422 {
            // Whatever shape this is, it is a refused form, and a screen must
            // say so in words rather than in the server's JSON.
            return .api(code: .validationError, message: L10n.t("error.validation"), status: status)
        }
        let raw = String(data: data, encoding: .utf8) ?? ""
        return .http(status: status, message: raw)
    }

    /// The first refused field's sentence; the person fixes one thing at a time.
    static func validationMessage(_ fields: [ValidationField]) -> String {
        fields.first?.userMessage ?? L10n.t("error.validation")
    }
}

/// Tells an upload's caller how much of the body has gone, `0…1`.
private final class UploadProgressReporter: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let report: @Sendable (Double) -> Void

    init(_ report: @escaping @Sendable (Double) -> Void) { self.report = report }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        report(min(1, Double(totalBytesSent) / Double(totalBytesExpectedToSend)))
    }
}
