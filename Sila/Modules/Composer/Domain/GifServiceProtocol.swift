import Foundation

/// What a GIF picker shows: a list, where it came from, and what people
/// from the viewer's country share on Sila.
public struct GifList: Equatable, Sendable, Decodable {
    public let gifs: [Gif]
    /// `tenor` when the provider answered, `library` when the list is what
    /// people on Sila have shared. Attribution is shown only for the former.
    public let source: String
    public let country: String?
    public let nextCursor: String?
    /// What people from `country` share on Sila, most-shared first.
    public let sharedHere: [Gif]
    /// Whether the deployment has a provider key at all. Without one the
    /// picker is the library alone, and says so when that is empty.
    public let providerConfigured: Bool

    public init(
        gifs: [Gif],
        source: String = "library",
        country: String? = nil,
        nextCursor: String? = nil,
        sharedHere: [Gif] = [],
        providerConfigured: Bool = false
    ) {
        self.gifs = gifs
        self.source = source
        self.country = country
        self.nextCursor = nextCursor
        self.sharedHere = sharedHere
        self.providerConfigured = providerConfigured
    }

    private enum CodingKeys: String, CodingKey {
        case gifs, source, country, nextCursor, sharedHere, providerConfigured
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        gifs = (try? container.decode([Gif].self, forKey: .gifs)) ?? []
        source = (try? container.decode(String.self, forKey: .source)) ?? "library"
        country = (try? container.decodeIfPresent(String.self, forKey: .country)) ?? nil
        let cursor = (try? container.decodeIfPresent(String.self, forKey: .nextCursor)) ?? nil
        nextCursor = (cursor?.isEmpty == false) ? cursor : nil
        sharedHere = (try? container.decode([Gif].self, forKey: .sharedHere)) ?? []
        providerConfigured = (try? container.decode(Bool.self, forKey: .providerConfigured)) ?? false
    }

    public var isFromProvider: Bool { source == "tenor" }
}

/// The GIF library, from the composer's side.
public protocol GifServiceProtocol: Sendable {
    /// What is popular right now — in `country`, or the viewer's own when nil.
    func trending(country: String?, cursor: String?) async throws -> GifList
    /// A search, in the same country context.
    func search(_ query: String, country: String?, cursor: String?) async throws -> GifList
}
