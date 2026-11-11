import XCTest
@testable import WoowAssistant

/// Inspect the actual hosted app bundle. A source table or readable emergency
/// fallback cannot make this packaging acceptance pass.
@MainActor final class AppLanguageIntegrationTests: XCTestCase {
    func testPackagedLanguageTablesAndNativePluralResolution() throws {
        let expected: [(AppDisplayLanguage, String, String, String)] = [
            (.traditionalChinese, "外觀與模型權限", "1 個步驟", "2 個步驟"),
            (.simplifiedChinese, "外观与模型权限", "1 个步骤", "2 个步骤"),
            (.english, "Appearance and model permissions", "1 step", "2 steps")
        ]
        for (language, title, singular, plural) in expected {
            let directory = try XCTUnwrap(Bundle.main.url(forResource: language.rawValue, withExtension: "lproj"))
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("App.strings").path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("App.stringsdict").path))
            let localizer = AppLocalizer(language: language)
            for (message, text) in [(AppText.configurationTitle, title),
                                    (.configurationStepCount(count: 1), singular),
                                    (.configurationStepCount(count: 2), plural)] {
                let resolved = localizer.resolve(message)
                XCTAssertEqual(resolved.text, text)
                XCTAssertEqual(resolved.language, language)
                XCTAssertFalse(resolved.usedFallback)
            }
            let original = "%n %#@count@ 原文 🧋"
            XCTAssertTrue(localizer.text(.configurationChanged(appearance: original)).contains(original))
        }
    }
}
