import Foundation
import Observation

/// The viewer's groups: private lists of people, kept for opening rooms to.
@MainActor
@Observable
public final class GroupsViewModel {

    public private(set) var groups: [UserGroup] = []
    public private(set) var isLoading = false
    public private(set) var hasLoaded = false
    public private(set) var isSaving = false
    /// The group whose members are being edited, if any.
    public var editingId: UUID?
    /// The new group's name, as typed.
    public var nameText = ""
    /// Handles for the new group or for the group being edited, as typed.
    public var handlesText = ""
    public var toast: SLToastMessage?
    /// A deletion waiting for confirmation.
    public var pendingDeletion: UserGroup?

    private let service: RoomsServiceProtocol
    private let analytics: AnalyticsClient
    private let suspension: SuspensionMonitor?
    /// Where the member picker gets its people, when there is one.
    public let people: PeopleDirectory?
    public let viewerHandle: String
    /// People ticked for the group being made, before it exists.
    public private(set) var pickedForNew: [UserSummary] = []

    public init(
        service: RoomsServiceProtocol,
        analytics: AnalyticsClient,
        suspension: SuspensionMonitor? = nil,
        people: PeopleDirectory? = nil,
        viewerHandle: String = ""
    ) {
        self.service = service
        self.analytics = analytics
        self.suspension = suspension
        self.people = people
        self.viewerHandle = viewerHandle
    }

    public func pickForNew(_ chosen: [UserSummary]) {
        for person in chosen where !pickedForNew.contains(where: { Handle.normalised($0.handle) == Handle.normalised(person.handle) }) {
            pickedForNew.append(person)
        }
    }

    public func removePickedForNew(_ handle: String) {
        let key = Handle.normalised(handle)
        pickedForNew.removeAll { Handle.normalised($0.handle) == key }
    }

    /// Adds the people a picker chose to the group being edited.
    public func addMembers(people chosen: [UserSummary]) async {
        guard let editingId, !chosen.isEmpty, !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            let updated = try await service.addGroupMembers(id: editingId, handles: chosen.map(\.handle))
            replace(updated)
            toast = .success(L10n.plural("groups.member.added", chosen.count))
        } catch {
            guard suspension?.notice(error) != true else { return }
            toast = .error(APIError.wrapping(error).userMessage)
        }
    }

    /// Typed handles plus the picked people, for the group being made.
    public var handles: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for handle in RoomInviteHandles.clean(handlesText) + pickedForNew.map(\.handle) {
            let key = Handle.normalised(handle)
            guard !key.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            out.append(key)
        }
        return out
    }
    public var trimmedName: String { nameText.trimmingCharacters(in: .whitespacesAndNewlines) }
    public var canCreate: Bool { !trimmedName.isEmpty && !isSaving }
    public var canAddMembers: Bool { !handles.isEmpty && !isSaving }
    public var editing: UserGroup? { groups.first { $0.id == editingId } }

    public func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        if !hasLoaded { analytics.track(.groupsOpened) }
        do {
            groups = try await service.fetchGroups()
            hasLoaded = true
        } catch {
            guard suspension?.notice(error) != true else { return }
            toast = .error(APIError.wrapping(error).userMessage)
        }
    }

    /// Makes a group from the name field and whatever handles were typed.
    public func create() async {
        guard canCreate else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            let group = try await service.createGroup(name: trimmedName, handles: handles)
            groups.append(group)
            nameText = ""
            handlesText = ""
            pickedForNew = []
            editingId = group.id
            toast = .success(L10n.t("groups.created", group.name))
        } catch {
            guard suspension?.notice(error) != true else { return }
            toast = .error(APIError.wrapping(error).userMessage)
        }
    }

    /// Adds the typed handles to the group being edited.
    public func addMembers() async {
        guard let editingId, canAddMembers else { return }
        let wanted = handles
        isSaving = true
        defer { isSaving = false }
        do {
            let updated = try await service.addGroupMembers(id: editingId, handles: wanted)
            replace(updated)
            handlesText = ""
            toast = .success(L10n.plural("groups.member.added", wanted.count))
        } catch {
            guard suspension?.notice(error) != true else { return }
            // `user_not_found` names the first handle nobody holds, and the
            // server added nothing — so the field stands, uncorrected.
            toast = .error(APIError.wrapping(error).userMessage)
        }
    }

    public func removeMember(_ handle: String, from group: UserGroup) async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            replace(try await service.removeGroupMember(id: group.id, handle: handle))
            toast = .info(L10n.t("groups.member.removed", handle))
        } catch {
            guard suspension?.notice(error) != true else { return }
            toast = .error(APIError.wrapping(error).userMessage)
        }
    }

    public func requestDeletion(_ group: UserGroup) {
        pendingDeletion = group
    }

    public func cancelDeletion() {
        pendingDeletion = nil
    }

    public func confirmDeletion() async {
        guard let group = pendingDeletion, !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await service.deleteGroup(id: group.id)
            groups.removeAll { $0.id == group.id }
            if editingId == group.id { editingId = nil }
            pendingDeletion = nil
            toast = .info(L10n.t("groups.deleted", group.name))
        } catch {
            guard suspension?.notice(error) != true else { return }
            pendingDeletion = nil
            toast = .error(APIError.wrapping(error).userMessage)
        }
    }

    private func replace(_ group: UserGroup) {
        if let index = groups.firstIndex(where: { $0.id == group.id }) {
            groups[index] = group
        } else {
            groups.append(group)
        }
    }
}
