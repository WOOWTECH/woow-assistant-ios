import Foundation

/// DEBUG-only synthetic source creation. No picker selection, file-read approval,
/// model answer, runtime source injection or networking is performed here.
enum TranscriptUITestSupport {
    struct Fixture {
        let namespace: UUID
        let url: URL
        var filename: String { url.lastPathComponent }
    }
    enum Failure: Error { case invalidNamespace, existingFile }

    static func seedIfRequested(arguments: [String] = ProcessInfo.processInfo.arguments,
        documentsDirectory: () throws -> URL = {
            try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        }) throws -> Fixture? {
        #if DEBUG
        guard arguments.contains("-UITestTranscript") else { return nil }
        let local = arguments.filter { $0 == "-UITestMode" }.count
        let live = arguments.filter { $0 == "-LiveModelUITest" }.count
        let namespaceFlag = local == 1 ? "-UITestNamespace" : "-LiveModelUITestNamespace"
        let otherNamespaceFlag = local == 1 ? "-LiveModelUITestNamespace" : "-UITestNamespace"
        guard arguments.filter({ $0 == "-UITestTranscript" }).count == 1,
              (local == 1 && live == 0) || (local == 0 && live == 1),
              !arguments.contains("-LiveModelUITestCleanup"), !arguments.contains(otherNamespaceFlag),
              arguments.filter({ $0 == namespaceFlag }).count == 1,
              let index = arguments.firstIndex(of: namespaceFlag), arguments.indices.contains(index + 1),
              let namespace = UUID(uuidString: arguments[index + 1]) else { throw Failure.invalidNamespace }
        let root = try documentsDirectory()
        let url = root.appendingPathComponent("Transcript-\(namespace.uuidString).txt")
        let data = Data(sourceText(namespace: namespace).utf8)
        if FileManager.default.fileExists(atPath: url.path) {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true, values.fileSize == data.count else {
                throw Failure.existingFile
            }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            guard try handle.read(upToCount: data.count + 1) == data else { throw Failure.existingFile }
        } else {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try data.write(to: url, options: .withoutOverwriting)
        }
        return Fixture(namespace: namespace, url: url)
        #else
        return nil
        #endif
    }

    #if DEBUG
    /// Source facts only. More than one 8192-byte read is needed; no expected
    /// summary, finish JSON, model instruction or synthesized answer is seeded.
    static func sourceText(namespace: UUID) -> String {
        var lines = ["社區圖書館工作紀錄", "來源識別：" + namespace.uuidString, ""]
        for number in 1...64 {
            lines += ["第 \(number) 段：館藏盤點與讀者服務。",
                      "本週志工依序核對書名、作者與架號，將需要修補的書另列清單；尚未確認的資訊保留空白。",
                      "讀者可以在服務台提出借閱問題，工作人員會先核對紀錄，再說明可選擇的處理方式。", ""]
        }
        lines += ["工作紀錄結尾：月底再次核對待修清單。", "結尾識別：" + namespace.uuidString, ""]
        return lines.joined(separator: "\n")
    }
    #endif
}

#if DEBUG
struct TranscriptUITestAudit {
    enum Event { case selected, fileRead(bytes: Int), modelRequest, rangeRead(covered: Int, total: Int), completed }
    private(set) var selections = 0
    private(set) var reads = 0
    private(set) var modelAttempts = 0
    private(set) var rangeReads = 0
    private(set) var covered = 0
    private(set) var total = 0
    private(set) var results = 0
    mutating func record(_ event: Event) {
        switch event {
        case .selected: selections += 1; covered = 0; total = 0
        case .fileRead(let bytes): reads += 1; total = bytes; covered = 0
        case .modelRequest: modelAttempts += 1
        case .rangeRead(let count, let bytes): rangeReads += 1; covered = count; total = bytes
        case .completed: results += 1
        }
    }
    var evidence: String {
        "TRANSCRIPT_AUDIT selections=\(selections) reads=\(reads) modelAttempts=\(modelAttempts) rangeReads=\(rangeReads) covered=\(covered) total=\(total) results=\(results)"
    }
}
#endif
