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
    /// `true` during the first load.
    public private(set) var isLoading = false
    /// `true` once a load has finished, successfully or not.
    public private(set) var hasLoaded = false
    /// Why the switches could not load.
    public private(set) var loadError: String?
    /// Kinds with a write in flight.
    public private(set) var savingKinds: Set<NotificationKind> = []
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
    public func isSaving(_ kind: NotificationKind) -> Bool { savingKinds.contains(kind) }

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
        defer {
            isLoading = false
            hasLoaded = true
        }
        do {
            preferences = try await service.fetchPreferences().notifications
        } catch {
            loadError = APIError.wrapping(error).userMessage
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
        guard !savingKinds.contains(kind) else { return }
        guard preferences.isEnabled(kind) != isEnabled else { return }

        let snapshot = preferences
        preferences = preferences.setting(isEnabled, for: kind)
        savingKinds.insert(kind)
        defer { savingKinds.remove(kind) }

        do {
            // The whole map goes every time. `PUT /me/preferences` replaces the
            // `notifications` object it is given, so sending one key would drop
            // the other four.
            let stored = try await service.updatePreferences(
                PreferencesUpdate(notifications: preferences.payload)
            )
            preferences = stored.notifications
            analytics.track(.notificationPreferenceChanged, properties: [
                "kind": kind.rawValue,
                "enabled": String(isEnabled)
            ])
        } catch {
            preferences = snapshot
            toast = .error(APIError.wrapping(error).userMessage)
        }
    }
}
