import AssistantBrowser
import SwiftUI
import WebKit

@MainActor
struct BrowserLibraryView: View {
    @Environment(\.appLocalizer) private var localizer
    @ObservedObject var workspace: BrowserWorkspace
    var pdfDestination: ((BrowserDownloadedPDFSelection) -> AnyView)? = nil
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
                Picker(localizer.text(.browserLibrary), selection: $section) {
                    Text(localizer.text(.browserTabs)).tag(0); Text(localizer.text(.browserBookmarks)).tag(1); Text(localizer.text(.browserHistory)).tag(2); Text(localizer.text(.browserSites)).tag(3)
                }.pickerStyle(.segmented).padding(.horizontal).accessibilityIdentifier("browser.library.sections")
                if let error = workspace.errorText { Text(localizer.text(error)).foregroundStyle(.red).accessibilityIdentifier("browser.library.error") }
                if workspace.isClearingWebsiteData {
                    ProgressView(localizer.text(.browserClearing))
                        .accessibilityIdentifier("browser.library.clearing")
                }
                List {
                    if section == 0 { tabs }
                    else if section == 1 { bookmarks }
                    else if section == 2 { history }
                    else { websites }
                }
            }
            .navigationTitle(localizer.text(.browserLibrary))
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() }.accessibilityIdentifier("browser.library.close") } }
            .toolbar { ToolbarItem(placement: .navigationBarLeading) { Button(localizer.text(.browserDownloads)) { showDownloads = true }.accessibilityIdentifier("browser.downloads.open") } }
            .sheet(isPresented: $showDownloads) { BrowserDownloadsView(manager: workspace.downloads, pdfDestination: pdfDestination) }
            .alert(localizer.text(.browserRenameBookmark), isPresented: $showRename) {
                TextField(localizer.text(.commonName), text: $renameTitle).accessibilityIdentifier("browser.bookmark.name")
                Button(localizer.text(.commonSave)) { if let id = renameID { workspace.renameBookmark(id, title: renameTitle) }; renameID = nil }
                Button(localizer.text(.commonCancel), role: .cancel) { renameID = nil }
            }
            .confirmationDialog(localizer.text(.browserClearHistoryQuestion), isPresented: $confirmHistory, titleVisibility: .visible) {
                Button(localizer.text(.browserClearHistory), role: .destructive) { workspace.clearHistory() }.accessibilityIdentifier("browser.history.confirmClear")
            }
            .confirmationDialog(localizer.text(.browserClearSiteQuestion), isPresented: $confirmSite, titleVisibility: .visible, presenting: deleteSite) { record in
                Button(localizer.text(.browserClearSite), role: .destructive) { workspace.removeWebsiteData([record]); deleteSite = nil }
                    .accessibilityIdentifier("browser.sites.confirmClear")
            }
            .onChange(of: section) { _, selected in if selected == 3 { workspace.refreshWebsiteRecords() } }
        }
    }
    private var tabs: some View {
        Group {
            Button(localizer.text(.browserNewTab)) { workspace.newTab(); dismiss() }.disabled(!workspace.available)
                .accessibilityIdentifier("browser.tabs.new")
            ForEach(workspace.library.tabs) { tab in
                HStack {
                    Button {
                        workspace.selectTab(tab.id); dismiss()
                    } label: {
                        VStack(alignment: .leading) {
                            Text(tab.title).lineLimit(2)
                            Text(tab.url?.host ?? localizer.text(.browserNoPage)).font(.caption)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.accessibilityIdentifier("browser.tabs.select.\(tab.id)")
                        .accessibilityValue(workspace.library.selectedID == tab.id ? localizer.text(.commonSelected) : localizer.text(.commonUnselected))
                    Button { workspace.closeTab(tab.id) } label: { Image(systemName: "xmark.circle") }
                        .accessibilityLabel(localizer.text(.commonCloseName(name: tab.title))).accessibilityIdentifier("browser.tabs.close.\(tab.id)")
                }.buttonStyle(.borderless)
            }
        }
    }
    private var bookmarks: some View {
        Group {
            Button(localizer.text(.browserBookmarkCurrent)) { workspace.addBookmark() }
                .disabled(!workspace.available || workspace.selected.loadedURL.flatMap(BrowserManualNavigationPolicy.libraryURL) == nil)
                .accessibilityIdentifier("browser.bookmarks.add")
            if workspace.library.bookmarks.isEmpty { Text(localizer.text(.browserNoBookmarks)).accessibilityIdentifier("browser.bookmarks.empty") }
            ForEach(workspace.library.bookmarks) { page in
                VStack(alignment: .leading, spacing: 8) {
                    pageButton(page, prefix: "bookmark")
                    HStack {
                        Button(localizer.text(.browserRename)) { renameTitle = page.title; renameID = page.id; showRename = true }.accessibilityIdentifier("browser.bookmark.rename.\(page.id)")
                        Button(localizer.text(.commonDelete), role: .destructive) { workspace.removeBookmark(page.id) }.accessibilityIdentifier("browser.bookmark.delete.\(page.id)")
                    }.buttonStyle(.borderless)
                }
            }
        }
    }
    private var history: some View {
        Group {
            Button(localizer.text(.browserClearAllHistory), role: .destructive) { confirmHistory = true }
                .disabled(workspace.library.history.isEmpty).accessibilityIdentifier("browser.history.clear")
            if workspace.library.history.isEmpty { Text(localizer.text(.browserNoHistory)).accessibilityIdentifier("browser.history.empty") }
            ForEach(workspace.library.history) { page in
                HStack {
                    pageButton(page, prefix: "history")
                    Button(localizer.text(.commonDelete), role: .destructive) { workspace.removeHistory(page.id) }
                        .accessibilityIdentifier("browser.history.delete.\(page.id)")
                }.buttonStyle(.borderless)
            }
        }
    }
    private var websites: some View {
        Group {
            Text(localizer.text(.browserSitesHelp))
                .font(.caption)
            if workspace.websiteRecords.isEmpty { Text(localizer.text(.browserNoSites)).accessibilityIdentifier("browser.sites.empty") }
            ForEach(workspace.websiteRecords, id: \.displayName) { record in
                HStack {
                    Text(record.displayName)
                    Spacer()
                    Button(localizer.text(.commonClear), role: .destructive) { deleteSite = record; confirmSite = true }
                        .disabled(workspace.isClearingWebsiteData).accessibilityIdentifier("browser.sites.clear.\(record.displayName)")
                }
            }
        }
    }
    private func pageButton(_ page: BrowserSavedPage, prefix: String) -> some View {
        Button { workspace.open(page.url); dismiss() } label: {
            VStack(alignment: .leading) {
                if prefix == "history", let match = workspace.library.searchSettings.match(page.url) {
                    Text(localizer.text(.browserHistorySearch(query: match.query))).lineLimit(2)
                    Text(match.engineName).font(.caption)
                } else { Text(page.title).lineLimit(2) }
                Text(page.url.absoluteString).font(.caption).lineLimit(2)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.accessibilityIdentifier("browser.\(prefix).open.\(page.id)")
    }
}
