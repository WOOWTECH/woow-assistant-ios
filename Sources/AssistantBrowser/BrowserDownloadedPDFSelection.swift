#if canImport(WebKit) && canImport(Combine)
import AssistantSkills
import Combine
import Foundation

/// An explicit selection of one completed, App-owned download. Creating this
/// object checks metadata only; it neither reads PDF bytes nor grants execution.
/// Never construct this from model output, a URL string, or persisted selection.
@MainActor public final class BrowserDownloadedPDFSelection: Identifiable {
    public let id = UUID()
    public let downloadID: UUID
    public let filename: String
    public private(set) var isValid = true
    public var onInvalidated: (() -> Void)?
    private let manager: BrowserDownloadManager
    private let record: BrowserDownloadItem
    private let url: URL
    private let identity: Identity
    private var observation: AnyCancellable?

    public init(manager: BrowserDownloadManager, userSelectedID: UUID) throws {
        guard let item = manager.items.first(where: { $0.id == userSelectedID }),
              item.status == .completed,
              URL(fileURLWithPath: item.fileName).pathExtension.lowercased() == "pdf" else {
            throw SkillExecutionError.invalidSelection
        }
        guard item.receivedBytes <= SkillExecutionLimits.fileBytes else { throw SkillExecutionError.fileTooLarge }
        let url = try manager.fileURL(id: item.id)
        self.manager = manager; record = item; downloadID = item.id
        filename = item.fileName; self.url = url; identity = try Identity(url)
        observation = manager.$items.sink { [weak self] items in
            // Published delivers before the manager property changes. Validate
            // the delivered records, not a stale read of manager.items.
            guard let self else { return }
            if items.first(where: { $0.id == self.downloadID }) != self.record { self.invalidate() }
        }
    }

    /// Recheck immediately before each explicit approval and after each await.
    /// The existing runtime still performs its own coordinated, bounded read.
    public func selectedFile() throws -> SkillExecutionSelectedFile {
        do {
            guard isValid, manager.items.first(where: { $0.id == downloadID }) == record,
                  try manager.fileURL(id: downloadID) == url,
                  try Identity(url) == identity else { throw SkillExecutionError.invalidSelection }
            return try SkillExecutionSelectedFile(userSelectedBrowserDownloadURL: url, downloadID: downloadID)
        } catch {
            invalidate()
            throw SkillExecutionError.invalidSelection
        }
    }

    public func invalidate() {
        guard isValid else { return }
        isValid = false
        observation?.cancel(); observation = nil
        let callback = onInvalidated; onInvalidated = nil
        callback?()
    }

    private struct Identity: Equatable {
        let volume: UInt64
        let inode: UInt64
        let bytes: Int64
        let modified: Date
        let created: Date

        init(_ url: URL) throws {
            let values = try FileManager.default.attributesOfItem(atPath: url.path)
            guard values[.type] as? FileAttributeType == .typeRegular,
                  (values[.referenceCount] as? NSNumber)?.intValue == 1,
                  let volume = values[.systemNumber] as? NSNumber,
                  let inode = values[.systemFileNumber] as? NSNumber,
                  let bytes = values[.size] as? NSNumber,
                  let modified = values[.modificationDate] as? Date,
                  let created = values[.creationDate] as? Date else { throw SkillExecutionError.invalidSelection }
            self.volume = volume.uint64Value; self.inode = inode.uint64Value
            self.bytes = bytes.int64Value; self.modified = modified; self.created = created
        }
    }
}

#endif
