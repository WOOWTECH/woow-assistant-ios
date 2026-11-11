import Foundation
import AssistantSkills

@MainActor enum LanguageResourceChecks {
    static func run(resourceRoot: URL) throws -> Int {
        var passed = 0
        func check(_ condition: Bool, _ label: String) throws {
            guard condition else { throw NSError(domain: "LanguageResources", code: 1, userInfo: [NSLocalizedDescriptionKey: label]) }
            passed += 1
        }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("language-resources-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        func makeBundle(_ name: String, languages: [String], omitKey: String? = nil) throws -> Bundle {
            let url = root.appendingPathComponent(name + ".bundle")
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            let info = ["CFBundleIdentifier": "io.woow.language." + name, "CFBundlePackageType": "BNDL", "CFBundleDevelopmentRegion": "zh-Hant"]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: url.appendingPathComponent("Info.plist"))
            for language in languages {
                let from = resourceRoot.appendingPathComponent(language + ".lproj")
                let to = url.appendingPathComponent(language + ".lproj")
                try fm.copyItem(at: from, to: to)
                if let omitKey, language == "en" {
                    let path = to.appendingPathComponent("App.strings")
                    var strings = try PropertyListSerialization.propertyList(from: Data(contentsOf: path), format: nil) as! [String: String]
                    strings.removeValue(forKey: omitKey)
                    try PropertyListSerialization.data(fromPropertyList: strings, format: .xml, options: 0).write(to: path)
                }
            }
            return Bundle(url: url)!
        }
        let bundle = try makeBundle("complete", languages: ["zh-Hant", "zh-Hans", "en"])
        let expected: [(AppDisplayLanguage, String, String)] = [(.traditionalChinese, "外觀與模型權限", "個步驟"), (.simplifiedChinese, "外观与模型权限", "个步骤"), (.english, "Appearance and model permissions", "steps")]
        for (language, title, plural) in expected {
            let l = AppLocalizer(language: language, bundle: bundle)
            try check(l.resolve(.configurationTitle).text == title && !l.resolve(.configurationTitle).usedFallback, "actual localized bundle title")
            for count in [0, 1, 2, 1001] {
                let rendered = l.resolve(.configurationStepCount(count: count))
                let numeral = count == 1001 ? "1,001" : String(count)
                let suffix = language == .english && count == 1 ? "step" : plural
                try check(rendered.text == numeral + " " + suffix && !rendered.usedFallback, "native stringsdict plural and explicit locale")
            }
            let external = "%1$@ %n %#@count@ configuration.title\n使用者原文 🧋"
            let rendered = l.text(.configurationChanged(appearance: external))
            try check(rendered.contains(external), "parameter is verbatim data, never recursive format/key/markup")
            let state = SelfConfigurationMessage.changed(.dark)
            try check(state.text(using: l).contains(l.appearanceName(.dark)), "stored dynamic status renders current localized argument")
        }
        let state = SelfConfigurationMessage.running
        let en = AppLocalizer(language: .english, bundle: bundle)
        let hans = AppLocalizer(language: .simplifiedChinese, bundle: bundle)
        try check(state.text(using: en) == "Checking and changing appearance…" && state.text(using: hans) == "正在查询并调整外观……", "same in-flight state re-renders without restarting it")
        let errors: [SelfConfigurationError] = [.permissionRequired, .authorizationChanged, .cancelled, .invalidRequest, .invalidCommand, .listRequired, .unavailableSetting, .invalidValue, .alreadyUsed, .timedOut, .modelFailed, .persistenceFailed]
        let hant = AppLocalizer(language: .traditionalChinese, bundle: bundle)
        for error in errors {
            try check(hant.text(hant.configurationError(error)) == error.errorDescription, "existing Traditional Chinese error preserved exactly")
            try check(en.text(en.configurationError(error)) != error.errorDescription && hans.text(hans.configurationError(error)) != error.errorDescription, "known error has explicit translations")
        }
        try check(en.configurationStep(.appliedAppearance(.light)) == "settings_set: Saved and read back “Light”", "typed readback event localization")
        let partial = try makeBundle("partial", languages: ["zh-Hant", "en"], omitKey: "configuration.title")
        let fallback = AppLocalizer(language: .english, bundle: partial).resolve(.configurationTitle)
        try check(fallback.text == "外觀與模型權限" && fallback.language == .traditionalChinese && fallback.usedFallback, "missing individual key falls back to Hant, not system English")
        let missingLanguage = AppLocalizer(language: .simplifiedChinese, bundle: partial).resolve(.configurationStepCount(count: 2))
        try check(missingLanguage.text == "2 個步驟" && missingLanguage.usedFallback, "missing language plural falls back to Hant")
        let empty = try makeBundle("empty", languages: [])
        let emergency = AppLocalizer(language: .english, bundle: empty)
        try check(emergency.text(.configurationTitle) == "外觀與模型權限" && emergency.resolve(.configurationTitle).usedFallback, "missing packaged resources preserve readable Hant")
        try check(emergency.text(.configurationStepCount(count: 2)) == "2 個步驟", "missing packaged plural uses typed Hant fallback")
        let modelErrors: [ModelSettingsError] = [.invalidURL, .missingModel, .missingKey, .changedOrigin, .invalidKey, .unavailableKeychain, .keychainStatus(-25293)]
        for error in modelErrors {
            let message = AppLocalizer.modelSettingsError(error)
            try check(hant.text(message) == error.errorDescription, "model settings code presentation preserves original Hant including ungrouped system code")
            try check(en.text(message) != error.errorDescription && !en.resolve(message).usedFallback, "shared known setting errors have packaged English translations")
        }
        try check(en.text(.modelSettingsKeychainStatus(code: "-25293")).contains("-25293"), "system code is not locale-grouped")
        let workerNotice = AppText.workerSaved
        try check(en.text(workerNotice) == "Settings saved. No connection or document upload has been made." && hans.text(workerNotice) == "设置已保存；尚未连接或上传文件。", "stored worker notice re-renders across languages without connecting")
        let uuid = UUID().uuidString
        let suite = try AppLanguagePreferences.suiteName(arguments: ["-UITestMode", "-UITestNamespace", uuid], debug: true)
        try check(suite.hasSuffix(".test." + uuid), "fixture preferences are isolated")
        try check(try AppLanguagePreferences.suiteName(arguments: ["-LiveModelUITest", "-LiveModelUITestNamespace", uuid], debug: true) == suite, "live fixture preferences use explicit namespace")
        for arguments in [["-UITestMode"], ["-UITestNamespace", uuid], ["-UITestMode", "-UITestNamespace", "bad"], ["-UITestMode", "-LiveModelUITest", "-UITestNamespace", uuid], ["-UITestMode", "-UITestNamespace", uuid, "-LiveModelUITestNamespace", uuid], ["-UITestMode", "-UITestMode", "-UITestNamespace", uuid], ["-UITestMode", "-UITestNamespace", uuid, "-UITestNamespace", uuid]] {
            do { _ = try AppLanguagePreferences.suiteName(arguments: arguments, debug: true); try check(false, "invalid namespace accepted") }
            catch AppLanguagePreferences.ConfigurationError.invalidTestNamespace { passed += 1 }
        }
        try check(try AppLanguagePreferences.suiteName(arguments: ["-UITestMode"], debug: false) == AppLanguagePreferences.productionSuite, "Release ignores harness arguments")
        return passed
    }
}
