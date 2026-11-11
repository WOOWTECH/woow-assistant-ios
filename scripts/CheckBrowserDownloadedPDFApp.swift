import Foundation
import Combine
import CryptoKit
import Network
import WebKit
import AssistantSkills
@testable import AssistantBrowser
#if os(iOS)
import UIKit
@testable import WoowAssistant
#else
import AppKit
#endif

/// The same bodies run on macOS and as hosted native XCTest. A real WKDownload
/// supplies bytes in the first group; storage mutations in other groups are
/// deliberately synthetic negative controls. No model or external network.
@MainActor enum BrowserDownloadedPDFAppChecks {
    struct Failure: Error { let check: String }
    final class Counter {
        var count = 0
        func check(_ condition: @autoclosure () throws -> Bool, _ name: String) throws {
            guard try condition() else { throw Failure(check: name) }
            count += 1
        }
    }
    static func wait(_ name: String, _ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        while !condition(), ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        guard condition() else { throw Failure(check: name) }
    }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    static func realDownloadAndApprovals() async throws -> Int {
        let c = Counter(), bytes = pdf()
        let server = try PDFDownloadServer(payload: bytes); try await server.start(); defer { server.stop() }
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let manager = BrowserDownloadManager(directory: root, limits: .init(), allowsURL: server.allows)
        let host = try Host(); defer { host.close() }
        let first = try await download(host.webView, manager: manager, url: server.url)
        let second = try await download(host.webView, manager: manager, url: server.url)
        try c.check(server.requests == 2, "two actual HTTP downloads")
        try c.check(manager.items.count == 2 && manager.items.allSatisfy { $0.status == .completed }, "native completed records")
        let url = try manager.fileURL(id: first)
        try c.check(try Data(contentsOf: url) == bytes, "WKDownload bytes equal server PDF")
        try c.check(manager.items[0].fileName == manager.items[1].fileName && first != second, "same name has independent UUIDs")
        try c.check(try manager.fileURL(id: second) != url, "same name never aliases path")
        let presenter = ReadPresenter(url: url, held: false)
        NSFileCoordinator.addFilePresenter(presenter); defer { NSFileCoordinator.removeFilePresenter(presenter) }
        let selection = try BrowserDownloadedPDFSelection(manager: manager, userSelectedID: first)
        let model = SkillExecutionViewModel(downloadedPDF: selection)
        defer { model.clear() }
        try c.check(model.plan == nil && model.result == nil && !model.running, "selection does not create execution")
        try c.check(presenter.calls == 0, "selection does not read")
        model.prepareDownload(pages: "2,1,2", password: "", metadataOnly: false, worker: nil)
        guard let plan = model.plan else { throw Failure(check: "download plan prepared") }
        try c.check(plan.steps.count == 2 && plan.steps.allSatisfy(\.requiresAuthorization), "original two approvals retained")
        try c.check(plan.steps[0].availability.detail.contains("已完成下載") && !plan.steps[0].availability.detail.contains("系統檔案選擇器"), "download is not a picker grant")
        try c.check(plan.steps[1].capability == .nativePDFText, "native extraction remains default")
        try c.check(presenter.calls == 0 && model.result == nil, "preparing reads nothing")
        model.execute(stepID: plan.steps[1].id)
        if let work = model.executingTask { await work.value }
        try c.check(model.completedStepIDs.isEmpty && model.result == nil && presenter.calls == 0, "second approval cannot bypass first")
        model.execute(stepID: plan.steps[0].id)
        guard let firstWork = model.executingTask else { throw Failure(check: "first actual App task") }
        model.execute(stepID: plan.steps[0].id) // A repeated tap while busy is ignored.
        await firstWork.value
        try c.check(presenter.calls == 1, "only one coordinated read")
        try c.check(model.completedStepIDs == [plan.steps[0].id] && model.nextStepID == plan.steps[1].id, "read alone completes only first step")
        try c.check(model.result == nil && !model.running, "download/read does not imply extraction")
        model.execute(stepID: plan.steps[1].id)
        if let work = model.executingTask { await work.value }
        guard let result = model.result else { throw Failure(check: "actual PDFKit result") }
        try c.check(result.inputSHA256 == digest(bytes), "extraction binds exact downloaded bytes")
        try c.check(result.engine == "Apple PDFKit" && result.originalScriptSHA256 == nil, "native engine provenance")
        try c.check(result.pageCount == 2 && result.pages.map(\.number) == [2, 1, 2], "page order and duplicate selection")
        try c.check(result.pages.map(\.text) == ["Downloaded beta", "Downloaded alpha", "Downloaded beta"], "actual PDF text")
        try c.check(model.nextStepID == nil && model.completedStepIDs.count == 2, "terminal two-step state")
        try c.check(presenter.calls == 1 && server.requests == 2, "extraction neither rereads nor redownloads")
        #if DEBUG
        try c.check(model.uiTestFixture == nil && model.uiTestAudit == nil, "download does not masquerade as picker fixture")
        #endif
        let restored = BrowserDownloadManager(directory: root)
        try c.check(restored.items.count == 2, "completed downloads persist")
        let reopened = SkillExecutionViewModel(downloadedPDF: try BrowserDownloadedPDFSelection(manager: restored, userSelectedID: first))
        try c.check(reopened.plan == nil && reopened.result == nil, "relaunch restores no read grants or execution")
        model.clear()
        model.execute(stepID: plan.steps[1].id)
        try c.check(model.plan == nil && model.result == nil && presenter.calls == 1, "cancelled plan cannot resume")
        let reports = SkillExecutionDependencies.reports(catalog: try .bundled())
        let reads = reports.first { $0.skillID == "documents" }?.dependencies.first { $0.original == "read_file / search_files" }
        try c.check(reads?.status == .implementedInRuntime, "PDF query tools reported implemented")
        try c.check(reads?.mapping.contains("本次已擷取") == true && reads?.mapping.contains("不開放") == true, "dependency label states bounded scope")
        return c.count
    }

    static func invalidSourcesAndLimits() async throws -> Int {
        let c = Counter(), root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try StoredFiles(root: root)
        let normal = try fixture.add(pdf(), name: "normal.pdf")
        let text = try fixture.add(Data("not pdf".utf8), name: "text.txt")
        let fake = try fixture.add(Data("not pdf".utf8), name: "fake.pdf")
        let large = try fixture.add(Data(repeating: 32, count: SkillExecutionLimits.fileBytes + 1), name: "large.pdf")
        let manager = BrowserDownloadManager(directory: root)
        for id in [UUID(), text, large] {
            do { _ = try BrowserDownloadedPDFSelection(manager: manager, userSelectedID: id); throw Failure(check: "invalid input accepted") }
            catch is SkillExecutionError { c.count += 1 }
        }
        let model = SkillExecutionViewModel(downloadedPDF: try BrowserDownloadedPDFSelection(manager: manager, userSelectedID: fake))
        model.prepareDownload(pages: "", password: "", metadataOnly: false, worker: nil)
        model.execute(stepID: model.plan!.steps[0].id)
        if let work = model.executingTask { await work.value }
        try c.check(model.result == nil && model.completedStepIDs.isEmpty && model.status == SkillExecutionError.invalidPDF.errorDescription, "extension alone is not valid PDF")
        model.clear()
        let selection = try BrowserDownloadedPDFSelection(manager: manager, userSelectedID: normal)
        let selected = SkillExecutionViewModel(downloadedPDF: selection)
        selected.prepareDownload(pages: String(repeating: "1,", count: 200) + "1", password: "", metadataOnly: false, worker: nil)
        try c.check(selected.plan == nil && selected.status == SkillExecutionError.tooManyPages.errorDescription, "201 selected pages rejected")
        selected.prepareDownload(pages: "1-2", password: "", metadataOnly: false, worker: nil)
        try c.check(selected.plan != nil, "valid explicit retry allowed")
        let path = try manager.fileURL(id: normal)
        let bytes = try Data(contentsOf: path)
        try bytes.write(to: path, options: .atomic) // Equal bytes/size; new file identity.
        selected.execute(stepID: selected.plan!.steps[0].id)
        try c.check(!selection.isValid && selected.plan == nil && !selected.downloadAvailable, "same-size replacement invalidates prior selection")
        try c.check(selected.executingTask == nil && selected.result == nil, "changed identity dispatches no read")
        let symlinkID = try fixture.add(pdf(), name: "symlink.pdf")
        let linkedManager = BrowserDownloadManager(directory: root)
        let link = try linkedManager.fileURL(id: symlinkID)
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: path)
        do { _ = try BrowserDownloadedPDFSelection(manager: linkedManager, userSelectedID: symlinkID); throw Failure(check: "symlink accepted") }
        catch is BrowserDownloadError { c.count += 1 }
        return c.count
    }

    static func deletionAndHeldRead() async throws -> Int {
        let c = Counter(), root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try StoredFiles(root: root), first = try fixture.add(pdf(), name: "first.pdf")
        let second = try fixture.add(pdf(), name: "second.pdf")
        let manager = BrowserDownloadManager(directory: root)
        let selected = try BrowserDownloadedPDFSelection(manager: manager, userSelectedID: first)
        let model = SkillExecutionViewModel(downloadedPDF: selected)
        model.prepareDownload(pages: "", password: "", metadataOnly: false, worker: nil)
        let oldPlan = model.plan!
        try manager.delete(id: first, confirmed: true)
        try c.check(!selected.isValid && model.plan == nil && !model.running, "manager willSet removal immediately cancels")
        model.execute(stepID: oldPlan.steps[0].id)
        try c.check(model.executingTask == nil && model.result == nil, "deleted selection cannot read")
        let next = try BrowserDownloadedPDFSelection(manager: manager, userSelectedID: second)
        let reading = SkillExecutionViewModel(downloadedPDF: next)
        reading.prepareDownload(pages: "", password: "", metadataOnly: false, worker: nil)
        let held = ReadPresenter(url: try manager.fileURL(id: second), held: true)
        NSFileCoordinator.addFilePresenter(held)
        defer { held.release(); NSFileCoordinator.removeFilePresenter(held); reading.clear() }
        reading.execute(stepID: reading.plan!.steps[0].id)
        guard let work = reading.executingTask else { throw Failure(check: "held read task exists") }
        try await wait("real presenter reached", { held.calls == 1 })
        reading.clear()
        try c.check(reading.plan == nil && !reading.running && reading.result == nil, "clear publishes cancellation before read returns")
        reading.prepareDownload(pages: "2", password: "", metadataOnly: true, worker: nil)
        let replacement = reading.plan!.id
        held.release(); await work.value
        try c.check(reading.plan?.id == replacement && reading.completedStepIDs.isEmpty && reading.result == nil, "late actual read cannot populate replacement plan")
        try c.check(!reading.running && reading.nextStepID == reading.plan?.steps[0].id, "late caller cannot advance replacement")
        reading.execute(stepID: reading.plan!.steps[0].id)
        if let active = reading.executingTask { await active.value }
        try c.check(reading.completedStepIDs.count == 1 && reading.result == nil, "new plan needs new explicit approval")
        try manager.delete(id: second, confirmed: true)
        try c.check(reading.plan == nil && !next.isValid && reading.result == nil, "deletion between approvals discards read snapshot")
        return c.count
    }

    static func lateWorkerAndDisclosure() async throws -> Int {
        let c = Counter(), root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try StoredFiles(root: root), id = try fixture.add(pdf(), name: "worker.pdf")
        let manager = BrowserDownloadManager(directory: root)
        let selection = try BrowserDownloadedPDFSelection(manager: manager, userSelectedID: id)
        let model = SkillExecutionViewModel(downloadedPDF: selection), worker = HeldWorker()
        defer { model.clear() }
        model.prepareDownload(pages: "1", password: "", metadataOnly: false, worker: worker)
        let plan = model.plan!
        try c.check(plan.steps[1].disclosure.contains(worker.destination), "explicit selected worker destination disclosed")
        let before = await worker.calls
        try c.check(before == 0, "preparing never uploads")
        model.execute(stepID: plan.steps[0].id)
        if let task = model.executingTask { await task.value }
        let afterRead = await worker.calls
        try c.check(afterRead == 0 && model.result == nil, "read grant never uploads")
        model.execute(stepID: plan.steps[1].id)
        guard let task = model.executingTask else { throw Failure(check: "worker actual App task") }
        await worker.started()
        let dispatches = await worker.calls
        try c.check(dispatches == 1 && model.running, "second explicit approval dispatches exactly once")
        try manager.delete(id: id, confirmed: true)
        try c.check(model.plan == nil && !model.running && model.result == nil, "deletion revokes while worker is held")
        await worker.release(); await task.value
        let replies = await worker.responses, finalCalls = await worker.calls
        try c.check(replies == 1 && finalCalls == 1, "join actual worker return without new calls")
        try c.check(model.result == nil && model.nextStepID == nil && model.completedStepIDs.isEmpty, "late worker result never published")
        return c.count
    }

    private static func temporary() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("download-pdf-" + UUID().uuidString) }
    private final class StoredFiles {
        let store: BrowserDownloadStore
        init(root: URL) throws { store = try BrowserDownloadStore(directory: root, limits: .init()) }
        func add(_ data: Data, name: String) throws -> UUID {
            var item = BrowserDownloadItem()
            let url = try store.destination(id: item.id, suggestedFilename: name)
            try data.write(to: url); item.fileName = url.lastPathComponent
            _ = try store.finish(item); return item.id
        }
    }
    private static func download(_ view: WKWebView, manager: BrowserDownloadManager, url: URL) async throws -> UUID {
        var id: UUID?, delivered = false, expired = false
        view.startDownload(using: URLRequest(url: url)) { download in
            guard !expired else { download.cancel(nil); return }
            id = manager.accept(download, sourceURL: url, allowsDownload: true); delivered = true
        }
        do { try await wait("native download callback", { delivered }) }
        catch { expired = true; throw error }
        guard let id else { throw Failure(check: "native download accepted") }
        try await wait("native download completion", { manager.items.first { $0.id == id }?.status == .completed })
        return id
    }
    @MainActor private final class Host {
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        #if os(iOS)
        let window: UIWindow
        let prior: UIWindow?
        #else
        let window: NSWindow
        #endif
        init() throws {
            #if os(iOS)
            guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { throw Failure(check: "host scene") }
            prior = scene.windows.first(where: \.isKeyWindow); window = UIWindow(windowScene: scene)
            let controller = UIViewController(); controller.view = webView; window.rootViewController = controller; window.makeKeyAndVisible()
            #else
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = webView
            #endif
        }
        func close() {
            webView.stopLoading()
            #if os(iOS)
            window.isHidden = true; prior?.makeKey()
            #else
            window.orderOut(nil)
            #endif
        }
    }
    private final class ReadPresenter: NSObject, NSFilePresenter, @unchecked Sendable {
        let presentedItemURL: URL?
        let presentedItemOperationQueue: OperationQueue = { let q = OperationQueue(); q.maxConcurrentOperationCount = 1; return q }()
        private let lock = NSLock()
        private var held: Bool
        private var callback: ((Error?) -> Void)?
        private var count = 0
        var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
        init(url: URL, held: Bool) { presentedItemURL = url; self.held = held }
        func savePresentedItemChanges(completionHandler: @escaping (Error?) -> Void) {
            lock.lock(); count += 1
            if held { callback = completionHandler; lock.unlock() }
            else { lock.unlock(); completionHandler(nil) }
        }
        func release() {
            lock.lock(); held = false; let pending = callback; callback = nil; lock.unlock(); pending?(nil)
        }
    }
    private actor HeldWorker: SkillExecutionPDFWorker {
        nonisolated let destination = "isolated held test adapter; no network"
        private(set) var calls = 0, responses = 0
        private var start: CheckedContinuation<Void, Never>?, pending: CheckedContinuation<Void, Never>?
        func started() async { if calls == 0 { await withCheckedContinuation { start = $0 } } }
        func release() { pending?.resume(); pending = nil }
        func extract(data: Data, options: SkillExecutionPDFOptions) async throws -> SkillExecutionPDFResult {
            calls += 1; start?.resume(); start = nil
            await withCheckedContinuation { pending = $0 }
            responses += 1
            return SkillExecutionPDFResult(pageCount: 2, pages: [.init(number: 1, text: "Downloaded alpha")], metadata: [:], emptyPages: [],
                inputSHA256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), engine: "Held fixture",
                originalScriptSHA256: SkillExecutionHTTPWorker.scriptSHA256)
        }
    }
    private static func pdf() -> Data {
        let streams = ["BT /F1 18 Tf 40 700 Td (Downloaded alpha) Tj ET", "BT /F1 18 Tf 40 700 Td (Downloaded beta) Tj ET"]
        var objects = ["<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R 5 0 R] /Count 2 >>"]
        for (index, stream) in streams.enumerated() {
            objects.append("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 7 0 R >> >> /Contents \(4 + index * 2) 0 R >>")
            objects.append("<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream")
        }
        objects.append("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
        var text = "%PDF-1.4\n", offsets = [0]
        for (index, object) in objects.enumerated() { offsets.append(text.utf8.count); text += "\(index + 1) 0 obj\n\(object)\nendobj\n" }
        let start = text.utf8.count
        text += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets.dropFirst() { text += String(format: "%010d 00000 n \n", offset) }
        text += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(start)\n%%EOF\n"
        return Data(text.utf8)
    }
}

private final class PDFDownloadServer: @unchecked Sendable {
    let payload: Data
    private let listener: NWListener
    private let queue = DispatchQueue(label: "download-pdf-fixture")
    private var connections: [NWConnection] = []
    private let lock = NSLock()
    private var count = 0
    var requests: Int { lock.lock(); defer { lock.unlock() }; return count }
    init(payload: Data) throws {
        self.payload = payload
        let parameters = NWParameters.tcp; parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
    }
    var url: URL { URL(string: "http://127.0.0.1:\(listener.port!.rawValue)/fixture.pdf")! }
    func allows(_ url: URL) -> Bool { url == self.url }
    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var completed = false
            listener.stateUpdateHandler = { state in
                guard !completed else { return }
                switch state {
                case .ready: completed = true; continuation.resume()
                case .failed(let error): completed = true; continuation.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }; self.connections.append(connection)
                connection.start(queue: self.queue); self.receive(connection, bytes: Data())
            }
            listener.start(queue: queue)
        }
    }
    func stop() { listener.cancel(); queue.sync { connections.forEach { $0.cancel() }; connections.removeAll() } }
    private func receive(_ connection: NWConnection, bytes: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, done, error in
            guard let self, error == nil else { connection.cancel(); return }
            var all = bytes; all.append(data ?? Data())
            guard all.count <= 8192 else { connection.cancel(); return }
            if String(decoding: all, as: UTF8.self).contains("\r\n\r\n") {
                self.lock.lock(); self.count += 1; self.lock.unlock()
                let head = "HTTP/1.1 200 OK\r\nContent-Type: application/pdf\r\nContent-Disposition: attachment; filename=\"fixture.pdf\"\r\nContent-Length: \(self.payload.count)\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(head.utf8) + self.payload, completion: .contentProcessed { _ in connection.cancel() })
            } else if !done { self.receive(connection, bytes: all) }
            else { connection.cancel() }
        }
    }
}

#if BROWSER_DOWNLOADED_PDF_APP_STANDALONE && os(macOS)
@main enum BrowserDownloadedPDFMain {
    static func main() {
        let application = NSApplication.shared; application.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do {
                let groups = ["realDownloadAndApprovals": try await BrowserDownloadedPDFAppChecks.realDownloadAndApprovals(),
                              "invalidSourcesAndLimits": try await BrowserDownloadedPDFAppChecks.invalidSourcesAndLimits(),
                              "deletionAndHeldRead": try await BrowserDownloadedPDFAppChecks.deletionAndHeldRead(),
                              "lateWorkerAndDisclosure": try await BrowserDownloadedPDFAppChecks.lateWorkerAndDisclosure()]
                let result: [String: Any] = ["groups": groups, "passed": groups.values.reduce(0,+), "failed": 0,
                    "actual_wkdownload": true, "actual_pdfkit": true, "actual_app_execution_caller": true,
                    "external_network_or_model_requests": 0, "native_ui": false]
                print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self)); exit(0)
            } catch {
                print("FAIL " + ((error as? BrowserDownloadedPDFAppChecks.Failure)?.check ?? "fixture execution")); exit(1)
            }
        }
        application.run()
    }
}
#endif
