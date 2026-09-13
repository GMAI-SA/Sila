import Foundation

/// Scripted ``GifServiceProtocol`` for tests, previews and `-mockComposer`.
public actor GifServiceMock: GifServiceProtocol {

    public enum MockScenario: String, CaseIterable, Sendable {
        /// The provider answers, and people here have shared a few.
        case populated
        /// No provider key: the library alone, with a few shares.
        case libraryOnly
        /// No provider key and nothing shared yet — the honest empty state.
        case empty
        /// Every call fails with a transport error.
        case offline
    }

    public private(set) var scenario: MockScenario
    public private(set) var recordedCalls: [String] = []
    private let latency: Double

    public init(scenario: MockScenario = .populated, latency: Double = 0) {
        self.scenario = scenario
        self.latency = latency
    }

    public func setScenario(_ scenario: MockScenario) { self.scenario = scenario }

    public func trending(country: String?, cursor: String?) async throws -> GifList {
        recordedCalls.append("trending:\(country ?? "-"):\(cursor ?? "first")")
        try await delay()
        return try list(all: Self.samples, country: country, cursor: cursor)
    }

    public func search(_ query: String, country: String?, cursor: String?) async throws -> GifList {
        recordedCalls.append("search:\(query):\(country ?? "-")")
        try await delay()
        let needle = query.lowercased()
        let hits = Self.samples.filter { ($0.title ?? "").lowercased().contains(needle) }
        return try list(all: hits, country: country, cursor: cursor, includeShared: false)
    }

    private func list(all: [Gif], country: String?, cursor: String?, includeShared: Bool = true) throws -> GifList {
        switch scenario {
        case .offline:
            throw APIError.transport("The Internet connection appears to be offline.")
        case .empty:
            return GifList(gifs: [], source: "library", country: country ?? "SA", providerConfigured: false)
        case .libraryOnly:
            let shared = all.filter { $0.shareCount > 0 }
            return GifList(gifs: shared, source: "library", country: country ?? "SA", sharedHere: includeShared ? shared : [], providerConfigured: false)
        case .populated:
            let page = cursor == nil ? Array(all.prefix(4)) : Array(all.dropFirst(4))
            return GifList(
                gifs: page,
                source: "tenor",
                country: country ?? "SA",
                nextCursor: cursor == nil && all.count > 4 ? "page-2" : nil,
                sharedHere: includeShared ? all.filter { $0.shareCount > 0 } : [],
                providerConfigured: true
            )
        }
    }

    private func delay() async throws {
        guard latency > 0 else { return }
        try await Task.sleep(nanoseconds: UInt64(latency * 1_000_000_000))
    }

    static func gif(_ n: Int, _ title: String, shares: Int = 0, width: Int = 498, height: Int = 280) -> Gif {
        Gif(
            id: shares > 0 ? UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n)) : nil,
            providerId: "mock-\(n)",
            url: URL(string: "https://media.tenor.com/mock\(n)/clip.mp4")!,
            gifURL: URL(string: "https://media.tenor.com/mock\(n)/clip.gif"),
            previewURL: URL(string: "https://media.tenor.com/mock\(n)/clip-tiny.gif"),
            stillURL: URL(string: "https://media.tenor.com/mock\(n)/clip-still.png"),
            width: width,
            height: height,
            title: title,
            shareCount: shares
        )
    }

    public static let samples: [Gif] = [
        gif(1, "happy cat", shares: 12),
        gif(2, "thumbs up", shares: 4, width: 320, height: 320),
        gif(3, "slow clap"),
        gif(4, "mind blown", width: 640, height: 360),
        gif(5, "dancing camel", shares: 1),
        gif(6, "coffee first"),
    ]
}
