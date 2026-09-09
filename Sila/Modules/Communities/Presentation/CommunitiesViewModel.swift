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

    public func load(isRefresh: Bool = false) async {
        guard !isLoading else { return }
        if hasLoaded && !isRefresh { return }
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            communities = try await service.fetchCommunities(
                mine: folder == .mine,
                forYou: folder == .forYou,
                topic: nil,
                limit: 30
            )
            hasLoaded = true
        } catch {
            guard suspension?.notice(error) != true else { return }
            if communities.isEmpty {
                loadError = APIError.wrapping(error).userMessage
            } else {
                toast = .error(APIError.wrapping(error).userMessage)
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
