import AssistantSkills
import SwiftUI

/// Parent entry: SkillAgentView(store: session.learning,
///                             modelAccess: { try session.modelAccess() })
@MainActor struct SkillAgentView: View {
    @ObservedObject var store: LearningStore
    let modelAccess: () throws -> ModelAccess
    @StateObject private var agent = SkillAgentSession()
    @State private var request = ""
    @State private var answer = ""
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                Text(agent.activity).accessibilityIdentifier("skillAgent.status")
                if let error = agent.error {
                    Text(verbatim: error).foregroundStyle(.red).accessibilityIdentifier("skillAgent.error")
                }
            }
            if let receipt = agent.receipt {
                Section("已儲存至個人技能") {
                    Text(verbatim: receipt.name).accessibilityIdentifier("skillAgent.receipt")
                    Text("試用中；尚未驗證這份做法的實際成果。工具操作仍須各自核准。")
                    Text("版本：" + receipt.version).font(.caption)
                }
            } else if let review = agent.review {
                Section("本次要求") { Text(verbatim: review.requestQuote) }
                Section(review.isUpdate ? "核對更新全文" : "核對新技能全文") {
                    Text(verbatim: review.name).accessibilityIdentifier("skillAgent.review.name")
                    Text("核准後才會儲存為「試用中」。這一步不會執行技能。")
                    Text(verbatim: review.markdown).font(.system(.body, design: .monospaced))
                        .textSelection(.enabled).accessibilityIdentifier("skillAgent.review.markdown")
                    DisclosureGroup("來源與版本") {
                        Text(verbatim: review.original.path + "\n" + review.original.revision
                            + "\n原文 SHA-256：" + review.original.sha256
                            + "\n草稿 SHA-256：" + review.draftFingerprint
                            + (review.replacesFingerprint.map { "\n原版本 SHA-256：" + $0 } ?? ""))
                            .font(.caption).textSelection(.enabled)
                    }
                }
            } else if let question = agent.question {
                Section("補充要求") {
                    Text(verbatim: question).accessibilityIdentifier("skillAgent.question")
                    TextEditor(text: $answer).frame(minHeight: 110).focused($focused)
                        .autocorrectionDisabled().accessibilityLabel("補充要求")
                        .accessibilityIdentifier("skillAgent.answer")
                }
            } else if !agent.running {
                Section("請模型協作編寫技能") {
                    Text("說明要建立、匯入或修改的做法。要求及本次查閱的技能內容會傳給已設定的模型；請勿填入密碼或金鑰。")
                    TextEditor(text: $request).frame(minHeight: 130).focused($focused)
                        .autocorrectionDisabled().accessibilityLabel("技能協作要求")
                        .accessibilityIdentifier("skillAgent.request")
                    Text("模型會查詢、讀取並準備完整草稿，由你核准後儲存。內建原文的腳本與其他 App 操作不會因此啟用。")
                        .font(.footnote)
                    if let message = agent.message {
                        Text(verbatim: message).accessibilityIdentifier("skillAgent.model.message")
                    }
                }
            }
            if !agent.steps.isEmpty {
                Section("本次工具紀錄") {
                    ForEach(Array(agent.steps.enumerated()), id: \.offset) { index, step in
                        Text(step).accessibilityIdentifier("skillAgent.step.\(index)")
                    }
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("模型協作編寫技能")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            VStack {
                if agent.running {
                    Button("停止協作") { agent.cancel() }.accessibilityIdentifier("skillAgent.cancel")
                } else if agent.review != nil {
                    Button("核准並儲存這份全文") { focused = false; agent.approve(store: store, modelAccess: modelAccess) }
                        .disabled(!store.available).accessibilityIdentifier("skillAgent.approve")
                    Button("捨棄草稿") { agent.cancel() }.accessibilityIdentifier("skillAgent.refuse")
                } else if agent.question != nil {
                    Button("送出補充") {
                        focused = false; agent.answer(answer, store: store, modelAccess: modelAccess); answer = ""
                    }
                    .disabled(answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("skillAgent.answer.send")
                } else if agent.receipt == nil {
                    Button("開始模型協作") {
                        focused = false; agent.start(request: request, store: store, modelAccess: modelAccess)
                    }
                    .disabled(!store.available || request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("skillAgent.start")
                }
            }.buttonStyle(.borderedProminent).padding().frame(maxWidth: .infinity).background(.regularMaterial)
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(agent.receipt == nil ? "取消" : "完成") { agent.cancel(showNotice: false); dismiss() }
                    .accessibilityIdentifier("skillAgent.close")
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer(); Button("完成輸入") { focused = false }.accessibilityIdentifier("skillAgent.keyboard.done")
            }
        }
        .onReceive(store.objectWillChange) { agent.hostChanged() }
        .onDisappear { agent.cancel(showNotice: false) }
    }
}
