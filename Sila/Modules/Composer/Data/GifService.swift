import Foundation

/// The production ``GifServiceProtocol``: `GET /gifs/trending` and
/// `GET /gifs/search` (contract v17).
public final class GifService: GifServiceProtocol {

    private let network: NetworkClient
    private let tokens: AccessTokenProviding

    public init(network: NetworkClient, tokens: AccessTokenProviding) {
        self.network = network
        self.tokens = tokens
    }

    public func trending(country: String?, cursor: String?) async throws -> GifList {
        try await network.send(
            APIRequest(path: "/gifs/trending", accessToken: try await tokens.accessToken(), query: query(country: country, cursor: cursor)),
            as: GifList.self
        )
    }

    public func search(_ query: String, country: String?, cursor: String?) async throws -> GifList {
        var items = self.query(country: country, cursor: cursor)
        items.insert(URLQueryItem(name: "q", value: query), at: 0)
        return try await network.send(
            APIRequest(path: "/gifs/search", accessToken: try await tokens.accessToken(), query: items),
            as: GifList.self
        )
    }

    private func query(country: String?, cursor: String?) -> [URLQueryItem] {
        var items = [URLQueryItem(name: "limit", value: "30")]
        if let country, !country.isEmpty { items.append(URLQueryItem(name: "country", value: country)) }
        if let cursor, !cursor.isEmpty { items.append(URLQueryItem(name: "cursor", value: cursor)) }
        return items
    }
}
