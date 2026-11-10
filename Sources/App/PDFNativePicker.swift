import Foundation

/// A per-presentation user choice. No launch argument or persisted preference
/// can select import-copy in a production build.
enum PDFImportChoice {
    case original, importCopy

    func mode(experiment: PDFNativePickerExperiment.Configuration?) -> PDFNativePickerExperiment.Mode {
        if self == .importCopy { return .uikitImportCopy }
        #if DEBUG
        return experiment?.mode ?? .swiftUI
        #else
        return .swiftUI
        #endif
    }
}

/// The experiment can only attach to an already validated synthetic fixture.
/// Parsing these arguments never resolves a directory or selects a file.
enum PDFNativePickerExperiment {
    enum Mode: Equatable {
        case swiftUI, uikitOpen, uikitImportCopy

        var source: String {
            switch self {
            case .swiftUI: return "swiftui"
            case .uikitOpen: return "uikit"
            case .uikitImportCopy: return "uikit-copy"
            }
        }
        var usesUIKit: Bool { self != .swiftUI }
        var asCopy: Bool { self == .uikitImportCopy }
    }

    struct Configuration {
        let namespace: UUID
        let mode: Mode
        var usesUIKit: Bool { mode.usesUIKit }
        var source: String { mode.source }
    }

    static func configuration(arguments: [String], fixtureNamespace: UUID?) -> Configuration? {
        #if DEBUG
        guard let fixtureNamespace,
              arguments.filter({ $0 == "-UITestMode" }).count == 1,
              arguments.filter({ $0 == "-UITestSkillExecution" }).count == 1,
              arguments.filter({ $0 == "-UITestNamespace" }).count == 1,
              !arguments.contains(where: { $0.hasPrefix("-Live") }),
              let index = arguments.firstIndex(of: "-UITestNamespace"), arguments.indices.contains(index + 1),
              arguments[index + 1] == fixtureNamespace.uuidString else { return nil }
        let openFlag = "-UITestPDFUIKitPicker"
        let copyFlag = "-UITestPDFUIKitCopyPicker"
        let openCount = arguments.filter { $0 == openFlag }.count
        let copyCount = arguments.filter { $0 == copyFlag }.count
        guard openCount + copyCount <= 1,
              !arguments.contains(where: {
                  $0.hasPrefix("-UITestPDFUIKit") && $0 != openFlag && $0 != copyFlag
              }) else { return nil }
        let mode: Mode = copyCount == 1 ? .uikitImportCopy : openCount == 1 ? .uikitOpen : .swiftUI
        return Configuration(namespace: fixtureNamespace, mode: mode)
        #else
        return nil
        #endif
    }
}

#if os(iOS)
import SwiftUI
import UniformTypeIdentifiers
import UIKit
#if DEBUG
import Darwin
#endif

/// All arms return the original delegate URLs to the same caller's count,
/// selection and approval checks. App code does not read/copy here; the opt-in
/// import arm asks the OS picker to make a copy before the App's read approval.
@MainActor struct PDFImportPresentation: ViewModifier {
    @Binding var isPresented: Bool
    let choice: PDFImportChoice
    let experiment: PDFNativePickerExperiment.Configuration?
    let onCompletion: (Result<[URL], Error>) -> Void
    var onObservation: (String) -> Void = { _ in }
    // Supplied only from the validated synthetic fixture. Observation never
    // selects an experimental picker mode or changes the user's import choice.
    var observationNamespace: UUID? = nil

    @ViewBuilder func body(content: Content) -> some View {
        presentation(content)
            #if DEBUG
            .background {
                if let namespace = experiment?.namespace ?? observationNamespace {
                    PDFPickerModeProbe(namespace: namespace,
                                       source: choice == .importCopy ? "user-copy" : (experiment?.source ?? "swiftui"),
                                       isPresented: isPresented,
                                       onObservation: onObservation)
                        .frame(width: 0, height: 0).allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            #endif
    }

    private func swiftUIImporter(_ content: Content) -> some View {
        content.fileImporter(isPresented: $isPresented, allowedContentTypes: [.pdf],
                             allowsMultipleSelection: false, onCompletion: onCompletion)
    }

    @ViewBuilder private func presentation(_ content: Content) -> some View {
        let mode = choice.mode(experiment: experiment)
        if mode.usesUIKit {
            content.sheet(isPresented: $isPresented) {
                PDFNativePicker(asCopy: mode.asCopy) { outcome in
                    isPresented = false
                    // Cancellation matches fileImporter: dismiss without a
                    // success/empty callback or a prepared execution plan.
                    if let outcome { onCompletion(outcome) }
                }
            }
        } else {
            swiftUIImporter(content)
        }
    }
}

/// Explicit user import-copy, plus the DEBUG open/import-copy experiments.
/// No directoryURL, preselection,
/// bookmark recreation, URL substitution, automatic retry or picker fallback.
@MainActor private struct PDFNativePicker: UIViewControllerRepresentable {
    let asCopy: Bool
    let onCompletion: (Result<[URL], Error>?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCompletion: onCompletion) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.pdf], asCopy: asCopy)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIDocumentPickerViewController, context: Context) {
        context.coordinator.onCompletion = onCompletion
    }

    @MainActor final class Coordinator: NSObject, UIDocumentPickerDelegate {
        var onCompletion: (Result<[URL], Error>?) -> Void
        private var completed = false

        init(onCompletion: @escaping (Result<[URL], Error>?) -> Void) { self.onCompletion = onCompletion }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard !completed else { return }
            completed = true
            onCompletion(.success(urls)) // The common handler rejects counts other than one.
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            guard !completed else { return }
            completed = true
            onCompletion(nil)
        }
    }
}

#if DEBUG
/// A passive, bounded public-API observation in this view's own window. No
/// private class names/KVC, responder hooks, delegate replacement or AX probing.
@MainActor private struct PDFPickerModeProbe: UIViewControllerRepresentable {
    let namespace: UUID
    let source: String
    let isPresented: Bool
    let onObservation: (String) -> Void

    func makeUIViewController(context: Context) -> ProbeController { ProbeController() }
    func updateUIViewController(_ controller: ProbeController, context: Context) {
        controller.update(namespace: namespace, source: source,
                          isPresented: isPresented, onObservation: onObservation)
    }
    static func dismantleUIViewController(_ controller: ProbeController, coordinator: ()) { controller.stop() }

    @MainActor final class ProbeController: UIViewController {
        private var observation: Task<Void, Never>?
        private var presenting = false
        private var reported = false
        private var activeNamespace: UUID?
        private var activeSource: String?

        func update(namespace: UUID, source: String, isPresented: Bool,
                    onObservation: @escaping (String) -> Void) {
            guard isPresented else { stop(); return }
            guard !presenting else { return }
            presenting = true
            reported = false
            activeNamespace = namespace
            activeSource = source
            observation = Task { @MainActor [weak self] in
                // Defer until the SwiftUI presentation transaction completes.
                await Task.yield()
                // Passive observation only; never wait synchronously or extend
                // the test's existing 45-second native-picker readiness budget.
                for _ in 0..<90 {
                    guard let self, !Task.isCancelled, self.presenting else { return }
                    if let root = self.viewIfLoaded?.window?.rootViewController,
                       let picker = Self.visiblePicker(in: root) {
                        let mode: String
                        switch picker.documentPickerMode {
                        case .open: mode = "open"
                        case .import: mode = "import"
                        case .exportToService: mode = "export"
                        case .moveToService: mode = "move"
                        @unknown default: mode = "unknown"
                        }
                        let value = "source=\(source) mode=\(mode) allowsMultipleSelection=\(picker.allowsMultipleSelection)"
                        self.reported = true
                        Self.record(namespace: namespace, value: value)
                        onObservation(value)
                        return
                    }
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
                guard let self, !Task.isCancelled else { return }
                self.reported = true
                Self.record(namespace: namespace, value: "source=\(source) mode=unobserved")
            }
        }

        func stop() {
            if presenting, !reported, let namespace = activeNamespace, let source = activeSource {
                Self.record(namespace: namespace, value: "source=\(source) mode=unobserved")
            }
            presenting = false
            activeNamespace = nil
            activeSource = nil
            observation?.cancel(); observation = nil
        }

        private static func visiblePicker(in root: UIViewController) -> UIDocumentPickerViewController? {
            var pending = [root]
            var visited = Set<ObjectIdentifier>()
            // Only the application's public containment/presentation graph;
            // no enumeration of other scenes, processes or provider internals.
            for _ in 0..<64 {
                guard let controller = pending.popLast() else { return nil }
                guard visited.insert(ObjectIdentifier(controller)).inserted else { continue }
                if let picker = controller as? UIDocumentPickerViewController,
                   picker.viewIfLoaded?.window != nil, !picker.isBeingDismissed { return picker }
                pending.append(contentsOf: controller.children)
                if let presented = controller.presentedViewController { pending.append(presented) }
            }
            return nil
        }

        private static func record(namespace: UUID, value: String) {
            print("SKILL_PDF_PICKER_PRESENTATION namespace=\(namespace.uuidString) \(value) sampledAt=\(Date().timeIntervalSince1970)")
            fflush(stdout)
        }
    }
}
#endif
#endif
