import SwiftUI
import AssistantMCP

struct MCPApprovalView: View {
    let proposal: MCPApprovalRequest
    let approve: () -> Void
    let decline: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("模型請求執行以下工具。核准只適用於這一次的名稱與參數；結果會提供給已設定的模型。")
                    Text(verbatim: proposal.name)
                        .font(.headline).textSelection(.enabled)
                        .accessibilityIdentifier("mcp.approval.name")
                    Text(verbatim: proposal.argumentsText)
                        .font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        .accessibilityIdentifier("mcp.approval.arguments")
                    Text("工具可能修改外部資料。取消本機等待無法撤銷已送出的操作。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .padding()
            }
            .navigationTitle("核准 MCP 呼叫")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Button("拒絕並停止", role: .cancel, action: decline)
                        .accessibilityIdentifier("mcp.approval.decline")
                    Spacer()
                    Button("核准這一次", action: approve)
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("mcp.approval.approve")
                }
                .padding().background(.bar)
            }
        }
    }
}

struct MCPResultsView: View {
    let steps: [MCPConversationStep]
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List(Array(steps.enumerated()), id: \.offset) { index, step in
                VStack(alignment: .leading, spacing: 8) {
                    if case .callTool(let name, _) = step.proposal.action { Text(verbatim: name).font(.headline) }
                    if case .readResource = step.proposal.action { Text("讀取 MCP 資源").font(.headline) }
                    Text(step.isError ? "工具回報錯誤" : "已收到工具結果")
                    Text(verbatim: resultText(step.result))
                        .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .privacySensitive().accessibilityIdentifier("mcp.result.\(index)")
                }
            }
            .navigationTitle("本次 MCP 工具結果")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
    private func resultText(_ value: JSONValue) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "結果無法顯示"
    }
}
