import XCTest
@testable import LokalBot

final class AppLanguageTests: XCTestCase {
    func testSystemLanguageUsesSupportedPreferencesAndFallsBackToEnglish() {
        XCTAssertEqual(AppLanguage.system.localizationIdentifier(preferredLanguages: ["zh-Hans-CN", "en"]), "zh-Hans")
        XCTAssertEqual(AppLanguage.system.localizationIdentifier(preferredLanguages: ["zh-TW"]), "zh-Hans")
        XCTAssertEqual(AppLanguage.system.localizationIdentifier(preferredLanguages: ["fr-FR", "zh_CN"]), "zh-Hans")
        XCTAssertEqual(AppLanguage.system.localizationIdentifier(preferredLanguages: ["en-GB", "zh-Hans"]), "en")
        XCTAssertEqual(AppLanguage.system.localizationIdentifier(preferredLanguages: ["fr-FR"]), "en")
        XCTAssertEqual(AppLanguage.system.localizationIdentifier(preferredLanguages: []), "en")
    }

    func testExplicitSelectionOverridesSystemLanguage() {
        XCTAssertEqual(AppLanguage.english.localizationIdentifier(preferredLanguages: ["zh-Hans"]), "en")
        XCTAssertEqual(AppLanguage.simplifiedChinese.localizationIdentifier(preferredLanguages: ["en"]), "zh-Hans")
    }

    func testLanguagePreferencePersistsWithoutChangingContentLanguages() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "AppLanguageTests.\(UUID().uuidString)"))
        defer { defaults.removeObject(forKey: AppSettings.key) }
        for language in AppLanguage.allCases {
            var settings = AppSettings()
            settings.appLanguage = language
            let transcriptionLanguage = settings.transcriptionLanguage
            let summaryLanguage = settings.summaryLanguage
            settings.save(to: defaults)
            let restored = AppSettings.load(from: defaults)
            XCTAssertEqual(restored.appLanguage, language)
            XCTAssertEqual(restored.transcriptionLanguage, transcriptionLanguage)
            XCTAssertEqual(restored.summaryLanguage, summaryLanguage)
        }
    }

    func testLegacyAndUnknownLanguageDoNotResetOtherSettings() throws {
        XCTAssertEqual(AppSettings().appLanguage, .system)
        for json in [#"{"menuBarOnly":false}"#, #"{"menuBarOnly":false,"appLanguage":"future-language"}"#] {
            let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
            XCTAssertEqual(settings.appLanguage, .system)
            XCTAssertFalse(settings.menuBarOnly)
        }
    }

    func testUserEnteredSettingsValuesAreNotTranslated() throws {
        let descriptor = try XCTUnwrap(SettingDescriptor.all.first { $0.id == "settings.cotypingUserName" })
        var settings = AppSettings()
        settings.cotypingUserName = "Settings"
        XCTAssertEqual(descriptor.currentValue(in: settings, language: .simplifiedChinese), "Settings")
    }

    func testBundledChineseAndEnglishAndMissingKeyFallback() {
        XCTAssertEqual(AppLanguage.simplifiedChinese.localized("Settings"), "设置")
        XCTAssertEqual(AppLanguage.simplifiedChinese.localized("App language"), "界面语言")
        XCTAssertEqual(AppLanguage.english.localized("Settings"), "Settings")
        XCTAssertEqual(AppLanguage.simplifiedChinese.localized("unknown.localization.key"), "unknown.localization.key")
    }

    @MainActor
    func testSettingsSearchFindsTranslatedLabelsAndLanguageAliases() {
        for query in ["语言", "中文", "English", "界面语言"] {
            XCTAssertTrue(SettingDescriptor.search(query, language: .simplifiedChinese).contains { $0.id == "settings.appLanguage" })
        }
        XCTAssertTrue(SettingDescriptor.search("文字大小", language: .simplifiedChinese).contains { $0.id == "settings.textSize" })
        XCTAssertTrue(SettingDescriptor.search("Theme", language: .simplifiedChinese).contains { $0.id == "settings.appTheme" })
    }
}
