import Foundation

// Portable checks of the exact routing/gate code used by PDFImportPresentation.
// Run both configurations; these are not native UIKit presentation tests:
// swiftc -parse-as-library -DDEBUG Sources/App/PDFNativePicker.swift \
//   scripts/PDFImportChoiceChecks.swift -o /tmp/woow-pdf-import-choice-debug
// /tmp/woow-pdf-import-choice-debug
// Repeat without -DDEBUG for the production route and launch-flag isolation.
@main
enum PDFImportChoiceChecks {
    struct Failure: Error { let message: String }
    private static var checks = 0

    static func require(_ value: Bool, _ message: String) throws {
        checks += 1
        if !value { throw Failure(message: message) }
    }

    static func main() throws {
        let namespace = UUID(uuidString: "A1111111-2222-4333-8444-555555555555")!
        let args = ["app", "-UITestMode", "-UITestSkillExecution", "-UITestNamespace", namespace.uuidString]

        try require(PDFImportChoice.original.mode(experiment: nil) == .swiftUI, "ordinary selection preserves SwiftUI")
        try require(PDFImportChoice.importCopy.mode(experiment: nil) == .uikitImportCopy, "explicit user copy works without fixture or flags")

        for mode: PDFNativePickerExperiment.Mode in [.swiftUI, .uikitOpen, .uikitImportCopy] {
            // Even a manually supplied experiment configuration cannot turn on
            // a production experiment. The user action is a separate input.
            let configuration = PDFNativePickerExperiment.Configuration(namespace: namespace, mode: mode)
            #if DEBUG
            try require(PDFImportChoice.original.mode(experiment: configuration) == mode, "existing DEBUG experiment still controls the original entry")
            #else
            try require(PDFImportChoice.original.mode(experiment: configuration) == .swiftUI, "Release must ignore even an injected experiment")
            #endif
            try require(PDFImportChoice.importCopy.mode(experiment: configuration) == .uikitImportCopy, "explicit copy choice does not depend on an experiment")
        }

        for flag in ["-UITestPDFUIKitPicker", "-UITestPDFUIKitCopyPicker"] {
            let configuration = PDFNativePickerExperiment.configuration(arguments: args + [flag], fixtureNamespace: namespace)
            #if DEBUG
            let expected: PDFNativePickerExperiment.Mode = flag == "-UITestPDFUIKitPicker" ? .uikitOpen : .uikitImportCopy
            try require(configuration?.mode == expected, "validated DEBUG experiment remains usable")
            #else
            try require(configuration == nil, "production must not accept experiment launch flags")
            try require(PDFImportChoice.original.mode(experiment: configuration) == .swiftUI, "flags cannot change ordinary production selection")
            #endif
            try require(PDFImportChoice.importCopy.mode(experiment: configuration).asCopy, "user-requested route asks the OS for a copy")

            let missingFixture = PDFNativePickerExperiment.configuration(arguments: args + [flag], fixtureNamespace: nil)
            try require(missingFixture == nil, "flags without a synthetic fixture are inactive")
            try require(PDFImportChoice.original.mode(experiment: missingFixture) == .swiftUI, "inactive flags do not activate UIKit")
        }

        for arguments in [args + ["-UITestPDFUIKitPicker", "-UITestPDFUIKitCopyPicker"],
                          args + ["-UITestPDFUIKitCopyPicker", "-UITestPDFUIKitCopyPicker"],
                          args + ["-UITestPDFUIKitUnknown"],
                          args + ["-UITestPDFUIKitCopyPicker", "-LiveModelUITest"]] {
            let configuration = PDFNativePickerExperiment.configuration(arguments: arguments, fixtureNamespace: namespace)
            try require(configuration == nil, "conflicting or invalid experiment inputs are rejected")
            try require(PDFImportChoice.original.mode(experiment: configuration) == .swiftUI, "rejected flags cannot activate a route")
        }

        #if DEBUG
        print("PASS DEBUG PDF import choice: \(checks) checks")
        #else
        print("PASS Release PDF import choice: \(checks) checks")
        #endif
    }
}
