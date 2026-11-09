import SwiftUI

struct ContentView: View {
    @State private var selection: AppSection = .chat
    @State private var draft = ""

    var body: some View {
        NavigationStack {
            Group {
                if selection == .chat {
                    ChatPlaceholder(draft: $draft)
                } else {
                    FeaturePlaceholder(section: selection)
                }
            }
            .navigationTitle(selection.title)
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                sectionNavigation
            }
        }
    }

    // Keep every section reachable in a compact iPhone layout, including while typing.
    private var sectionNavigation: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 0) {
                ForEach(AppSection.allCases) { section in
                    Button {
                        selection = section
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: section.symbol)
                                .font(.body)
                            Text(section.shortTitle)
                                .font(.caption)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(selection == section ? Color.accentColor : Color.secondary)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(section.title)
                    .accessibilityValue(selection == section ? "已選取" : "未選取")
                    .accessibilityAddTraits(selection == section ? .isSelected : [])
                    .accessibilityIdentifier("navigation.\(section.rawValue)")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("navigation.sections")
    }
}

private enum AppSection: String, CaseIterable, Identifiable {
    case chat
    case browser
    case tools
    case memory
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chat: return "對話"
        case .browser: return "瀏覽器"
        case .tools: return "Skills 與 MCP"
        case .memory: return "記憶與檔案"
        case .settings: return "設定"
        }
    }

    var shortTitle: String {
        switch self {
        case .tools: return "工具"
        case .memory: return "資料"
        default: return title
        }
    }

    var symbol: String {
        switch self {
        case .chat: return "message"
        case .browser: return "globe"
        case .tools: return "puzzlepiece.extension"
        case .memory: return "folder"
        case .settings: return "gearshape"
        }
    }

    var explanation: String {
        switch self {
        case .chat:
            return "此版本尚未連接模型，暫時無法傳送訊息。切換分頁時會保留目前的草稿。"
        case .browser:
            return "此版本尚未載入網頁，也未進行網站連線驗證。分頁、登入、上傳、下載與頁面操作仍待實作。"
        case .tools:
            return "此版本尚未載入或執行 Skills，也未連接 MCP 伺服器；目前沒有可呼叫的工具。"
        case .memory:
            return "此版本尚未提供記憶儲存、附件匯入或檔案管理。"
        case .settings:
            return "此版本尚未提供模型、通知、語言、外觀與隱私設定。"
        }
    }
}

private struct ChatPlaceholder: View {
    @Binding var draft: String
    @FocusState private var isEditingDraft: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "message")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("對話尚未實作")
                    .font(.title2.bold())
                    .accessibilityIdentifier("chat.status")
                Text(AppSection.chat.explanation)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("chat.explanation")
                TextField("輸入訊息", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .focused($isEditingDraft)
                    .submitLabel(.done)
                    .onSubmit { isEditingDraft = false }
                    .accessibilityLabel("訊息草稿")
                    .accessibilityIdentifier("chat.draft")
                Button("傳送（尚未開放）") {}
                    .buttonStyle(.borderedProminent)
                    .disabled(true)
                    .accessibilityHint("尚未連接模型，無法傳送訊息；草稿會保留。")
                    .accessibilityIdentifier("chat.send")
            }
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
            .padding()
        }
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成") { isEditingDraft = false }
                    .accessibilityIdentifier("chat.dismissKeyboard")
            }
        }
    }
}

private struct FeaturePlaceholder: View {
    let section: AppSection

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: section.symbol)
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("\(section.title)尚未實作")
                    .font(.title2.bold())
                    .accessibilityIdentifier("\(section.rawValue).status")
                Text(section.explanation)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("\(section.rawValue).explanation")
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
            .padding()
        }
    }
}
