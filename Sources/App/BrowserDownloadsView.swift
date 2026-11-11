import AssistantBrowser
import SwiftUI
import UIKit

/// Standalone sheet content. Parent owns/passes the workspace's shared manager.
@MainActor
struct BrowserDownloadsView: View {
    @ObservedObject var manager: BrowserDownloadManager
    var pdfDestination: ((BrowserDownloadedPDFSelection) -> AnyView)? = nil
    @State private var selectedPDF: BrowserDownloadedPDFSelection?
    @Environment(\.dismiss) private var dismiss
    @State private var deleting: BrowserDownloadItem?
    @State private var sharing: SharedFile?
    @State private var actionError: String?

    private struct SharedFile: Identifiable {
        let id: UUID
        let url: URL
    }

    var body: some View {
        NavigationStack {
            List {
                if let error = manager.errorMessage {
                    Section {
                        Text(error).foregroundStyle(.red)
                        Button("關閉提示") { manager.clearError() }
                    }
                }
                if manager.items.isEmpty {
                    ContentUnavailableView("尚無下載檔案", systemImage: "arrow.down.circle",
                                           description: Text("在瀏覽器手動下載後，可在這裡查看進度、分享或刪除檔案。"))
                }
                ForEach(manager.items) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(item.fileName).font(.headline).lineLimit(2)
                        HStack {
                            Text(item.status.title)
                            Spacer()
                            Text(sizeDescription(item)).monospacedDigit()
                        }.font(.caption).foregroundStyle(.secondary)
                        if item.status == .downloading || item.status == .waiting {
                            if let fraction = item.fractionCompleted { ProgressView(value: fraction) }
                            else { ProgressView().accessibilityLabel("檔案大小未知，下載中") }
                        }
                        if let failure = item.failureMessage { Text(failure).font(.caption).foregroundStyle(.red) }
                        HStack {
                            if item.status.isActive {
                                Button("取消下載", role: .destructive) { manager.cancel(id: item.id) }
                                    .disabled(item.status == .cancelling)
                            } else {
                                if item.status == .completed {
                                    if pdfDestination != nil, URL(fileURLWithPath: item.fileName).pathExtension.lowercased() == "pdf" {
                                        Button("處理 PDF") { openPDF(item) }
                                            .accessibilityIdentifier("download.pdf.\(item.id)")
                                            .accessibilityHint("開啟待審計畫，尚未讀取檔案")
                                    }
                                    Button { share(item) } label: {
                                        Label("開啟或分享", systemImage: "square.and.arrow.up")
                                    }.accessibilityIdentifier("download.share.\(item.id)")
                                }
                                Spacer()
                                Button("刪除", role: .destructive) { deleting = item }
                                    .disabled(sharing?.id == item.id)
                            }
                        }.buttonStyle(.borderless)
                    }.padding(.vertical, 4)
                }
                Section {
                    Text("最多保留 \(manager.limits.maximumCount) 筆下載，同時下載 \(manager.limits.maximumActive) 筆。單檔上限 \(bytes(manager.limits.maximumFileBytes))，總量上限 \(bytes(manager.limits.maximumTotalBytes))。")
                    Text("檔案保存在此 App 中。請點選「開啟或分享」選擇其他 App，或儲存到「檔案」。下載中離開 App 可能中斷；不會自動開啟檔案。")
                }.font(.footnote).foregroundStyle(.secondary)
            }
            .navigationTitle("下載項目")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .confirmationDialog("刪除下載項目？", isPresented: Binding(
                get: { deleting != nil }, set: { if !$0 { deleting = nil } }
            ), titleVisibility: .visible, presenting: deleting) { item in
                Button("刪除檔案與紀錄", role: .destructive) {
                    do { try manager.delete(id: item.id, confirmed: true) }
                    catch { actionError = (error as? BrowserDownloadError)?.localizedDescription ?? "無法刪除，請稍後再試。" }
                    deleting = nil
                }
                Button("取消", role: .cancel) { deleting = nil }
            } message: { item in
                Text("確定刪除「\(item.fileName)」？此 App 內的檔案會一併刪除，已分享的副本不受影響。")
            }
            .navigationDestination(isPresented: Binding(get: { selectedPDF != nil }, set: { presented in
                if !presented { selectedPDF?.invalidate(); selectedPDF = nil }
            })) {
                if let selectedPDF, let pdfDestination { pdfDestination(selectedPDF) }
            }
            .sheet(item: $sharing) { file in BrowserDownloadShareSheet(url: file.url) }
            .alert("無法完成操作", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
                Button("好", role: .cancel) { actionError = nil }
            } message: { Text(actionError ?? "") }
        }.accessibilityIdentifier("browser.downloads")
    }

    private func openPDF(_ item: BrowserDownloadItem) {
        do {
            selectedPDF?.invalidate()
            selectedPDF = try BrowserDownloadedPDFSelection(manager: manager, userSelectedID: item.id)
        } catch { actionError = (error as? LocalizedError)?.errorDescription ?? "無法開啟下載檔案。" }
    }

    private func share(_ item: BrowserDownloadItem) {
        do { sharing = SharedFile(id: item.id, url: try manager.fileURL(id: item.id)) }
        catch { actionError = (error as? BrowserDownloadError)?.localizedDescription ?? "無法開啟下載檔案。" }
    }

    private func sizeDescription(_ item: BrowserDownloadItem) -> String {
        if let total = item.totalBytes { return bytes(item.receivedBytes) + " / " + bytes(total) }
        return bytes(item.receivedBytes) + "・大小未知"
    }

    private func bytes(_ count: Int64) -> String { ByteCountFormatter.string(fromByteCount: count, countStyle: .file) }
}

@MainActor
private struct BrowserDownloadShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
