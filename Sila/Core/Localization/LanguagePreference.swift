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

    /// Restores the stored choice and installs it before anything renders.
    /// - Parameter storage: Where the choice persists.
    public init(storage: StorageClient) {
        self.storage = storage
        let stored = storage.value(for: .appLanguage, as: String.self)
            .flatMap(AppLanguageChoice.init(rawValue:)) ?? .system
        self.choice = stored
        apply(stored)
    }

    /// Adopts and persists a choice.
    public func select(_ choice: AppLanguageChoice) {
        guard choice != self.choice else { return }
        // Apply first: if the build has no resources for the requested
        // language, nothing changed and nothing should be stored or shown.
        guard apply(choice) else { return }
        self.choice = choice
        storage.set(choice.rawValue, for: .appLanguage)
    }

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
