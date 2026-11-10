#if PDF_ASSEMBLY_ADD_APP_CHECKS
import AppKit
import AssistantSkills
import CoreText
import Foundation
import PDFKit

/// Actual App session and native PDFKit; no native picker/exporter UI claim.
@main enum PDFAssemblyAddAppChecks {
    struct Failure: Error { let code: String }
    @MainActor static var count = 0
    @MainActor static func require(_ value: Bool, _ code: String) throws {
        count += 1
        if !value { throw Failure(code: code) }
    }
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do {
                try await check()
                print("ADD_APP_CHECKS passed=\(count) nativePicker=false")
                exit(0)
            } catch {
                print("ADD_APP_FAILED code=\((error as? Failure)?.code ?? "native_operation")")
                exit(1)
            }
        }
        app.run() // Parent process bounds this entire executable to 60 seconds.
    }
    @MainActor static func pending(_ session: SkillPDFAssemblySession) throws -> Task<Void, Never> {
        // Read only the App's own Task handle; wait for actual completion even
        // if clear() removes it. No private OS API or synthetic completion.
        guard let value = Mirror(reflecting: session).children.first(where: { $0.label == "task" })?.value,
              let optional = value as? Optional<Task<Void, Never>>, let task = optional else {
            throw Failure(code: "missing_task")
        }
        return task
    }
    @MainActor static func drain(_ session: SkillPDFAssemblySession) async throws {
        await (try pending(session)).value
        try require(!session.running, "actual_task_completed")
    }
    @MainActor static func request(_ session: SkillPDFAssemblySession, adding: Bool) throws -> SkillPDFAssemblySession.PickerRequest {
        guard let request = session.beginPicker(adding: adding) else { throw Failure(code: "missing_request") }
        return request
    }
    static func pdf(_ words: [String]) throws -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 400, height: 300)
        guard let consumer = CGDataConsumer(data: data), let context = CGContext(consumer: consumer, mediaBox: &box, nil) else {
            throw Failure(code: "pdf_context")
        }
        for word in words {
            context.beginPDFPage(nil); context.textPosition = CGPoint(x: 30, y: 100)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: word, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 14, nil)
            ])), context)
            context.endPDFPage()
        }
        context.closePDF(); return data as Data
    }
    static func texts(_ data: Data) throws -> [String] {
        guard let pdf = PDFDocument(data: data) else { throw Failure(code: "pdf_readback") }
        return (0..<pdf.pageCount).map { (pdf.page(at: $0)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
    }
    @MainActor static func check() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("assembly-add-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = ["A", "B", "C", "D"].map { root.appendingPathComponent($0 + ".pdf") }
        let bytes = try ["A", "B", "C", "D"].map { try pdf([$0 + "1", $0 + "2"]) }
        for (file, data) in zip(files, bytes) { try data.write(to: file, options: .withoutOverwriting) }
        let session = SkillPDFAssemblySession()
        try require(!session.canAdd && session.beginPicker(adding: true) == nil, "cannot_add_before_initial")
        for urls in [[], [files[0], files[1]]] {
            let invalid = try request(session, adding: false)
            try require(!session.finishPicker(invalid, urls: urls) && session.sources.isEmpty, "initial_requires_exactly_one")
            try require(!session.finishPicker(invalid, urls: [files[0]]), "invalid_callback_consumed")
        }
        let cancelledInitial = try request(session, adding: false)
        session.cancelPicker(cancelledInitial)
        try require(!session.finishPicker(cancelledInitial, urls: [files[0]]), "cancelled_initial_rejects_late")
        let initial = try request(session, adding: false)
        try require(session.beginPicker(adding: false) == nil, "one_outstanding_picker")
        try require(session.finishPicker(initial, urls: [files[0]]), "first_user_pick")
        let a = session.sources[0].id
        try require(!session.finishPicker(initial, urls: [files[1]]) && session.sources.map(\.id) == [a], "duplicate_callback_no_replacement")
        try require(session.receipts.isEmpty && session.plan == nil && session.result == nil, "selection_not_read_consent")
        session.prepare(); session.assemble()
        try require(!session.running && !session.canPrepare, "unapproved_source_cannot_prepare")
        session.read(a)
        try require(!session.canAdd && session.beginPicker(adding: true) == nil, "cannot_add_during_actual_read")
        try await drain(session)
        try require(session.receipts.map(\.id) == [a], "first_read_has_own_receipt")
        session.prepare(); try await drain(session)
        let plan = session.plan!
        let beforeAssembly = try request(session, adding: true)
        session.assemble()
        try require(!session.running && session.result == nil && session.plan?.id == plan.id, "pending_picker_blocks_assembly_preserves_review")
        session.cancelPicker(beforeAssembly)
        session.assemble(); try await drain(session)
        let firstResult = session.result!, firstOrder = session.orderText
        try require(try texts(firstResult.data) == ["A1", "A2"], "first_actual_output")
        let cancelled = try request(session, adding: true)
        session.cancelPicker(cancelled)
        try require(session.result?.data == firstResult.data && session.orderText == firstOrder && session.plan?.id == plan.id,
                    "cancel_preserves_result_review_and_order")
        let adding = try request(session, adding: true)
        session.cancelPicker(cancelled)
        session.pickerFailed(cancelled)
        try require(!session.finishPicker(cancelled, urls: [files[1]]) && session.beginPicker(adding: true) == nil,
                    "stale_callbacks_cannot_consume_new_request")
        session.cancelPicker(adding)
        let failed = try request(session, adding: true)
        session.pickerFailed(failed)
        try require(session.result?.data == firstResult.data && session.receipts.map(\.id) == [a], "provider_failure_preserves_result_and_receipt")
        for urls in [[files[0]], [], [files[1], files[2]], [root.appendingPathComponent("invalid.txt")]] {
            let invalid = try request(session, adding: true)
            try require(!session.finishPicker(invalid, urls: urls), "invalid_add_rejected")
            try require(session.result?.data == firstResult.data && session.sources.map(\.id) == [a]
                        && session.plan?.id == plan.id && session.receipts.map(\.id) == [a], "invalid_add_is_nondestructive")
        }
        let second = try request(session, adding: true)
        try require(session.finishPicker(second, urls: [files[1]]), "second_deliberate_pick")
        let ids = session.sources.map(\.id)
        try require(ids.count == 2 && ids[0] == a && ids[1] != a, "add_preserves_existing_source_identity")
        try require(session.receipts.isEmpty && session.plan == nil && session.result == nil && session.orderText.isEmpty,
                    "add_revokes_all_prior_approval_snapshots")
        session.prepare(); session.assemble()
        try require(!session.running && !session.canPrepare, "old_grants_cannot_assemble_added_set")
        session.read(ids[0]); try await drain(session)
        try require(session.receipts.map(\.id) == [a] && !session.canPrepare, "fresh_A_consent_does_not_read_B")
        session.read(ids[1]); try await drain(session)
        try require(session.receipts.map(\.id) == ids && session.orderText == "1:1-2,2:1-2", "both_new_grants_read_real_sources")
        session.orderText = "1:2,2:1,1:1"
        session.prepare(); try await drain(session)
        try require(session.plan?.order.map(\.sourceID) == [ids[0], ids[1], ids[0]] && session.plan?.order.map(\.number) == [2, 1, 1]
                    && session.result == nil, "exact_cross_file_review_without_assembly")
        session.assemble(); try await drain(session)
        let result = session.result!
        try require(try texts(result.data) == ["A2", "B1", "A1"], "actual_A2_B1_A1_output")
        let document = try SkillPDFAssemblyDocument(data: result.data)
        try require(document.snapshot().regularFileContents == result.data, "real_immutable_export_snapshot")
        let third = try request(session, adding: true)
        try require(session.finishPicker(third, urls: [files[2]]) && session.sources.count == 3, "third_source_allowed")
        try require(Array(session.sources.prefix(2)).map(\.id) == ids && session.receipts.isEmpty && session.result == nil, "third_preserves_identity_revokes_snapshots")
        try require(!session.canAdd && session.beginPicker(adding: true) == nil, "fourth_source_disallowed")
        try require(document.data == result.data, "export_snapshot_survives_added_source")
        session.clear()
        let stale = try request(session, adding: false)
        session.clear()
        let fresh = try request(session, adding: false)
        try require(!session.finishPicker(stale, urls: [files[0]]), "clear_fences_old_picker_generation")
        try require(session.finishPicker(fresh, urls: [files[1]]), "new_generation_usable")
        session.read(session.sources[0].id)
        let reading = try pending(session)
        session.clear(); await reading.value
        try require(session.sources.isEmpty && session.receipts.isEmpty && session.result == nil && session.status == nil,
                    "late_actual_read_cannot_republish_after_clear")
        for (file, original) in zip(files, bytes) {
            try require(try Data(contentsOf: file) == original, "original_bytes_unchanged")
        }
    }
}
#endif
