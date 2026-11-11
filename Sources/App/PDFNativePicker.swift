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

    /// Separate arm: extraction's open/copy flags never change assembly.
    static func assemblyConfiguration(arguments: [String], fixtureNamespace: UUID?) -> Configuration? {
        #if DEBUG
        let flag = "-UITestPDFAssemblyUIKitOpen"
        guard let base = configuration(arguments: arguments, fixtureNamespace: fixtureNamespace),
              base.mode == .swiftUI,
              arguments.filter({ $0 == flag }).count <= 1,
              !arguments.contains(where: { $0.hasPrefix("-UITestPDFAssembly") && $0 != flag }) else { return nil }
        return Configuration(namespace: base.namespace, mode: arguments.contains(flag) ? .uikitOpen : .swiftUI)
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
    var allowsMultipleSelection: Bool = false
    let onCompletion: (Result<[URL], Error>) -> Void
    var onCancellation: () -> Void = {}
    var onObservation: (String) -> Void = { _ in }
    // Supplied only from the validated synthetic fixture. Observation never
    // selects an experimental picker mode or changes the user's import choice.
    var observationNamespace: UUID? = nil
    #if DEBUG
    @State private var presentationCount = 0
    @State private var callbackCount = 0
    #endif

    @ViewBuilder func body(content: Content) -> some View {
        presentation(content)
            #if DEBUG
            .background {
                if let namespace = experiment?.namespace ?? observationNamespace {
                    PDFPickerModeProbe(namespace: namespace,
                                       source: choice == .importCopy ? "user-copy" : (experiment?.source ?? "swiftui"),
                                       isPresented: isPresented,
                                       onObservation: onObservation, onIdentity: recordIdentity)
                        .frame(width: 0, height: 0).allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            .onChange(of: isPresented) { _, presented in
                if presented {
                    presentationCount += 1; callbackCount = 0
                    let mode = choice.mode(experiment: experiment)
                    let copy = mode.usesUIKit ? String(mode.asCopy) : "notExposed"
                    recordIdentity("event=requested ordinal=\(presentationCount) adapter=\(mode.usesUIKit ? "uikit" : "swiftui") requestedUTType=\(UTType.pdf.identifier) requestedAsCopy=\(copy) allowsMultipleSelection=\(allowsMultipleSelection)")
                }
                recordLifecycle("event=bindingChanged ordinal=\(presentationCount) presented=\(presented) callbacks=\(callbackCount)")
            }
            #endif
    }

    private func swiftUIImporter(_ content: Content) -> some View {
        content.fileImporter(isPresented: $isPresented, allowedContentTypes: [.pdf],
                             allowsMultipleSelection: allowsMultipleSelection, onCompletion: { outcome in
            deliver(outcome, source: "swiftui")
        }, onCancellation: onCancellation)
    }

    @ViewBuilder private func presentation(_ content: Content) -> some View {
        let mode = choice.mode(experiment: experiment)
        if mode.usesUIKit {
            content.sheet(isPresented: $isPresented) {
                PDFNativePicker(asCopy: mode.asCopy, allowsMultipleSelection: allowsMultipleSelection,
                                onLifecycle: recordLifecycle, onIdentity: recordIdentity) { outcome in
                    isPresented = false
                    // Cancellation matches fileImporter: dismiss without a
                    // success/empty callback or a prepared execution plan.
                    if let outcome { deliver(outcome, source: "uikit") }
                    else { onCancellation() }
                }
            }
        } else {
            swiftUIImporter(content)
        }
    }

    private func deliver(_ outcome: Result<[URL], Error>, source: String) {
        #if DEBUG
        if callbackCount < 16 {
            callbackCount += 1
            let category: String
            switch outcome {
            case .success(let urls): category = urls.isEmpty ? "empty" : urls.count == 1 ? "one" : "multiple"
            case .failure: category = "failure"
            }
            recordLifecycle("event=completion source=\(source) callbacks=\(callbackCount) outcome=\(category)")
        }
        #endif
        onCompletion(outcome)
    }

    private func recordIdentity(_ value: String) {
        #if DEBUG
        guard presentationCount <= 3,
              let namespace = experiment?.namespace ?? observationNamespace,
              PDFNativePickerExperiment.configuration(arguments: ProcessInfo.processInfo.arguments,
                                                       fixtureNamespace: namespace) != nil else { return }
        print("SKILL_PDF_PICKER_IDENTITY namespace=\(namespace.uuidString) \(value) sampledAt=\(Date().timeIntervalSince1970)")
        fflush(stdout)
        #endif
    }

    private func recordLifecycle(_ value: String) {
        #if DEBUG
        guard let namespace = experiment?.namespace ?? observationNamespace else { return }
        print("SKILL_PDF_PICKER_LIFECYCLE namespace=\(namespace.uuidString) \(value) sampledAt=\(Date().timeIntervalSince1970)")
        fflush(stdout)
        #endif
    }
}

/// Explicit user import-copy, plus the DEBUG open/import-copy experiments.
/// No directoryURL, preselection,
/// bookmark recreation, URL substitution, automatic retry or picker fallback.
@MainActor private struct PDFNativePicker: UIViewControllerRepresentable {
    let asCopy: Bool
    let allowsMultipleSelection: Bool
    let onLifecycle: (String) -> Void
    let onIdentity: (String) -> Void
    let onCompletion: (Result<[URL], Error>?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCompletion: onCompletion, onLifecycle: onLifecycle, onIdentity: onIdentity) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.pdf], asCopy: asCopy)
        picker.allowsMultipleSelection = allowsMultipleSelection
        picker.delegate = context.coordinator
        #if DEBUG
        context.coordinator.record("nativeCreated", picker)
        #endif
        return picker
    }

    func updateUIViewController(_ picker: UIDocumentPickerViewController, context: Context) {
        // One controller owns one immutable presentation callback. A late
        // delegate must not acquire a newer selection request's closure.
    }

    static func dismantleUIViewController(_ picker: UIDocumentPickerViewController, coordinator: Coordinator) {
        #if DEBUG
        coordinator.record("nativeDismantled", picker)
        #endif
    }

    @MainActor final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onCompletion: (Result<[URL], Error>?) -> Void
        let onLifecycle: (String) -> Void
        let onIdentity: (String) -> Void
        private var completed = false
        #if DEBUG
        private var callbacks = 0
        private weak var createdPicker: UIDocumentPickerViewController?
        #endif

        init(onCompletion: @escaping (Result<[URL], Error>?) -> Void, onLifecycle: @escaping (String) -> Void,
             onIdentity: @escaping (String) -> Void) {
            self.onCompletion = onCompletion; self.onLifecycle = onLifecycle; self.onIdentity = onIdentity
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            #if DEBUG
            callbacks = min(callbacks + 1, 16)
            record("nativePicked", controller)
            #endif
            guard !completed else { return }
            completed = true
            onCompletion(.success(urls)) // Caller enforces its own selection-count bounds.
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            #if DEBUG
            callbacks = min(callbacks + 1, 16)
            record("nativeCancelled", controller)
            #endif
            guard !completed else { return }
            completed = true
            onCompletion(nil)
        }

        #if DEBUG
        func record(_ event: String, _ controller: UIDocumentPickerViewController) {
            if event == "nativeCreated" { createdPicker = controller }
            guard callbacks < 16 else { return }
            onIdentity("event=\(event) pickerMatchesCreated=\(createdPicker === controller) delegateIsCoordinator=\(controller.delegate === self) callbacks=\(callbacks)")
            let snapshot = PDFPickerModeProbe.snapshot(controller)
            onLifecycle("event=\(event) \(snapshot) identitySame=\(createdPicker === controller) callbacks=\(callbacks)")
        }
        #endif
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
    let onIdentity: (String) -> Void

    func makeUIViewController(context: Context) -> ProbeController { ProbeController() }
    func updateUIViewController(_ controller: ProbeController, context: Context) {
        controller.update(namespace: namespace, source: source,
                          isPresented: isPresented, onObservation: onObservation, onIdentity: onIdentity)
    }
    static func dismantleUIViewController(_ controller: ProbeController, coordinator: ()) { controller.stop() }

    static func snapshot(_ picker: UIDocumentPickerViewController) -> String {
        let mode: String
        switch picker.documentPickerMode {
        case .open: mode = "open"
        case .import: mode = "import"
        case .exportToService: mode = "export"
        case .moveToService: mode = "move"
        @unknown default: mode = "unknown"
        }
        return "mode=\(mode) allowsMultipleSelection=\(picker.allowsMultipleSelection) delegatePresent=\(picker.delegate != nil) inWindow=\(picker.viewIfLoaded?.window != nil) dismissing=\(picker.isBeingDismissed)"
    }

    @MainActor final class ProbeController: UIViewController {
        private var observation: Task<Void, Never>?
        private var presenting = false
        private var reported = false
        private var activeNamespace: UUID?
        private var activeSource: String?
        private weak var firstPicker: UIDocumentPickerViewController?
        private weak var firstDelegate: AnyObject?
        private var identityObservation: ((String) -> Void)?

        func update(namespace: UUID, source: String, isPresented: Bool,
                    onObservation: @escaping (String) -> Void, onIdentity: @escaping (String) -> Void) {
            guard isPresented else { stop(); return }
            guard !presenting else { return }
            presenting = true
            reported = false
            activeNamespace = namespace
            activeSource = source
            identityObservation = onIdentity
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
                        self.firstPicker = picker
                        self.firstDelegate = picker.delegate
                        onIdentity("event=probeObserved source=\(source) delegatePresent=\(picker.delegate != nil)")
                        Self.record(namespace: namespace, value: value)
                        Self.record(namespace: namespace, value: "source=\(source) event=observed " + PDFPickerModeProbe.snapshot(picker), lifecycle: true)
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
            if presenting, reported, let source = activeSource {
                let delegateSame = firstDelegate != nil && firstPicker?.delegate === firstDelegate
                identityObservation?("event=probeStopped source=\(source) pickerAlive=\(firstPicker != nil) initialDelegateAlive=\(firstDelegate != nil) delegateUnchanged=\(delegateSame)")
            }
            firstPicker = nil; firstDelegate = nil; identityObservation = nil
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

        private static func record(namespace: UUID, value: String, lifecycle: Bool = false) {
            let prefix = lifecycle ? "SKILL_PDF_PICKER_LIFECYCLE" : "SKILL_PDF_PICKER_PRESENTATION"
            print("\(prefix) namespace=\(namespace.uuidString) \(value) sampledAt=\(Date().timeIntervalSince1970)")
            fflush(stdout)
        }
    }
}
#endif
#endif
