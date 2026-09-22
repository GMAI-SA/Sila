import Foundation
import Observation

/// The list of communities: what to join, and what you are already in.
@MainActor
@Observable
public final class CommunitiesViewModel {

    public enum Folder: String, CaseIterable, Identifiable, Sendable {
        case forYou, mine
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .forYou: return L10n.t("communities.folder.forYou")
            case .mine: return L10n.t("communities.folder.mine")
            }
        }
    }

    public private(set) var communities: [Community] = []
    public private(set) var isLoading = false
    public private(set) var hasLoaded = false
    public private(set) var loadError: String?
    public var folder: Folder = .forYou {
        didSet { if folder != oldValue { Task { await load(isRefresh: true) } } }
    }
    public var toast: SLToastMessage?

    private let service: CommunitiesServiceProtocol
    private let analytics: AnalyticsClient
    private let suspension: SuspensionMonitor?

    public init(
        service: CommunitiesServiceProtocol,
        analytics: AnalyticsClient,
        suspension: SuspensionMonitor? = nil
    ) {
        self.service = service
        self.analytics = analytics
        self.suspension = suspension
    }

    public var isEmpty: Bool { hasLoaded && communities.isEmpty && loadError == nil }

    /// Loads in flight. More than one is legitimate — the folder control and
    /// a pull-to-refresh can both ask — and the list is loading while any
    /// of them is.
    private var inFlight = 0

    public func load(isRefresh: Bool = false) async {
        if hasLoaded && !isRefresh { return }
        // The answer is applied only if it is for the folder still on screen.
        // A folder change *during* a load used to be thrown away — the
        // underline moved, the list did not — and a generation counter would
        // instead throw away the older of two loads for the *same* folder.
        let requested = folder
        inFlight += 1
        isLoading = true
        loadError = nil
        defer {
            inFlight -= 1
            if inFlight == 0 { isLoading = false }
        }
        do {
            let page = try await service.fetchCommunities(
                mine: requested == .mine,
                forYou: requested == .forYou,
                topic: nil,
                limit: 30
            )
            guard requested == folder else { return }
            communities = page
            hasLoaded = true
        } catch {
            guard requested == folder else { return }
            guard suspension?.notice(error) != true else { return }
            // Abandoned: not loaded, not failed. The next appearance asks again.
            guard !APIError.wrapping(error).isCancellation else { return }
            if communities.isEmpty {
                loadError = APIError.wrapping(error).presentableMessage
            } else {
                toast = .error(for: error)
            }
            hasLoaded = true
        }
    }

    /// Puts a community the viewer just opened at the top of both folders.
    public func insert(_ community: Community) {
        communities.removeAll { $0.id == community.id }
        communities.insert(community, at: 0)
    }

    /// Adopts a community changed on its own screen.
    public func merge(_ community: Community) {
        guard let index = communities.firstIndex(where: { $0.id == community.id }) else { return }
        if folder == .mine && !community.isMember {
            communities.remove(at: index)
        } else {
            communities[index] = community
        }
    }
}
