import Foundation
import Observation

/// Drives ``PeoplePickerSheet``: the people the viewer knows, a search for
/// everybody else, and the set they have ticked.
@MainActor
@Observable
public final class PeoplePickerViewModel {

    /// Followers and following, merged and sorted. Loaded once.
    public private(set) var known: [UserSummary] = []
    /// Search results for the current query, from the whole platform.
    public private(set) var results: [UserSummary] = []
    public private(set) var isLoading = false
    public private(set) var isSearching = false
    public private(set) var hasLoaded = false
    public var query = ""
    public var toast: SLToastMessage?
    /// Ticked handles, normalised.
    public private(set) var selected: Set<String> = []

    private let directory: PeopleDirectory
    private let viewerHandle: String
    /// Handles that are already in — invited, members — and so not offered.
    private let excluded: Set<String>
    private var picked: [String: UserSummary] = [:]

    public init(directory: PeopleDirectory, viewerHandle: String, excluding: [String] = []) {
        self.directory = directory
        self.viewerHandle = viewerHandle
        self.excluded = Set(excluding.map(Handle.normalised).filter { !$0.isEmpty })
    }

    public func load() async {
        guard !isLoading, !hasLoaded else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            known = try await directory.knownPeople(of: viewerHandle).filter { !excluded.contains(Handle.normalised($0.handle)) }
            hasLoaded = true
        } catch {
            toast = .error(APIError.wrapping(error).userMessage)
        }
    }

    /// The known people that match the query — every one of them when it is
    /// empty. Matching is on name and handle, case-insensitively.
    public var visibleKnown: [UserSummary] {
        let needle = Self.needle(query)
        guard !needle.isEmpty else { return known }
        return known.filter { Self.matches($0, needle) }
    }

    /// Search results that are not already among the known people.
    public var more: [UserSummary] {
        let knownHandles = Set(known.map { Handle.normalised($0.handle) })
        return results.filter {
            let key = Handle.normalised($0.handle)
            return !key.isEmpty && !knownHandles.contains(key) && !excluded.contains(key)
                && key != Handle.normalised(viewerHandle)
        }
    }

    /// Runs the search for the current query. Short queries search nothing.
    public func search() async {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "@", with: "")
        guard needle.count >= SearchConstants.minimumQueryLength else {
            results = []
            return
        }
        isSearching = true
        defer { isSearching = false }
        do {
            let found = try await directory.search(needle)
            // Only adopt the answer to the question still being asked.
            if Self.needle(query) == Self.needle(needle) { results = found }
        } catch {
            // A failed search leaves the known people on screen; nothing to say.
        }
    }

    public func isSelected(_ person: UserSummary) -> Bool {
        selected.contains(Handle.normalised(person.handle))
    }

    public func toggle(_ person: UserSummary) {
        let key = Handle.normalised(person.handle)
        guard !key.isEmpty else { return }
        if selected.contains(key) {
            selected.remove(key)
            picked[key] = nil
        } else {
            selected.insert(key)
            picked[key] = person
        }
    }

    /// The ticked people, in the order they were ticked is not kept; sorted by name.
    public var selectedPeople: [UserSummary] {
        picked.values.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    public var selectedCount: Int { selected.count }

    private static func needle(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: "@", with: "")
    }

    private static func matches(_ person: UserSummary, _ needle: String) -> Bool {
        person.displayName.lowercased().contains(needle) || Handle.normalised(person.handle).contains(needle)
    }
}
