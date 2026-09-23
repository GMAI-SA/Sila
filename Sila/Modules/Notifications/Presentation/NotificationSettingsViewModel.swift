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
    /// Which kinds push to the phone, by wire name.
    public private(set) var push: [String: Bool] = [:]
    public private(set) var quietHours: QuietHours?
    public private(set) var savingPush: Set<String> = []
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
            push = stored.push
            quietHours = stored.quietHours
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

    // MARK: - Push

    /// The push switches, grouped like the in-app ones; kinds that only push
    /// (a message, a room reminder) are gathered at the end.
    public var pushSections: [NotificationGroup] {
        guard !push.isEmpty else { return [] }
        var seen = Set<String>()
        var sections: [NotificationGroup] = []
        for group in groups {
            let kinds = group.kinds.filter { push[$0] != nil }
            seen.formUnion(kinds)
            if !kinds.isEmpty { sections.append(NotificationGroup(id: group.id, kinds: kinds)) }
        }
        let rest = push.keys.filter { !seen.contains($0) }.sorted()
        if !rest.isEmpty { sections.append(NotificationGroup(id: "more", kinds: rest)) }
        return sections
    }

    public func isPushOn(_ key: String) -> Bool { push[key] ?? false }

    public func setPush(_ on: Bool, key: String) async {
        guard !savingPush.contains(key), isPushOn(key) != on else { return }
        let snapshot = push
        push[key] = on
        savingPush.insert(key)
        defer { savingPush.remove(key) }
        do {
            var update = PreferencesUpdate()
            update.push = [key: on]
            let stored = try await service.updatePreferences(update)
            push = stored.push.isEmpty ? push : stored.push
        } catch {
            push = snapshot
            toast = .error(for: error)
        }
    }

    /// Minutes after midnight → a date today, for the pickers.
    public static func date(minutes: Int) -> Date {
        Calendar.current.startOfDay(for: Date()).addingTimeInterval(TimeInterval(minutes * 60))
    }

    public static func minutes(of date: Date) -> Int {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    /// Turns quiet hours on (22:00–07:00 by default), changes them, or off.
    public func setQuietHours(_ hours: QuietHours?) async {
        let snapshot = quietHours
        if let hours, hours.startMin == hours.endMin { return }
        quietHours = hours
        do {
            var update = PreferencesUpdate()
            if let hours {
                update.quietHours = hours
                update.timezone = TimeZone.current.identifier
            } else {
                update.clearQuietHours = true
            }
            let stored = try await service.updatePreferences(update)
            quietHours = stored.quietHours
        } catch {
            quietHours = snapshot
            toast = .error(for: error)
        }
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
