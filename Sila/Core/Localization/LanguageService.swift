import Foundation

/// Reads `GET /languages`.
///
/// The list is what the server knows about the languages Sila carries content
/// in, and the field that matters to this client is `rtl`. The client could
/// guess a direction from the script of every post it renders — and does, as a
/// fallback — but the server has already decided this once, per language, and
/// two components disagreeing about which way Urdu reads is a bug nobody would
/// find twice.
public protocol LanguageServiceProtocol: Sendable {

    /// The languages the server recognises, with their direction.
    func fetchLanguages() async throws -> [LanguageOption]
}

/// The production ``LanguageServiceProtocol``.
public final class LanguageService: LanguageServiceProtocol {

    private let network: NetworkClient
    private let tokens: AccessTokenProviding
    private let directory: LanguageDirectory

    /// - Parameters:
    ///   - network: HTTP transport.
    ///   - tokens: Supplies the bearer token — `/languages` is authenticated.
    ///   - directory: Cache to update on a successful fetch.
    public init(
        network: NetworkClient,
        tokens: AccessTokenProviding,
        directory: LanguageDirectory = .shared
    ) {
        self.network = network
        self.tokens = tokens
        self.directory = directory
    }

    public func fetchLanguages() async throws -> [LanguageOption] {
        let token = try await tokens.accessToken()
        let request = APIRequest(path: "/languages", accessToken: token)
        let options = try await network.send(request, as: LanguagesResponse.self).languages
        directory.replace(with: options)
        return options
    }
}

/// Accepts either envelope the endpoint might use.
///
/// `{"languages": [...]}` is what the rest of this API does; a bare array is
/// what a list endpoint often turns out to be. Rather than guess and ship a
/// build whose Arabic posts silently left-align, this decodes both.
struct LanguagesResponse: Decodable {

    let languages: [LanguageOption]

    private enum CodingKeys: String, CodingKey {
        case languages
    }

    init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: CodingKeys.self),
           let wrapped = try? container.decode([LanguageOption].self, forKey: .languages) {
            languages = wrapped.filter { !$0.code.isEmpty }
            return
        }
        let bare = try decoder.singleValueContainer().decode([LanguageOption].self)
        languages = bare.filter { !$0.code.isEmpty }
    }

    init(languages: [LanguageOption]) {
        self.languages = languages
    }
}

/// The offline ``LanguageServiceProtocol``.
///
/// Ships the two languages the app itself is written in, so previews, mock
/// launches and the UI tests get the same direction behaviour as production
/// without a network call.
public struct LanguageServiceMock: LanguageServiceProtocol {

    private let options: [LanguageOption]
    private let directory: LanguageDirectory

    public init(
        options: [LanguageOption] = LanguageServiceMock.defaults,
        directory: LanguageDirectory = .shared
    ) {
        self.options = options
        self.directory = directory
    }

    /// English, Arabic, and one more right-to-left language that the app is
    /// *not* translated into — because "renders an RTL post correctly" and
    /// "happens to be running in Arabic" are two different things, and a mock
    /// that only ever offers `ar` cannot tell them apart.
    public static let defaults: [LanguageOption] = [
        LanguageOption(code: "ar", name: "Arabic", nativeName: "العربية", rtl: true),
        LanguageOption(code: "en", name: "English", nativeName: "English", rtl: false),
        LanguageOption(code: "ur", name: "Urdu", nativeName: "اردو", rtl: true),
        LanguageOption(code: "fr", name: "French", nativeName: "Français", rtl: false)
    ]

    public func fetchLanguages() async throws -> [LanguageOption] {
        directory.replace(with: options)
        return options
    }
}
