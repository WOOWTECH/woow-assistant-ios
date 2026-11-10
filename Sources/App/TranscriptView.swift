import AssistantSkills
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// Host passes the actual configured access plus a publisher that fires whenever
/// that configuration/credential changes. Saved references are read-only snapshots.
@MainActor struct TranscriptView: View {
    let modelAccess: () throws -> ModelAccess
    let modelChanges: AnyPublisher<Void, Never>
    let approvedSource: TranscriptSnapshot?
    @StateObject private var session: TranscriptSession
    @State private var choosing = false
    @State private var format: TranscriptFormat = .summary
    @State private var loadedApprovedSource: UUID?
    @State private var sourceExpanded = false
    @Environment(\.dismiss) private var dismiss
    #if DEBUG
    @State private var fixtureNotice: String?
    #endif

    init(learning: LearningStore, modelAccess: @escaping () throws -> ModelAccess, modelChanges: AnyPublisher<Void, Never>,
         approvedSource: TranscriptSnapshot? = nil) {
        _session = StateObject(wrappedValue: TranscriptSession(learning: learning))
        self.modelAccess = modelAccess; self.modelChanges = modelChanges; self.approvedSource = approvedSource
    }

    var body: some View {
        Form {
            Section {
                Text(session.status).accessibilityIdentifier("transcript.status")
                Text("僅整理使用者選取的文字或字幕；不會聽取音訊或觀看影片。")
                if let error = session.error {
                    Text(verbatim: error).foregroundStyle(.red).accessibilityIdentifier("transcript.error")
                }
                Button("選取文字稿或字幕檔") { choosing = true }
                    .disabled(session.running).accessibilityIdentifier("transcript.choose")
                #if DEBUG
                Text(session.diagnostic).font(.caption).accessibilityIdentifier("transcript.diagnostic")
                if let fixtureNotice {
                    Text(verbatim: fixtureNotice).accessibilityIdentifier("transcript.uitest.fixture")
                    Text(session.audit.evidence).font(.caption).accessibilityIdentifier("transcript.uitest.audit")
                }
                #endif
            }
            if let review = session.review {
                Section("核對本次讀取") {
                    Text(verbatim: review.filename).accessibilityIdentifier("transcript.review.filename")
                    Text("核准後只讀取此檔案，最多 64 KiB、等待最多 30 秒。這一步不會傳送給模型。")
                    Button("核准讀取這份文字檔") { session.approveRead() }
                        .disabled(session.running).accessibilityIdentifier("transcript.approveRead")
                    Button("拒絕讀取", role: .cancel) { session.cancel() }
                        .accessibilityIdentifier("transcript.refuse")
                }
            }
            if let source = session.snapshot {
                Section("已核准的文字快照") {
                    Text(verbatim: source.filename).accessibilityIdentifier("transcript.filename")
                    Text("\(source.byteCount) 位元組 · UTF-8")
                    if let url = source.sourceURL {
                        Text(verbatim: url.absoluteString).font(.caption).accessibilityIdentifier("transcript.sourceURL")
                    }
                    Button(sourceExpanded ? "收合原文" : "查看原文") { sourceExpanded.toggle() }
                        .accessibilityIdentifier("transcript.showSource")
                    if sourceExpanded {
                        Text(verbatim: source.text).textSelection(.enabled).accessibilityIdentifier("transcript.source")
                    }
                    Text("SHA-256：" + source.sha256).font(.caption).textSelection(.enabled)
                }
                Section("傳送前確認") {
                    Picker("整理形式", selection: $format) {
                        ForEach(TranscriptFormat.allCases, id: \.self) { value in Text(value.title).tag(value) }
                    }.disabled(session.running).accessibilityIdentifier("transcript.format")
                    if let destination = session.destination {
                        Text(verbatim: destination).accessibilityIdentifier("transcript.destination")
                    }
                    Button("確認目前設定的目的服務") { session.confirmDestination(modelAccess: modelAccess) }
                        .disabled(session.running).accessibilityIdentifier("transcript.confirmDestination")
                    Text("開始後，檔名、原文，以及依目前開關選取的個人檔案、記憶與已啟用技能參考會傳至上述服務。參考資料不會成為原文證據；產出不會自動寫入記憶或技能。")
                        .accessibilityIdentifier("transcript.referenceNotice")
                    Button("將這份文字傳給模型並整理") { session.start(format: format, modelAccess: modelAccess) }
                        .disabled(session.destination == nil || session.running).accessibilityIdentifier("transcript.start")
                }
            }
            if let refusal = session.refusal {
                Section("模型回覆：未完成") { Text(verbatim: refusal).accessibilityIdentifier("transcript.refusal") }
            }
            if let result = session.result {
                Section("整理結果") {
                    Text(verbatim: result.title).font(.headline).accessibilityIdentifier("transcript.result")
                    Text("僅依文字來源整理。全部位元組已讀取，下列原文證據已逐字核對；這不代表字幕與影音相符，或所有論點皆已正確摘要。")
                    ForEach(result.sections) { section in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(verbatim: section.title).font(.headline)
                            Text(verbatim: section.text).textSelection(.enabled)
                                .accessibilityIdentifier("transcript.section.\(section.id)")
                            ForEach(Array(section.evidence.enumerated()), id: \.offset) { index, evidence in
                                VStack(alignment: .leading) {
                                    Text("原文引文 · 位元組 \(evidence.offset)" + (evidence.timestamp.map { " · " + $0 } ?? ""))
                                        .font(.caption)
                                    Text(verbatim: evidence.quote).textSelection(.enabled)
                                        .accessibilityIdentifier("transcript.evidence.\(section.id).\(index)")
                                }
                            }
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier("transcript.form")
        .navigationTitle("整理文字稿與字幕")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") { session.cancel(notice: false); dismiss() }.accessibilityIdentifier("transcript.close")
            }
        }
        .safeAreaInset(edge: .bottom) {
            if session.running {
                Button("停止整理") { session.cancel() }.buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("transcript.cancel").padding()
                    .frame(maxWidth: .infinity).background(.regularMaterial)
            }
        }
        .fileImporter(isPresented: $choosing, allowedContentTypes: Self.allowedTypes, allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard urls.count == 1, let url = urls.first else { session.selectionFailed(); return }
                session.select(url)
            case .failure: session.selectionFailed()
            }
        }
        .onAppear {
            if let approvedSource, loadedApprovedSource != approvedSource.id {
                session.loadApprovedSource(approvedSource); loadedApprovedSource = approvedSource.id
            }
            #if DEBUG
            do {
                if let fixture = try TranscriptUITestSupport.seedIfRequested() {
                    fixtureNotice = "測試文字檔已建立：" + fixture.filename
                }
            } catch { fixtureNotice = "測試文字檔建立失敗。" }
            #endif
        }
        .onReceive(modelChanges) { session.hostChanged() }
        .onDisappear { session.cancel(notice: false) }
    }

    private static var allowedTypes: [UTType] {
        [.plainText] + ["txt", "srt", "vtt", "md"].compactMap { UTType(filenameExtension: $0) }
    }
}
