import Foundation
import Observation

/// Which list the safety screen is showing.
public enum SafetyListTab: String, CaseIterable, Identifiable, Sendable, Hashable {
    case blocked, muted, reports

    public var id: String { rawValue }

    /// Segmented-control label.
    public var title: String {
        switch self {
        case .blocked: return "Blocked"
        case .muted: return "Muted"
        case .reports: return "Reports"
        }
    }

    /// The line under the heading — what this list is, and what it is not.
    public var caption: String {
        switch self {
        case .blocked: return SafetyCopy.blockedListCaption
        case .muted: return SafetyCopy.mutedListCaption
        case .reports: return SafetyCopy.reportsListCaption
        }
    }

    /// Accessibility hint for the segmented control.
    public var accessibilityHint: String {
        switch self {
        case .blocked: return "Shows accounts you have blocked, each with an unblock button"
        case .muted: return "Shows accounts you have muted, each with an unmute button"
        case .reports: return "Shows everything you have reported and where each one has got to"
        }
    }
}

/// Drives ``SafetyListsScreen``.
///
/// Every row acts **in place**. Unblocking somebody does not push a confirmation
/// or bounce back to a profile: the person is already on a list called Blocked,
/// they have already decided, and a second dialog would be the app asking them
/// to justify a decision it recorded for them in the first place.
///
/// Removal from the list is optimistic and rolled back on failure, for the same
/// reason the feed's likes are: a row that sits there for a second after the tap
/// reads as a button that did not work.
@MainActor
@Observable
public final class SafetyListsViewModel {

    /// The visible list.
    public var tab: SafetyListTab = .blocked

    /// Accounts the viewer has blocked.
    public private(set) var blocked: [SafetyRelation] = []
    /// Accounts the viewer has muted.
    public private(set) var muted: [SafetyRelation] = []
    /// Reports the viewer has filed, newest first.
    public private(set) var reports: [Report] = []

    /// `true` during the first load.
    public private(set) var isLoading = false
    /// `true` once a load has finished, successfully or not.
    public private(set) var hasLoaded = false
    /// Why the lists could not load.
    public private(set) var loadError: String?
    /// Handles with a write in flight.
    public private(set) var busyHandles: Set<String> = []
    /// Banner message.
    public var toast: SLToastMessage?

    private let service: SafetyServiceProtocol
    private let analytics: AnalyticsClient
    private let suspension: SuspensionMonitor?
    private let onChange: (@MainActor (SafetyChange) -> Void)?

    /// - Parameters:
    ///   - service: Safety backend.
    ///   - analytics: Event sink.
    ///   - suspension: Where `403 account_suspended` goes.
    ///   - onChange: Told after every accepted write, so the menus elsewhere in
    ///     the app agree without a round trip.
    public init(
        service: SafetyServiceProtocol,
        analytics: AnalyticsClient,
        suspension: SuspensionMonitor? = nil,
        onChange: (@MainActor (SafetyChange) -> Void)? = nil
    ) {
        self.service = service
        self.analytics = analytics
        self.suspension = suspension
        self.onChange = onChange
    }

    // MARK: - Derived state

    /// `true` when the visible list has nothing in it and nothing went wrong.
    public var isCurrentListEmpty: Bool {
        guard hasLoaded, loadError == nil else { return false }
        switch tab {
        case .blocked: return blocked.isEmpty
        case .muted: return muted.isEmpty
        case .reports: return reports.isEmpty
        }
    }

    /// Whether a write is in flight for this handle.
    public func isBusy(_ handle: String) -> Bool {
        busyHandles.contains(Handle.normalised(handle))
    }

    // MARK: - Loading

    /// Loads all three lists. Safe on every appearance.
    public func load() async {
        guard !hasLoaded, !isLoading else { return }
        await reload()
    }

    /// Loads unconditionally — the retry and pull-to-refresh path.
    public func reload() async {
        isLoading = true
        loadError = nil
        defer {
            isLoading = false
            hasLoaded = true
        }

        async let blocks = service.fetchBlocked()
        async let mutes = service.fetchMuted()
        async let filed = service.fetchReports()

        do {
            blocked = try await blocks
        } catch {
            // Every one of the three is consumed even when the first fails, or
            // the others are cancelled mid-decode and their failures are
            // reported nowhere.
            _ = try? await mutes
            _ = try? await filed
            guard suspension?.notice(error) != true else { return }
            loadError = APIError.wrapping(error).userMessage
            return
        }

        muted = (try? await mutes) ?? []
        // The receipts list is the least important of the three. A profile page
        // that cannot list somebody's own reports is worse with an error banner
        // over two lists that loaded fine.
        reports = (try? await filed) ?? []
        analytics.track(.safetyListsOpened, properties: [
            "blocked": String(blocked.count),
            "muted": String(muted.count),
            "reports": String(reports.count)
        ])
    }

    // MARK: - Row actions

    /// Lifts a block, from the row it is on.
    public func unblock(_ relation: SafetyRelation) async {
        let target = relation.target
        guard !isBusy(target.handle) else { return }
        busyHandles.insert(target.handle)
        defer { busyHandles.remove(target.handle) }

        let snapshot = blocked
        blocked.removeAll { $0.user.id == relation.user.id }

        do {
            _ = try await service.setBlocked(false, handle: target.handle)
            toast = .info(SafetyCopy.unblocked(target))
            onChange?(.unblocked(target))
        } catch {
            blocked = snapshot
            guard suspension?.notice(error) != true else { return }
            toast = .error(APIError.wrapping(error).userMessage)
        }
    }

    /// Lifts a mute, from the row it is on.
    public func unmute(_ relation: SafetyRelation) async {
        let target = relation.target
        guard !isBusy(target.handle) else { return }
        busyHandles.insert(target.handle)
        defer { busyHandles.remove(target.handle) }

        let snapshot = muted
        muted.removeAll { $0.user.id == relation.user.id }

        do {
            _ = try await service.setMuted(false, handle: target.handle)
            toast = .success(SafetyCopy.unmuted(target))
            onChange?(.unmuted(target))
        } catch {
            muted = snapshot
            guard suspension?.notice(error) != true else { return }
            toast = .error(APIError.wrapping(error).userMessage)
        }
    }
}
