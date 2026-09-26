import XCTest
import SwiftUI
@testable import Sila

/// The in-app language choice: persisted, installed into ``L10n``, and honest
/// about direction. These tests touch the global override, so every one
/// restores the system state before it returns.
@MainActor
final class LanguagePreferenceTests: XCTestCase {

    override func tearDown() {
        L10n.use(nil)
        super.tearDown()
    }

    func testDefaultsToSystemAndInstallsNoOverride() {
        let preference = LanguagePreference(storage: InMemoryStorageClient())

        XCTAssertEqual(preference.choice, .system)
        XCTAssertNil(L10n.override)
    }

    func testSelectingArabicAppliesPersistsAndFlipsDirection() {
        let storage = InMemoryStorageClient()
        let preference = LanguagePreference(storage: storage)

        preference.select(.arabic)

        XCTAssertEqual(preference.choice, .arabic)
        XCTAssertEqual(L10n.override?.code, "ar")
        XCTAssertEqual(L10n.languageCode, "ar")
        XCTAssertEqual(preference.layoutDirection, .rightToLeft)
        XCTAssertEqual(storage.value(for: .appLanguage, as: String.self), "ar")
        // The proof that strings actually re-resolve: a known key in Arabic.
        XCTAssertEqual(L10n.t("profile.language.title"), "اللغة")
    }

    func testSelectingEnglishAppliesAndRunsLeftToRight() {
        let preference = LanguagePreference(storage: InMemoryStorageClient())

        preference.select(.english)

        XCTAssertEqual(L10n.override?.code, "en")
        XCTAssertEqual(preference.layoutDirection, .leftToRight)
        XCTAssertEqual(L10n.t("profile.language.title"), "Language")
    }

    func testStoredChoiceIsRestoredOnConstruction() {
        let storage = InMemoryStorageClient()
        storage.set("ar", for: .appLanguage)

        let preference = LanguagePreference(storage: storage)

        XCTAssertEqual(preference.choice, .arabic)
        XCTAssertEqual(L10n.override?.code, "ar", "the stored choice must be live before the first string renders")
    }

    func testCorruptStoredValueFallsBackToSystem() {
        let storage = InMemoryStorageClient()
        storage.set("klingon", for: .appLanguage)

        let preference = LanguagePreference(storage: storage)

        XCTAssertEqual(preference.choice, .system)
        XCTAssertNil(L10n.override)
    }

    func testBackToSystemClearsTheOverride() {
        let storage = InMemoryStorageClient()
        let preference = LanguagePreference(storage: storage)
        preference.select(.arabic)

        preference.select(.system)

        XCTAssertEqual(preference.choice, .system)
        XCTAssertNil(L10n.override)
        XCTAssertEqual(storage.value(for: .appLanguage, as: String.self), "system")
    }

    /// The suite's own value, not the device-wide one the global domain
    /// would answer with.
    private func own(_ defaults: UserDefaults, _ suite: String) -> [String]? {
        defaults.persistentDomain(forName: suite)?[LanguagePreference.appleLanguagesKey] as? [String]
    }

    /// A push arriving while the app is closed is drawn by iOS from the
    /// app's strings, in the language iOS thinks the app is in.
    func testAForcedLanguageIsToldToTheSystemAndSystemHandsItBack() throws {
        let suite = "sila.tests.language.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let preference = LanguagePreference(storage: InMemoryStorageClient(), systemDefaults: defaults)
        XCTAssertNil(own(defaults, suite), "the device's choice is not touched")

        preference.select(.arabic)
        XCTAssertEqual(own(defaults, suite), ["ar"])
        preference.select(.system)
        XCTAssertNil(own(defaults, suite))
    }

    func testFollowingTheDeviceLeavesIOSsOwnPerAppSettingAlone() throws {
        let suite = "sila.tests.language.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        // What Settings › Sila › Language writes.
        defaults.set(["ar"], forKey: LanguagePreference.appleLanguagesKey)

        _ = LanguagePreference(storage: InMemoryStorageClient(), systemDefaults: defaults)
        XCTAssertEqual(own(defaults, suite), ["ar"])

        let storage = InMemoryStorageClient()
        storage.set("en", for: .appLanguage)
        _ = LanguagePreference(storage: storage, systemDefaults: defaults)
        XCTAssertEqual(own(defaults, suite), ["en"],
                       "a forced language is told again at launch")
    }

    func testEveryChoiceHasATitleWrittenInItsOwnLanguage() {
        // Somebody stranded in the wrong language must be able to find their
        // own name for it, whatever the interface currently speaks.
        XCTAssertEqual(AppLanguageChoice.english.title, "English")
        XCTAssertEqual(AppLanguageChoice.arabic.title, "العربية")
        XCTAssertFalse(AppLanguageChoice.system.title.isEmpty)
    }
}
