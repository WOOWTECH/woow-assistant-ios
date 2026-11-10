import AssistantBrowser
import SwiftUI
import WebKit

@MainActor
struct BrowserLibraryView: View {
    @ObservedObject var workspace: BrowserWorkspace
    @Environment(\.dismiss) private var dismiss
    @State private var section = 0
    @State private var renameID: UUID?
    @State private var showRename = false
    @State private var renameTitle = ""
    @State private var confirmHistory = false
    @State private var deleteSite: WKWebsiteDataRecord?
    @State private var confirmSite = false
    @State private var showDownloads = false
    var body: some View {
        NavigationStack {
            VStack {
                Picker("瀏覽資料", selection: $section) {
                    Text("分頁").tag(0); Text("書籤").tag(1); Text("歷史").tag(2); Text("網站").tag(3)
                }.pickerStyle(.segmented).padding(.horizontal).accessibilityIdentifier("browser.library.sections")
                if let error = workspace.error { Text(error).foregroundStyle(.red).accessibilityIdentifier("browser.library.error") }
                if workspace.isClearingWebsiteData {
                    ProgressView("正在清除網站資料…")
                        .accessibilityIdentifier("browser.library.clearing")
                }
                List {
                    if section == 0 { tabs }
                    else if section == 1 { bookmarks }
                    else if section == 2 { history }
                    else { websites }
                }
            }
            .navigationTitle("瀏覽資料")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() }.accessibilityIdentifier("browser.library.close") } }
            .toolbar { ToolbarItem(placement: .navigationBarLeading) { Button("下載") { showDownloads = true }.accessibilityIdentifier("browser.downloads.open") } }
            .sheet(isPresented: $showDownloads) { BrowserDownloadsView(manager: workspace.downloads) }
            .alert("修改書籤名稱", isPresented: $showRename) {
                TextField("名稱", text: $renameTitle).accessibilityIdentifier("browser.bookmark.name")
                Button("儲存") { if let id = renameID { workspace.renameBookmark(id, title: renameTitle) }; renameID = nil }
                Button("取消", role: .cancel) { renameID = nil }
            }
            .confirmationDialog("清除瀏覽歷史？書籤與網站登入資料會保留。", isPresented: $confirmHistory, titleVisibility: .visible) {
                Button("清除歷史", role: .destructive) { workspace.clearHistory() }.accessibilityIdentifier("browser.history.confirmClear")
            }
            .confirmationDialog("清除此網站的資料？可能需要重新登入，所有分頁與下載將停止。", isPresented: $confirmSite, titleVisibility: .visible, presenting: deleteSite) { record in
                Button("清除網站資料", role: .destructive) { workspace.removeWebsiteData([record]); deleteSite = nil }
                    .accessibilityIdentifier("browser.sites.confirmClear")
            }
            .onChange(of: section) { _, selected in if selected == 3 { workspace.refreshWebsiteRecords() } }
        }
    }
    private var tabs: some View {
        Group {
            Button("新增分頁") { workspace.newTab(); dismiss() }.disabled(!workspace.available)
                .accessibilityIdentifier("browser.tabs.new")
            ForEach(workspace.library.tabs) { tab in
                HStack {
                    Button {
                        workspace.selectTab(tab.id); dismiss()
                    } label: {
                        VStack(alignment: .leading) {
                            Text(tab.title).lineLimit(2)
                            Text(tab.url?.host ?? "尚未開啟網頁").font(.caption)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.accessibilityIdentifier("browser.tabs.select.\(tab.id)")
                        .accessibilityValue(workspace.library.selectedID == tab.id ? "已選取" : "未選取")
                    Button { workspace.closeTab(tab.id) } label: { Image(systemName: "xmark.circle") }
                        .accessibilityLabel("關閉 \(tab.title)").accessibilityIdentifier("browser.tabs.close.\(tab.id)")
                }.buttonStyle(.borderless)
            }
        }
    }
    private var bookmarks: some View {
        Group {
            Button("加入目前頁面書籤") { workspace.addBookmark() }
                .disabled(!workspace.available || workspace.selected.loadedURL.flatMap(BrowserManualNavigationPolicy.libraryURL) == nil)
                .accessibilityIdentifier("browser.bookmarks.add")
            if workspace.library.bookmarks.isEmpty { Text("尚無書籤").accessibilityIdentifier("browser.bookmarks.empty") }
            ForEach(workspace.library.bookmarks) { page in
                VStack(alignment: .leading, spacing: 8) {
                    pageButton(page, prefix: "bookmark")
                    HStack {
                        Button("改名") { renameTitle = page.title; renameID = page.id; showRename = true }.accessibilityIdentifier("browser.bookmark.rename.\(page.id)")
                        Button("刪除", role: .destructive) { workspace.removeBookmark(page.id) }.accessibilityIdentifier("browser.bookmark.delete.\(page.id)")
                    }.buttonStyle(.borderless)
                }
            }
        }
    }
    private var history: some View {
        Group {
            Button("清除所有歷史", role: .destructive) { confirmHistory = true }
                .disabled(workspace.library.history.isEmpty).accessibilityIdentifier("browser.history.clear")
            if workspace.library.history.isEmpty { Text("尚無瀏覽歷史").accessibilityIdentifier("browser.history.empty") }
            ForEach(workspace.library.history) { page in
                HStack {
                    pageButton(page, prefix: "history")
                    Button("刪除", role: .destructive) { workspace.removeHistory(page.id) }
                        .accessibilityIdentifier("browser.history.delete.\(page.id)")
                }.buttonStyle(.borderless)
            }
        }
    }
    private var websites: some View {
        Group {
            Text("網站資料由 WebKit 儲存，包括 Cookie 與網站儲存空間；出現在清單不代表目前已登入。")
                .font(.caption)
            if workspace.websiteRecords.isEmpty { Text("尚無網站資料").accessibilityIdentifier("browser.sites.empty") }
            ForEach(workspace.websiteRecords, id: \.displayName) { record in
                HStack {
                    Text(record.displayName)
                    Spacer()
                    Button("清除", role: .destructive) { deleteSite = record; confirmSite = true }
                        .disabled(workspace.isClearingWebsiteData).accessibilityIdentifier("browser.sites.clear.\(record.displayName)")
                }
            }
        }
    }
    private func pageButton(_ page: BrowserSavedPage, prefix: String) -> some View {
        Button { workspace.open(page.url); dismiss() } label: {
            VStack(alignment: .leading) {
                Text(page.title).lineLimit(2)
                Text(page.url.absoluteString).font(.caption).lineLimit(2)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.accessibilityIdentifier("browser.\(prefix).open.\(page.id)")
    }
}
