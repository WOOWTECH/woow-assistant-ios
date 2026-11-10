import AssistantMemory
import SwiftUI

struct MemoryToolReviewView: View {
    let review: MemoryToolReview
    let approve: () -> Void
    let decline: () -> Void

    private var operation: String {
        switch review.op { case .add: return "新增"; case .update: return "修改"; case .delete: return "刪除" }
    }
    private var kind: String {
        switch review.kind { case .fact: return "事實"; case .preference: return "偏好"; case .procedure: return "操作偏好"; case nil: return "記憶" }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("請核對這次記憶修改。核准後會儲存，並提供撤銷按鈕。")
                    Text(operation).font(.headline).accessibilityIdentifier("memoryTool.operation")
                    Text(kind).accessibilityIdentifier("memoryTool.kind")
                    Text("你的原話").font(.headline)
                    Text(verbatim: review.quote).textSelection(.enabled).accessibilityIdentifier("memoryTool.quote")
                    if let before = review.before {
                        Text("目前內容").font(.headline)
                        Text(verbatim: before.content).textSelection(.enabled).accessibilityIdentifier("memoryTool.before")
                    }
                    if let after = review.after {
                        Text("儲存後內容").font(.headline)
                        Text(verbatim: after.content).textSelection(.enabled).accessibilityIdentifier("memoryTool.after")
                        Text("搜尋關鍵字").font(.headline)
                        Text(verbatim: after.keywords.isEmpty ? "無" : after.keywords.joined(separator: "、"))
                            .accessibilityIdentifier("memoryTool.keywords")
                        if after.status == .pending {
                            Text("這條操作偏好會先列為待確認；需另外批准後，後續任務才會參考。")
                                .accessibilityIdentifier("memoryTool.pendingNotice")
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .navigationTitle("核對記憶修改")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("拒絕", action: decline).accessibilityIdentifier("memoryTool.decline")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("核准", action: approve).accessibilityIdentifier("memoryTool.approve")
                }
            }
        }
    }
}
