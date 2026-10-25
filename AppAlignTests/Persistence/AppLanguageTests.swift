import Foundation
import XCTest

final class AppLanguageTests: XCTestCase {
    func testEnglishIsDefaultAndSelectionPersists() {
        let suite = "AppLanguageTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            XCTFail("Could not create test defaults")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(AppLanguage.selected(in: defaults), .english)
        AppLanguage.select(.japanese, in: defaults)
        XCTAssertEqual(AppLanguage.selected(in: defaults), .japanese)
        XCTAssertEqual(defaults.string(forKey: AppLanguage.defaultsKey), "ja")
        AppLanguage.select(.english, in: defaults)
        XCTAssertEqual(AppLanguage.selected(in: defaults), .english)
    }

    func testUnknownStoredLanguageFallsBackToEnglish() {
        let suite = "AppLanguageTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            XCTFail("Could not create test defaults")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set("fr", forKey: AppLanguage.defaultsKey)
        XCTAssertEqual(AppLanguage.selected(in: defaults), .english)
    }

    func testJapaneseTranslationAndNumberedStatus() {
        let bundle = Bundle(for: AppLanguageTests.self)
        XCTAssertEqual(L10n.string("Keyboard placement", language: .japanese, bundle: bundle), "キーボードによる配置")
        XCTAssertEqual(L10n.string("Zone 3", language: .japanese, bundle: bundle), "ゾーン3")
        XCTAssertEqual(L10n.string("Zone 3", language: .english, bundle: bundle), "Zone 3")
    }
}
