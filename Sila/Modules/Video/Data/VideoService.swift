import Foundation

/// The production ``VideoServiceProtocol``.
///
/// The small JSON calls go through ``NetworkClient`` like every other call;
/// the file bodies — chunks and parts — go through a ``VideoUploadTransport``,
/// which in the app is a background `URLSession`, so an upload keeps going
/// while the app is suspended.
public final class VideoService: VideoServiceProtocol {

    private let network: NetworkClient
    private let tokens: AccessTokenProviding
    private let transport: VideoUploadTransport
    private let analytics: AnalyticsClient
    /// The API base (`…/api/v1`) the plan's root-relative URLs belong to.
    private let baseURL: URL

    public init(
        network: NetworkClient,
        tokens: AccessTokenProviding,
        transport: VideoUploadTransport,
        analytics: AnalyticsClient,
        baseURL: URL = AppConfig.apiBaseURL
    ) {
        self.network = network
        self.tokens = tokens
        self.transport = transport
        self.analytics = analytics
        self.baseURL = baseURL
    }

    public func fetchConfig() async throws -> VideoConfig {
        let envelope = try await network.send(APIRequest(path: "/config"), as: ServerConfigEnvelope.self)
        return envelope.video ?? VideoConfig(enabled: false)
    }

    public func startUpload(sizeBytes: Int, durationSeconds: Double, contentType: String) async throws -> VideoUploadStart {
        let token = try await tokens.accessToken()
        let request = try APIRequest.json(
            "/videos/uploads",
            body: VideoUploadStartRequest(
                sizeBytes: sizeBytes,
                // Two decimals is all the server keeps, and a long binary
                // fraction in a request body helps nobody reading a log.
                durationS: (durationSeconds * 100).rounded() / 100,
                contentType: contentType
            ),
            accessToken: token
        )
        let start = try await network.send(request, as: VideoUploadStart.self)
        analytics.track(.videoUploadStarted, properties: [
            "type": start.upload.type.rawValue,
            "bytes": String(sizeBytes),
        ])
        return start
    }

    public func uploadStatus(_ plan: VideoUploadPlan) async throws -> VideoUploadStatus {
        let token = try await tokens.accessToken()
        return try await network.send(
            APIRequest(path: apiPath(plan.statusUrl), accessToken: token),
            as: VideoUploadStatus.self
        )
    }

    public func sendChunk(
        _ plan: VideoUploadPlan,
        number: Int,
        file: URL,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        guard let path = plan.url, let url = absoluteURL(path) else {
            throw APIError.api(code: .uploadTypeMismatch, message: "", status: 409)
        }
        let token = try await tokens.accessToken()
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(
            VideoPieces.contentRange(number: number, total: plan.sizeBytes, pieceSize: plan.pieceSize),
            forHTTPHeaderField: "Content-Range"
        )
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = VideoUploadTiming.pieceTimeout
        let (body, response) = try await transport.upload(request, fromFile: file, progress: progress)
        guard (200..<300).contains(response.statusCode) else {
            throw URLSessionNetworkClient.makeError(status: response.statusCode, data: body)
        }
    }

    public func partTargets(_ plan: VideoUploadPlan, numbers: [Int]) async throws -> [VideoPartTarget] {
        guard let partsURL = plan.partsUrl else {
            throw APIError.api(code: .uploadTypeMismatch, message: "", status: 409)
        }
        let token = try await tokens.accessToken()
        let request = try APIRequest.json(
            apiPath(partsURL),
            body: VideoPartsRequest(numbers: numbers),
            accessToken: token
        )
        return try await network.send(request, as: VideoPartTargets.self).targets
    }

    public func sendPart(
        _ target: VideoPartTarget,
        file: URL,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        guard let url = URL(string: target.url), url.scheme != nil else {
            throw APIError.transport("The storage address is not one this app can use.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = target.method
        // Exactly the signed headers, and no Authorization: this goes to
        // storage, whose signature covers what the API asked for.
        for (name, value) in target.headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.timeoutInterval = VideoUploadTiming.pieceTimeout
        let (body, response) = try await transport.upload(request, fromFile: file, progress: progress)
        guard (200..<300).contains(response.statusCode) else {
            // Storage's own error body, not the API's. A 403 is usually a
            // signature past its fifteen minutes: the uploader asks again.
            throw APIError.http(status: response.statusCode, message: String(decoding: body.prefix(200), as: UTF8.self))
        }
    }

    public func complete(_ plan: VideoUploadPlan) async throws -> PostVideo {
        let token = try await tokens.accessToken()
        let video = try await network.send(
            APIRequest(path: apiPath(plan.completeUrl), method: .post, accessToken: token),
            as: PostVideo.self
        )
        analytics.track(.videoUploadCompleted, properties: ["bytes": String(plan.sizeBytes)])
        return video
    }

    public func fetchVideo(_ id: UUID) async throws -> PostVideo {
        let token = try await tokens.accessToken()
        return try await network.send(APIRequest(path: videoPath(id), accessToken: token), as: PostVideo.self)
    }

    public func discard(_ id: UUID) async throws {
        let token = try await tokens.accessToken()
        try await network.send(APIRequest(path: videoPath(id), method: .delete, accessToken: token))
    }

    // MARK: - Paths

    private func videoPath(_ id: UUID) -> String { "/videos/\(id.uuidString.lowercased())" }

    /// The plan's `/api/v1/videos/…` as a path under ``baseURL``, which
    /// already ends in `/api/v1`.
    func apiPath(_ raw: String) -> String {
        var path = raw
        if let absolute = URL(string: raw), absolute.scheme != nil {
            path = absolute.path
        }
        let prefix = baseURL.path
        if !prefix.isEmpty, prefix != "/", path.hasPrefix(prefix) {
            path = String(path.dropFirst(prefix.count))
        }
        return path.hasPrefix("/") ? path : "/" + path
    }

    /// A root-relative path against the API's origin; an absolute URL as it is.
    func absoluteURL(_ raw: String) -> URL? {
        if let absolute = URL(string: raw), absolute.scheme != nil { return absolute }
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return nil }
        components.path = ""
        components.query = nil
        guard let origin = components.url else { return nil }
        return URL(string: raw, relativeTo: origin)?.absoluteURL
    }
}

/// How long the pieces of an upload may take.
public enum VideoUploadTiming {
    /// One chunk or part: 5–8 MB on a slow connection is a minute and more.
    public static let pieceTimeout: TimeInterval = 120
}
