import Foundation

/// The experiment can only attach to an already validated synthetic fixture.
/// Parsing these arguments never resolves a directory or selects a file.
enum PDFNativePickerExperiment {
    struct Configuration {
        let namespace: UUID
        let usesUIKit: Bool
        var source: String { usesUIKit ? "uikit" : "swiftui" }
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
        let switches = arguments.filter { $0 == "-UITestPDFUIKitPicker" }.count
        guard switches <= 1 else { return nil }
        return Configuration(namespace: fixtureNamespace, usesUIKit: switches == 1)
        #else
        return nil
        #endif
    }
}

#if os(iOS)
import SwiftUI
import UniformTypeIdentifiers
#if DEBUG
import UIKit
import Darwin
#endif

/// Both arms return the original delegate URLs to the same caller's count,
/// selection and approval checks. Neither arm reads/copies a selected file.
@MainActor struct PDFImportPresentation: ViewModifier {
    @Binding var isPresented: Bool
    let experiment: PDFNativePickerExperiment.Configuration?
    let onCompletion: (Result<[URL], Error>) -> Void
    var onObservation: (String) -> Void = { _ in }

    @ViewBuilder func body(content: Content) -> some View {
        #if DEBUG
        presentation(content)
            .background {
                if let experiment {
                    PDFPickerModeProbe(configuration: experiment, isPresented: isPresented,
                                       onObservation: onObservation)
                        .frame(width: 0, height: 0).allowsHitTesting(false).accessibilityHidden(true)
                }
            }
        #else
        swiftUIImporter(content)
        #endif
    }

    private func swiftUIImporter(_ content: Content) -> some View {
        content.fileImporter(isPresented: $isPresented, allowedContentTypes: [.pdf],
                             allowsMultipleSelection: false, onCompletion: onCompletion)
    }

    #if DEBUG
    @ViewBuilder private func presentation(_ content: Content) -> some View {
        if experiment?.usesUIKit == true {
            content.sheet(isPresented: $isPresented) {
                PDFNativePicker { outcome in
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
    #endif
}

#if DEBUG
/// Explicit open-in-place control. No directoryURL, preselection, bookmark
/// recreation, URL substitution, automatic retry or fallback to another picker.
@MainActor private struct PDFNativePicker: UIViewControllerRepresentable {
    let onCompletion: (Result<[URL], Error>?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCompletion: onCompletion) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.pdf], asCopy: false)
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

/// A passive, bounded public-API observation in this view's own window. No
/// private class names/KVC, responder hooks, delegate replacement or AX probing.
@MainActor private struct PDFPickerModeProbe: UIViewControllerRepresentable {
    let configuration: PDFNativePickerExperiment.Configuration
    let isPresented: Bool
    let onObservation: (String) -> Void

    func makeUIViewController(context: Context) -> ProbeController { ProbeController() }
    func updateUIViewController(_ controller: ProbeController, context: Context) {
        controller.update(configuration: configuration, isPresented: isPresented, onObservation: onObservation)
    }
    static func dismantleUIViewController(_ controller: ProbeController, coordinator: ()) { controller.stop() }

    @MainActor final class ProbeController: UIViewController {
        private var observation: Task<Void, Never>?
        private var presenting = false
        private var reported = false
        private var activeConfiguration: PDFNativePickerExperiment.Configuration?

        func update(configuration: PDFNativePickerExperiment.Configuration, isPresented: Bool,
                    onObservation: @escaping (String) -> Void) {
            guard isPresented else { stop(); return }
            guard !presenting else { return }
            presenting = true
            reported = false
            activeConfiguration = configuration
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
                        let value = "source=\(configuration.source) mode=\(mode) allowsMultipleSelection=\(picker.allowsMultipleSelection)"
                        self.reported = true
                        Self.record(configuration: configuration, value: value)
                        onObservation(value)
                        return
                    }
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
                guard let self, !Task.isCancelled else { return }
                self.reported = true
                Self.record(configuration: configuration, value: "source=\(configuration.source) mode=unobserved")
            }
        }

        func stop() {
            if presenting, !reported, let configuration = activeConfiguration {
                Self.record(configuration: configuration, value: "source=\(configuration.source) mode=unobserved")
            }
            presenting = false
            activeConfiguration = nil
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

        private static func record(configuration: PDFNativePickerExperiment.Configuration, value: String) {
            print("SKILL_PDF_PICKER_PRESENTATION namespace=\(configuration.namespace.uuidString) \(value) sampledAt=\(Date().timeIntervalSince1970)")
            fflush(stdout)
        }
    }
}
#endif
#endif
