import Foundation
import Observation
import SwiftUI

/// The three things the language row can say.
public enum AppLanguageChoice: String, CaseIterable, Sendable {
    /// Follow the device — the default, and the only state that existed
    /// before the picker.
    case system
    /// Force English.
    case english = "en"
    /// Force Arabic.
    case arabic = "ar"

    /// The row label for this choice, written in the language it names —
    /// someone lost in the wrong language must be able to find their own.
    public var title: String {
        switch self {
        case .system: return L10n.t("profile.language.system")
        case .english: return "English"
        case .arabic: return "العربية"
        }
    }

    /// The forced language code, or `nil` for "whatever the system picked".
    public var overrideCode: String? {
        self == .system ? nil : rawValue
    }
}

/// Owns the in-app language choice: persists it, installs it into ``L10n``,
/// and tells SwiftUI when it changes.
///
/// This is the one production caller of ``L10n/use(_:)`` — the picker row in
/// the Profile tab goes through here, nothing in `Modules/` touches the
/// override directly, and tests keep using `withLanguage` as before.
///
/// The change applies **without a restart**: strings re-resolve because the
/// root view rebuilds on ``choice``, and the chrome flips direction because
/// the root also re-applies ``layoutDirection``.
@MainActor
@Observable
public final class LanguagePreference {

    /// The current choice. Set via ``select(_:)``.
    public private(set) var choice: AppLanguageChoice

    private let storage: StorageClient
    /// Where the system reads the app's own language from — the key iOS's
    /// per-app language setting writes. `nil` in tests.
    private let systemDefaults: UserDefaults?

    /// Restores the stored choice and installs it before anything renders.
    /// - Parameters:
    ///   - storage: Where the choice persists.
    ///   - systemDefaults: Told a forced language, so words the system draws
    ///     for the app follow it too — push banners, whose `loc-key` iOS
    ///     resolves from the app's strings in the app's language (contract
    ///     v21: the payload carries a key, never words).
    public init(storage: StorageClient, systemDefaults: UserDefaults? = AppConfig.isRunningUnitTests ? nil : .standard) {
        self.storage = storage
        self.systemDefaults = systemDefaults
        let stored = storage.value(for: .appLanguage, as: String.self)
            .flatMap(AppLanguageChoice.init(rawValue:)) ?? .system
        self.choice = stored
        apply(stored)
        // A forced language is told to the system again on every launch; the
        // device's own choice is left exactly as iOS's settings made it.
        if stored != .system { tellSystem(stored) }
    }

    /// Adopts and persists a choice.
    public func select(_ choice: AppLanguageChoice) {
        guard choice != self.choice else { return }
        // Apply first: if the build has no resources for the requested
        // language, nothing changed and nothing should be stored or shown.
        guard apply(choice) else { return }
        self.choice = choice
        storage.set(choice.rawValue, for: .appLanguage)
        tellSystem(choice)
    }

    /// Writes the app's language where iOS looks for it: a push that arrives
    /// while the app is closed is drawn by the system from `push.<kind>`, and
    /// without this it came out in the device's language — English banners
    /// for somebody reading the app in Arabic. "System" hands the choice back.
    private func tellSystem(_ choice: AppLanguageChoice) {
        guard let systemDefaults else { return }
        if let code = choice.overrideCode {
            systemDefaults.set([code], forKey: Self.appleLanguagesKey)
        } else {
            systemDefaults.removeObject(forKey: Self.appleLanguagesKey)
        }
    }

    static let appleLanguagesKey = "AppleLanguages"

    /// The direction the whole interface should run in right now.
    ///
    /// Derived from ``choice`` rather than read once, so the root view that
    /// observes this flips the moment the choice does.
    public var layoutDirection: LayoutDirection {
        switch choice {
        case .system: return L10n.layoutDirection
        case .english: return .leftToRight
        case .arabic: return .rightToLeft
        }
    }

    /// Installs the choice into ``L10n``. Returns whether it took.
    @discardableResult
    private func apply(_ choice: AppLanguageChoice) -> Bool {
        L10n.use(choice.overrideCode)
    }
}
