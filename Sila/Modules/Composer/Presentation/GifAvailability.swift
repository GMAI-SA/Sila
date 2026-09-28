import Foundation
import Observation

/// Whether the GIF picker has anything a person could post (contract v27 §5).
///
/// The library decides what a GIF shows, and it fills only from the provider:
/// a server with no provider key lists what its library already holds and
/// refuses any other GIF. Production has no key and an empty library, so the
/// picker opened on nothing. Its ways in — the composer's GIF button and the
/// floating button's GIF option — are hidden instead, and come back by
/// themselves once the server answers with a provider or a library.
///
/// Learned from `/gifs/trending`: asked when the tabs open, and again once an
/// answer is older than ``freshness``; the picker reports every trending list
/// it loads too. Until the server has answered, the ways in stay. A request
/// that fails says nothing about GIFs; only `503 gif_unavailable` does.
@MainActor
@Observable
public final class GifAvailability {

    /// What the server last said.
    public enum Offer: Equatable, Sendable {
        /// Not asked yet, or never answered.
        case unknown
        /// A provider to search, or GIFs already in the library.
        case offered
        /// Nothing anybody could post.
        case unavailable
    }

    public private(set) var offer: Offer = .unknown

    /// How long one answer stands before the next check asks again.
    public static let freshness: TimeInterval = 10 * 60

    private let service: GifServiceProtocol
    private let now: @MainActor () -> Date
    @ObservationIgnored private var answeredAt: Date?
    @ObservationIgnored private var inFlight: Task<Void, Never>?

    /// - Parameters:
    ///   - service: The library.
    ///   - now: The clock, for ``freshness``.
    public init(service: GifServiceProtocol, now: @escaping @MainActor () -> Date = { Date() }) {
        self.service = service
        self.now = now
    }

    /// `false` only once the server has said there is nothing to pick.
    public var isOffered: Bool { offer != .unavailable }

    /// Anything to pick: a provider to search, or GIFs the library holds.
    public static func offers(_ list: GifList) -> Bool {
        list.providerConfigured || !list.gifs.isEmpty || !list.sharedHere.isEmpty
    }

    /// What a trending list said, wherever it was loaded. (A search that
    /// finds nothing says nothing about the library.)
    public func note(_ list: GifList) {
        settle(Self.offers(list) ? .offered : .unavailable)
    }

    /// What a failed GIF request said: only `gif_unavailable` is an answer.
    public func note(error: Error) {
        if APIError.wrapping(error).code == .gifUnavailable {
            settle(.unavailable)
        }
    }

    /// Asks the server, unless a fresh answer stands or a question is
    /// already out — in which case this waits for that one.
    public func check(country: String?) async {
        if let inFlight {
            await inFlight.value
            return
        }
        if offer != .unknown, let answeredAt, now().timeIntervalSince(answeredAt) < Self.freshness {
            return
        }
        let service = service
        let task = Task { [weak self] in
            do {
                let list = try await service.trending(country: country, cursor: nil)
                self?.note(list)
            } catch {
                self?.note(error: error)
            }
        }
        inFlight = task
        await task.value
        inFlight = nil
    }

    private func settle(_ next: Offer) {
        answeredAt = now()
        if offer != next { offer = next }
    }
}
