import Foundation
import Observation

/// Drives ``NotificationSettingsSheet``.
///
/// The five switches live in `/me/preferences` beside the feed settings, but
/// they get their own surface because of where people go looking for them: the
/// person who wants likes silenced is, by definition, standing in the
/// notifications list being bothered by likes. Making them find it under "Feed
/// preferences" would be filing the off switch in a different room.
///
/// Each switch saves on its own, immediately. There is no Save button and no
/// draft: a notification setting is a single fact, `PUT /me/preferences` is a
/// partial update, and a screen of five independent switches that could be
/// abandoned half-applied would be worse than one that commits as it goes.
@MainActor
@Observable
public final class NotificationSettingsViewModel {

    /// The map the server last confirmed. Never written optimistically except
    /// for the moment a switch is in flight — see ``setEnabled(_:for:)``.
    public private(set) var preferences = NotificationPreferences()
    /// The sections as the server grouped them (contract v19). Falls back to
    /// this build's own list when an older server sends no groups.
    public private(set) var groups: [NotificationGroup] = []
    /// `true` during the first load.
    public private(set) var isLoading = false
    /// `true` once a load has finished, successfully or not.
    public private(set) var hasLoaded = false
    /// Why the switches could not load.
    public private(set) var loadError: String?
    /// Kinds, by wire name, with a write in flight.
    public private(set) var savingKeys: Set<String> = []
    /// Banner message.
    public var toast: SLToastMessage?

    private let service: PreferencesServiceProtocol
    private let analytics: AnalyticsClient

    /// - Parameters:
    ///   - service: The preferences backend — the same one the feed settings
    ///     use, because this is the same document.
    ///   - analytics: Event sink.
    public init(service: PreferencesServiceProtocol, analytics: AnalyticsClient) {
        self.service = service
        self.analytics = analytics
    }

    // MARK: - Derived state

    /// The sentence under the list, describing what is currently silenced.
    public var summary: String { NotificationCopy.settingsSummary(preferences) }

    /// Whether a specific switch is mid-write.
    public func isSaving(_ kind: NotificationKind) -> Bool { savingKeys.contains(kind.rawValue) }

    /// Whether a switch, by wire name, is mid-write.
    public func isSaving(key: String) -> Bool { savingKeys.contains(key) }

    /// What the sheet draws: the server's groups, or one section of this
    /// build's own switches when the server did not group them.
    public var sections: [NotificationGroup] {
        groups.isEmpty
            ? [NotificationGroup(id: "posts", kinds: NotificationKind.settable.map(\.rawValue))]
            : groups
    }

    // MARK: - Loading

    /// Loads the stored map. Safe on every appearance.
    public func load() async {
        guard !hasLoaded, !isLoading else { return }
        await reload()
    }

    /// Loads unconditionally — the retry path.
    public func reload() async {
        isLoading = true
        loadError = nil
        var abandoned = false
        defer {
            isLoading = false
            if !abandoned { hasLoaded = true }
        }
        do {
            let stored = try await service.fetchPreferences()
            preferences = stored.notifications
            groups = stored.notificationGroups
        } catch {
            // Cut short: nothing loaded, nothing failed, ask again next time.
            abandoned = APIError.wrapping(error).isCancellation
            loadError = APIError.wrapping(error).presentableMessage
        }
    }

    // MARK: - Writing

    /// Flips one kind and writes it.
    ///
    /// The switch moves under the finger and is put **back** if the server
    /// refuses — a control that stayed where it was left while the server
    /// disagreed would be telling somebody their likes are silenced when they
    /// are not.
    /// - Parameters:
    ///   - isEnabled: The state the user asked for.
    ///   - kind: Which notifications it governs.
    public func setEnabled(_ isEnabled: Bool, for kind: NotificationKind) async {
        await setEnabled(isEnabled, key: kind.rawValue)
    }

    /// Flips one kind, by its wire name, and writes it — for kinds the server
    /// lists that this build has no case for.
    public func setEnabled(_ isEnabled: Bool, key: String) async {
        guard !savingKeys.contains(key) else { return }
        guard preferences.isEnabled(key: key) != isEnabled else { return }

        let snapshot = preferences
        preferences = preferences.setting(isEnabled, key: key)
        savingKeys.insert(key)
        defer { savingKeys.remove(key) }

        do {
            // The whole map goes every time, so a write can never be read as
            // switching the others back to a default.
            let stored = try await service.updatePreferences(
                PreferencesUpdate(notifications: preferences.payload)
            )
            preferences = stored.notifications
            if !stored.notificationGroups.isEmpty { groups = stored.notificationGroups }
            analytics.track(.notificationPreferenceChanged, properties: [
                "kind": key,
                "enabled": String(isEnabled)
            ])
        } catch {
            preferences = snapshot
            toast = .error(for: error)
        }
    }
}
