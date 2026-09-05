import Foundation

/// Scripted ``ComposerServiceProtocol`` used by tests, previews and the
/// `-mockComposer` launch argument.
///
/// The scenarios are the five outcomes the composer has to handle without
/// lying: it works, it half-works, you are not allowed to speak, the network is
/// gone, and you are being throttled.
///
/// ```swift
/// let service = ComposerServiceMock(scenario: .threadFailsMidway)
/// ```
public actor ComposerServiceMock: ComposerServiceProtocol {

    /// The canned worlds the mock can serve.
    public enum MockScenario: String, CaseIterable, Sendable {
        /// Every post is accepted.
        case success
        /// The first two segments post; the third fails with `rate_limited`,
        /// leaving two real posts behind — the case the UI must not smooth over.
        case threadFailsMidway
        /// 403 `unverified`: the account may read but not speak.
        case unverified
        /// Every call fails with a transport error.
        case offline
        /// Every call is throttled.
        case rateLimited
    }

    /// The scenario currently being played.
    public private(set) var scenario: MockScenario

    /// Artificial latency, in seconds. Tests pass `0`.
    private let latency: Double

    /// Drafts the mock was asked to post, in order — the assertion surface for
    /// thread sequencing.
    public private(set) var receivedDrafts: [PostDraft] = []

    /// After how many successful posts ``MockScenario/threadFailsMidway`` trips.
    private let failAfter: Int

    private var successCount = 0

    /// Creates a mock.
    /// - Parameters:
    ///   - scenario: Which world to serve.
    ///   - latency: Seconds of simulated delay.
    ///   - failAfter: Successful posts before ``MockScenario/threadFailsMidway``
    ///     starts failing.
    public init(scenario: MockScenario = .success, latency: Double = 0, failAfter: Int = 2) {
        self.scenario = scenario
        self.latency = latency
        self.failAfter = failAfter
    }

    /// Switches scenario mid-flight (used by previews and UI-test hooks).
    public func setScenario(_ scenario: MockScenario) {
        self.scenario = scenario
    }

    // MARK: - ComposerServiceProtocol

    /// Hands back a path shaped like the server's, so a screen that assumed a
    /// full URL fails here rather than in front of somebody.
    public func uploadImage(_ data: Data) async throws -> String {
        guard !data.isEmpty else {
            throw APIError.api(code: .invalidImage, message: "That file could not be read as an image", status: 400)
        }
        return "/api/v1/media/posts/mock-\(UUID().uuidString.prefix(8)).jpg"
    }

    public func createPost(_ draft: PostDraft) async throws -> Post {
        receivedDrafts.append(draft)
        if latency > 0 {
            try? await Task.sleep(nanoseconds: UInt64(latency * 1_000_000_000))
        }

        switch scenario {
        case .offline:
            throw APIError.transport("The Internet connection appears to be offline.")

        case .unverified:
            throw APIError.api(
                code: .unverified,
                message: "Verify your identity before posting.",
                status: 403
            )

        case .rateLimited:
            throw APIError.api(code: .rateLimited, message: "Slow down.", status: 429)

        case .threadFailsMidway where successCount >= failAfter:
            throw APIError.api(code: .rateLimited, message: "Slow down.", status: 429)

        case .success, .threadFailsMidway:
            successCount += 1
            return Self.post(for: draft, ordinal: successCount)
        }
    }

    // MARK: - Fixtures

    /// Builds the post the server would have returned for a draft.
    ///
    /// Deterministic ids, so a test can assert that segment 2 replied to
    /// segment 1 without knowing what UUID was minted.
    static func post(for draft: PostDraft, ordinal: Int) -> Post {
        Post(
            id: id(9_000 + ordinal),
            author: FeedServiceMock.aziz,
            text: draft.trimmedText,
            createdAt: Date(),
            scope: PostScope(rawValue: draft.scope.wireValue) ?? .international,
            scopeCountry: draft.scope.scopeCountry,
            scopeRegion: draft.scope.scopeRegion,
            replyToPostId: draft.replyToPostId,
            replyCountDirect: 0,
            metrics: PostMetrics(),
            viewer: PostViewerState(canReply: true)
        )
    }

    private static func id(_ suffix: Int) -> UUID {
        let padded = String(format: "%012d", suffix)
        return UUID(uuidString: "00000000-0000-4000-8000-\(padded)") ?? UUID()
    }
}
