import AssistantBrowser
import SwiftUI

@MainActor
struct WebsiteDataView: View {
    @ObservedObject var store: LearningStore
    @ObservedObject var browser: BrowserSession
    let modelAccess: () throws -> ModelAccess
    let onOpenBrowser: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var note = ""
    @State private var edit: WebsiteLesson?
    @State private var replay: WebRoute?
    @State private var query = ""
    @FocusState private var noteFocused: Bool

    var body: some View {
        List {
            if let error = store.error { Text(error).foregroundStyle(.red).accessibilityIdentifier("website.error") }
            Section("儲存目前網站的知識") {
                if let page = browser.current {
                    Text(page.url.host ?? "").font(.caption)
                    TextField("記下此網站的操作方式或注意事項", text: $note)
                        .focused($noteFocused).submitLabel(.done).onSubmit { noteFocused = false }
                        .accessibilityIdentifier("website.note")
                    Button("儲存這條知識") { saveNote(page) }
                        .disabled(note.isEmpty || !store.available).accessibilityIdentifier("website.save")
                    Text("會一併保留本頁的一小段原文作為來源。網站內容不會自動變成你的個人記憶。")
                        .font(.caption)
                } else { Text("先在瀏覽器開啟網頁，才能建立有來源的知識。") }
            }
            Section("網站知識") {
                TextField("搜尋網站知識", text: $query).accessibilityIdentifier("website.search")
                let lessons = (try? store.websites.search(query)) ?? []
                if lessons.isEmpty { Text("尚無網站知識").accessibilityIdentifier("website.empty") }
                ForEach(lessons) { lesson in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(lesson.text).accessibilityIdentifier("website.lesson.\(lesson.id)")
                        Text(lesson.origin.url.host ?? "").font(.caption)
                        Text("來源：\(lesson.evidence.quote)").font(.caption).foregroundStyle(.secondary)
                        Text(lesson.status == .approved ? "已核准" : "待確認")
                        HStack {
                            if lesson.status == .pending {
                                Button("核准") { store.mutateWeb { web, _ in try web.approve(id: lesson.id) } }
                                    .accessibilityIdentifier("website.approve.\(lesson.id)")
                            }
                            Button("編輯") { edit = lesson }.accessibilityIdentifier("website.edit.\(lesson.id)")
                            Button("刪除", role: .destructive) { store.mutateWeb { web, _ in try web.delete(id: lesson.id) } }
                                .accessibilityIdentifier("website.delete.\(lesson.id)")
                        }.buttonStyle(.borderless)
                    }
                }
            }
            Section("網頁路線") {
                if store.routes.routes.isEmpty { Text("尚無已確認路線").accessibilityIdentifier("website.routes.empty") }
                ForEach(store.routes.routes) { route in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(route.originalGoal).accessibilityIdentifier("website.route.\(route.id)")
                        Text("\(route.steps.count) 步 · \(route.origin.url.host ?? "")")
                        if route.disabled { Text("已停用：同一步驟連續兩次不符") }
                        HStack {
                            Button("重走路線") { replay = route }.disabled(route.disabled || browser.isRunning)
                                .accessibilityIdentifier("website.replay.\(route.id)")
                            Button("刪除", role: .destructive) { store.mutateWeb { _, routes in try routes.delete(id: route.id) } }
                                .accessibilityIdentifier("website.route.delete.\(route.id)")
                        }.buttonStyle(.borderless)
                    }
                }
            }
            Section("知識修訂") {
                ForEach(store.websites.revisions.reversed()) { revision in
                    let hash = store.websites.contentHash
                    VStack(alignment: .leading) {
                        Text(revision.lesson.text).font(.caption)
                        Button("還原這個版本") { store.mutateWeb { web, _ in
                            _ = try web.restore(revisionID: revision.id, expectedCurrentHash: hash)
                        }}.accessibilityIdentifier("website.restore.\(revision.id)")
                    }
                }
            }
        }
        .navigationTitle("網站知識與路線")
        .accessibilityIdentifier("website.manager")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() }.accessibilityIdentifier("website.close") } }
        .sheet(item: $edit) { item in
            NavigationStack { WebsiteLessonEditor(store: store, item: item) }
        }
        .alert("重走已儲存的網頁路線？", isPresented: Binding(get: { replay != nil }, set: { if !$0 { replay = nil } })) {
            Button("取消", role: .cancel) { replay = nil }
            Button("開啟並逐步核對") {
                guard let route = replay else { return }
                browser.replay(route: route, store: store, modelAccess: modelAccess)
                replay = nil; dismiss(); onOpenBrowser()
            }
        } message: {
            Text("將開啟 \(replay?.origin.url.host ?? "") 的 \(replay?.steps.count ?? 0) 個已記錄步驟。只讀取網頁；內容不符便停止，不會提交表單。")
        }
    }

    private func saveNote(_ page: WebObservation) {
        let quote = String(page.text.prefix(200)).trimmingCharacters(in: .whitespacesAndNewlines)
        let snapshot = PageSnapshot(url: page.url, title: page.title, visibleText: page.text, capturedAt: page.capturedAt)
        if store.mutateWeb({ web, _ in
            let evidence = try WebsiteLessonEvidence(snapshot: snapshot, quote: quote)
            _ = try web.addManual(text: note, evidence: evidence)
        }) { note = "" }
    }
}

@MainActor
private struct WebsiteLessonEditor: View {
    @ObservedObject var store: LearningStore
    let item: WebsiteLesson
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    init(store: LearningStore, item: WebsiteLesson) { self.store = store; self.item = item; _text = State(initialValue: item.text) }
    var body: some View {
        Form {
            TextEditor(text: $text).frame(minHeight: 180).accessibilityIdentifier("website.editor.text")
            Text("來源原文：\(item.evidence.quote)").font(.caption)
            if let error = store.error { Text(error).foregroundStyle(.red) }
        }
        .navigationTitle("編輯網站知識")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("儲存") {
                    if store.mutateWeb({ web, _ in try web.edit(id: item.id, text: text, evidence: item.evidence) }) { dismiss() }
                }.accessibilityIdentifier("website.editor.save")
            }
        }
    }
}
