import AssistantMemory
import SwiftUI

struct UserProfileToolReviewView: View {
    let review: UserProfileToolReview
    let approve: () -> Void
    let decline: () -> Void

    private var operation: String {
        switch review.op { case .add: return "新增"; case .replace: return "修改"; case .delete: return "刪除" }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("模型提出以下個人檔案修改。請核對是否符合你這次的要求；核准後會儲存，下次對話開始時生效。")
                    Text(operation).font(.headline).accessibilityIdentifier("profileTool.operation")
                    Text("你的原話").font(.headline)
                    Text(verbatim: review.quote).textSelection(.enabled).accessibilityIdentifier("profileTool.quote")
                    if let before = review.before {
                        Text("目前內容").font(.headline)
                        Text(verbatim: before).textSelection(.enabled).accessibilityIdentifier("profileTool.before")
                    }
                    if let after = review.after {
                        Text("儲存後內容").font(.headline)
                        Text(verbatim: after).textSelection(.enabled).accessibilityIdentifier("profileTool.after")
                    } else {
                        Text("這條內容將不再用於後續對話；修改歷史會保留。")
                    }
                }.padding()
            }
            .navigationTitle("核對個人檔案")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Button("拒絕並停止", role: .cancel, action: decline)
                        .accessibilityIdentifier("profileTool.decline")
                    Spacer()
                    Button("核准並儲存", action: approve)
                        .buttonStyle(.borderedProminent).accessibilityIdentifier("profileTool.approve")
                }.padding().background(.bar)
            }
        }
    }
}
