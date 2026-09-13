import Foundation
import Observation

/// The GIF picker: what is popular where the viewer is, and a search.
///
/// Opens on the trending list for the viewer's verified country — the
/// provider's, with what people from that country have shared on Sila above
/// it — and switches to a search after a short pause in typing.
@MainActor
@Observable
public final class GifPickerViewModel {

    public enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    public var query = ""
    public private(set) var list: GifList?
    public private(set) var loadState: LoadState = .idle
    public private(set) var isLoadingMore = false

    private let service: GifServiceProtocol
    private let country: String?
    private let debounce: TimeInterval
    private var searchTask: Task<Void, Never>?
    /// The trending list, kept so clearing the search restores it instantly.
    private var trendingList: GifList?

    /// - Parameters:
    ///   - service: The library.
    ///   - country: The viewer's verified country, for "popular here".
    ///   - debounce: Seconds to wait after a keystroke before searching.
    public init(service: GifServiceProtocol, country: String?, debounce: TimeInterval = 0.3) {
        self.service = service
        self.country = country
        self.debounce = debounce
    }

    public var gifs: [Gif] { list?.gifs ?? [] }
    public var sharedHere: [Gif] { isSearching ? [] : (list?.sharedHere ?? []) }
    public var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }
    /// Whether the provider answered — its attribution is shown only then.
    public var isFromProvider: Bool { list?.isFromProvider ?? false }
    /// Nothing at all, on a deployment with no provider: say so honestly.
    public var isLibraryEmpty: Bool {
        loadState == .loaded && gifs.isEmpty && sharedHere.isEmpty && list?.providerConfigured == false && !isSearching
    }
    public var hasMore: Bool { list?.nextCursor != nil }

    /// The country's name in the interface language, for the "popular here" row.
    public var countryName: String? {
        guard let code = list?.country ?? country else { return nil }
        return Locale.current.localizedString(forRegionCode: code)
    }

    /// Loads the trending list, once.
    public func load() async {
        guard loadState == .idle else { return }
        await loadTrending()
    }

    public func reload() async {
        if isSearching { await search(query) } else { await loadTrending() }
    }

    /// Types into the search field: a debounced search, or trending when cleared.
    public func updateQuery(_ text: String, immediately: Bool = false) {
        query = text
        searchTask?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            if let trendingList { list = trendingList; loadState = .loaded }
            return
        }
        searchTask = Task { [debounce] in
            if !immediately {
                try? await Task.sleep(nanoseconds: UInt64(debounce * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }
            await search(trimmed)
        }
    }

    public func clear() {
        updateQuery("")
    }

    public func loadMoreIfNeeded(current gif: Gif) async {
        guard let list, let cursor = list.nextCursor, !isLoadingMore else { return }
        guard let index = list.gifs.firstIndex(of: gif), index >= list.gifs.count - 6 else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            let next = trimmed.isEmpty
                ? try await service.trending(country: country, cursor: cursor)
                : try await service.search(trimmed, country: country, cursor: cursor)
            let known = Set(list.gifs.map(\.listKey))
            self.list = GifList(
                gifs: list.gifs + next.gifs.filter { !known.contains($0.listKey) },
                source: list.source,
                country: list.country,
                nextCursor: next.nextCursor,
                sharedHere: list.sharedHere,
                providerConfigured: list.providerConfigured
            )
        } catch {
            // The end of the list is not worth a message.
        }
    }

    private func loadTrending() async {
        loadState = .loading
        do {
            let fetched = try await service.trending(country: country, cursor: nil)
            trendingList = fetched
            if !isSearching { list = fetched }
            loadState = .loaded
        } catch {
            guard let message = APIError.wrapping(error).presentableMessage else {
                // Abandoned, not failed: leave the state ready to load again.
                loadState = list == nil ? .idle : .loaded
                return
            }
            loadState = .failed(message)
        }
    }

    private func search(_ term: String) async {
        loadState = .loading
        do {
            let fetched = try await service.search(term, country: country, cursor: nil)
            guard !Task.isCancelled, term == query.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
            list = fetched
            loadState = .loaded
        } catch {
            guard let message = APIError.wrapping(error).presentableMessage else {
                loadState = list == nil ? .idle : .loaded
                return
            }
            loadState = .failed(message)
        }
    }
}
