import AppIntents
import CoreSpotlight
import Foundation
import UniformTypeIdentifiers

/// Puts one entry for the app itself into the iPhone's search (Spotlight and
/// the home-screen pull-down), so that typing "social" — not only "Known" —
/// finds it. The home-screen name stays "Known"; this only adds words iOS can
/// match on.
///
/// The entry is app-level, not account data: it stays through sign-out. It is
/// written once per app version and language, so a launch normally costs one
/// `UserDefaults` read.
public enum AppSearchIndex {

    /// The Spotlight domain the entry lives under, `app.known.search`.
    /// Spelled in pieces: as one literal it has the shape of a catalog key
    /// and `LocalizationCatalogTests` would look for it in the strings.
    public static let domain = ["app", "known", "search"].joined(separator: ".")
    /// The entry's id. Tapping it just opens the app.
    public static let itemIdentifier = domain + ".app"

    /// Words iOS should match in every language — the product's names and
    /// what it is, in English and Arabic.
    public static let baseKeywords = [
        "social", "social network", "network", "community", "verified",
        "real people", "know", "known", "rooms",
        "معروف", "تواصل", "تواصل اجتماعي", "شبكة اجتماعية", "مجتمع", "موثق"
    ]

    /// The keywords for the language the app is showing: the fixed list plus
    /// that language's words for "social" (`app.spotlight.keywords`, a
    /// comma-separated list), without duplicates, in order.
    public static func keywords() -> [String] {
        let localized = L10n.t("app.spotlight.keywords")
            .components(separatedBy: CharacterSet(charactersIn: ",،、"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != "app.spotlight.keywords" }
        var seen = Set<String>()
        return (baseKeywords + localized).filter { seen.insert($0.lowercased()).inserted }
    }

    /// The searchable item, in the current language.
    public static func makeItem() -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: .content)
        attributes.title = L10n.t("auth.brand.wordmark")
        attributes.displayName = attributes.title
        attributes.contentDescription = L10n.t("app.spotlight.description")
        attributes.keywords = keywords()
        let item = CSSearchableItem(
            uniqueIdentifier: itemIdentifier,
            domainIdentifier: domain,
            attributeSet: attributes
        )
        // Spotlight items expire after a month by default; this one should not.
        item.expirationDate = .distantFuture
        return item
    }

    /// What the stored stamp must equal for the index to be current.
    static func stamp(bundle: Bundle = .main, language: String = L10n.languageCode) -> String {
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(version)(\(build))|\(language)"
    }

    static let stampKey = "com.socialsa.sila.spotlightStamp"

    /// Writes the entry if this version or language has not written it yet.
    /// Safe to call on every launch and on every language change.
    @MainActor
    public static func refreshIfNeeded(defaults: UserDefaults = .standard) {
        guard !AppConfig.isRunningUnitTests, CSSearchableIndex.isIndexingAvailable() else { return }
        let stamp = stamp()
        guard defaults.string(forKey: stampKey) != stamp else { return }
        let item = makeItem()
        CSSearchableIndex.default().indexSearchableItems([item]) { error in
            guard error == nil else { return }
            DispatchQueue.main.async { defaults.set(stamp, forKey: stampKey) }
        }
    }
}

// MARK: - App Shortcut

/// "Open Known" for Siri, Shortcuts and search. Opens the app, nothing else.
struct OpenKnownIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Known"
    static let description: IntentDescription? = IntentDescription("Opens Known.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        .result()
    }
}

struct KnownAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenKnownIntent(),
            phrases: [
                "Open \(.applicationName)",
                "Open \(.applicationName) social",
                "Show \(.applicationName) social network"
            ],
            shortTitle: "Open Known",
            systemImageName: "person.2.fill"
        )
    }
}
