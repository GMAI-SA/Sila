import Foundation

/// The production ``VoiceServiceProtocol``.
///
/// The upload goes through its own `URLSession` task because it is the one
/// request in the app whose progress somebody watches; every other call goes
/// through ``NetworkClient`` as usual. Errors are read with the same decoder
/// the network client uses, so a refusal reads the same either way.
public final class VoiceService: VoiceServiceProtocol {

    private let network: NetworkClient
    private let tokens: AccessTokenProviding
    private let analytics: AnalyticsClient
    private let session: URLSession

    public init(network: NetworkClient, tokens: AccessTokenProviding, analytics: AnalyticsClient,
                session: URLSession = .shared) {
        self.network = network
        self.tokens = tokens
        self.analytics = analytics
        self.session = session
    }

    public func upload(
        _ file: URL,
        kind: VoiceKind,
        languageHint: String?,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> VoiceClip {
        let token = try await tokens.accessToken()
        let data = try Data(contentsOf: file)
        var form = MultipartFormData()
        form.appendFile(data, name: "file", filename: "voice.m4a", mimeType: "audio/mp4")
        form.appendField(kind.rawValue, name: "kind")
        if let languageHint { form.appendField(languageHint, name: "language_hint") }

        var request = URLRequest(url: AppConfig.apiBaseURL.appendingPathComponent("media/voice"))
        request.httpMethod = "POST"
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 120

        let delegate = UploadProgressDelegate(progress)
        let (body, response): (Data, URLResponse)
        do {
            (body, response) = try await session.upload(for: request, from: form.encoded(), delegate: delegate)
        } catch {
            throw APIError.wrapping(error)
        }
        guard let http = response as? HTTPURLResponse else { throw APIError.transport("No response") }
        guard (200..<300).contains(http.statusCode) else {
            throw URLSessionNetworkClient.makeError(status: http.statusCode, data: body)
        }
        progress(1)
        let clip: VoiceClip
        do {
            clip = try JSONCoding.decoder.decode(VoiceClip.self, from: body)
        } catch {
            throw APIError.decoding("Could not decode the recording: \(error.localizedDescription)")
        }
        analytics.track(.voiceUploaded, properties: ["kind": kind.rawValue, "duration_ms": String(clip.durationMs)])
        return clip
    }

    public func fetchClip(_ id: UUID) async throws -> VoiceClip {
        let token = try await tokens.accessToken()
        return try await network.send(APIRequest(path: path(id), accessToken: token), as: VoiceClip.self)
    }

    public func editCaption(_ id: UUID, text: String) async throws -> VoiceClip {
        let token = try await tokens.accessToken()
        let request = try APIRequest.json(path(id) + "/caption", method: .patch,
                                          body: CaptionEditRequest(caption: text), accessToken: token)
        return try await network.send(request, as: VoiceClip.self)
    }

    public func removeCaption(_ id: UUID) async throws -> VoiceClip {
        let token = try await tokens.accessToken()
        return try await network.send(
            APIRequest(path: path(id) + "/caption", method: .delete, accessToken: token), as: VoiceClip.self
        )
    }

    public func redoCaption(_ id: UUID, language: String?) async throws -> VoiceClip {
        let token = try await tokens.accessToken()
        let request = try APIRequest.json(path(id) + "/caption/redo",
                                          body: CaptionRedoRequest(language: language), accessToken: token)
        return try await network.send(request, as: VoiceClip.self)
    }

    public func setStance(_ stance: VoiceStances.Stance?, postId: UUID) async throws -> VoiceStances {
        let token = try await tokens.accessToken()
        let path = "/posts/\(postId.uuidString.lowercased())/stance"
        if let stance {
            let request = try APIRequest.json(path, method: .put, body: StanceRequest(stance: stance.rawValue), accessToken: token)
            return try await network.send(request, as: VoiceStances.self)
        }
        return try await network.send(APIRequest(path: path, method: .delete, accessToken: token), as: VoiceStances.self)
    }

    private func path(_ id: UUID) -> String { "/media/voice/clips/\(id.uuidString.lowercased())" }
}

/// Reports bytes sent as a fraction.
private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let report: @Sendable (Double) -> Void

    init(_ report: @escaping @Sendable (Double) -> Void) { self.report = report }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        report(min(0.99, Double(totalBytesSent) / Double(totalBytesExpectedToSend)))
    }
}
