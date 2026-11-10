import Foundation

/// Serial use by the main-actor manager. Tests exercise real filesystem operations.
/// Each transfer has its own UUID directory, so identical names never overwrite.
final class BrowserDownloadStore {
    private struct Manifest: Codable { let version: Int; let items: [BrowserDownloadItem] }
    let directory: URL
    let limits: BrowserDownloadLimits
    private let files: URL
    private let partials: URL
    private let manifest: URL
    private let fm = FileManager.default
    private(set) var completed: [BrowserDownloadItem] = []
    private var pending: [UUID: URL] = [:]

    init(directory: URL, limits: BrowserDownloadLimits) throws {
        guard directory.isFileURL else { throw BrowserDownloadError.invalidFile }
        self.directory = directory.standardizedFileURL
        self.limits = limits
        files = directory.appendingPathComponent("Files", isDirectory: true)
        partials = directory.appendingPathComponent("Partial", isDirectory: true)
        manifest = directory.appendingPathComponent("completed.json")
        try makeDirectory(self.directory)
        try makeDirectory(files)
        try makeDirectory(partials)
        var root = self.directory
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try root.setResourceValues(values)
        try load()
        // App termination cannot leave a resumable transfer. Remove its private
        // partial folder at next launch; never traverse links or unrelated names.
        try cleanupUUIDDirectories(in: partials, keeping: [])
        try cleanupUUIDDirectories(in: files, keeping: Set(completed.map(\.id)))
    }

    var completedBytes: Int64 { completed.reduce(0) { $0 + $1.receivedBytes } }

    func destination(id: UUID, suggestedFilename: String) throws -> URL {
        guard pending[id] == nil, !completed.contains(where: { $0.id == id }),
              completed.count + pending.count < limits.maximumCount else { throw BrowserDownloadError.tooMany }
        try validateDirectory(directory); try validateDirectory(partials)
        let folder = partials.appendingPathComponent(id.uuidString, isDirectory: true)
        guard !fm.fileExists(atPath: folder.path) else { throw BrowserDownloadError.invalidFile }
        try makeDirectory(folder)
        let url = folder.appendingPathComponent(BrowserDownloadPolicy.sanitizedFilename(suggestedFilename))
        // WKDownload requires a nonexistent file in an existing directory.
        guard !fm.fileExists(atPath: url.path) else { throw BrowserDownloadError.invalidFile }
        pending[id] = url
        return url
    }

    func partialBytes(id: UUID) throws -> Int64 {
        guard let url = pending[id] else { return 0 }
        try validateDirectory(partials); try validateDirectory(url.deletingLastPathComponent())
        if !fm.fileExists(atPath: url.path) { return 0 }
        return try regularFileSize(url)
    }

    func finish(_ item: BrowserDownloadItem) throws -> BrowserDownloadItem {
        guard let source = pending[item.id], source.lastPathComponent == item.fileName else {
            throw BrowserDownloadError.invalidFile
        }
        try validateDirectory(directory); try validateDirectory(partials)
        try validateDirectory(source.deletingLastPathComponent()); try validateDirectory(files)
        let size = try regularFileSize(source)
        guard size <= limits.maximumFileBytes, completedBytes + size <= limits.maximumTotalBytes,
              completed.count < limits.maximumCount else { throw BrowserDownloadError.tooLarge }
        let folder = files.appendingPathComponent(item.id.uuidString, isDirectory: true)
        guard !fm.fileExists(atPath: folder.path) else { throw BrowserDownloadError.invalidFile }
        try makeDirectory(folder)
        let destination = folder.appendingPathComponent(item.fileName)
        var result = item
        result.status = .completed; result.receivedBytes = size; result.totalBytes = size
        result.completedAt = Date(); result.failureMessage = nil
        do {
            try fm.moveItem(at: source, to: destination)
            #if os(iOS)
            try fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: destination.path)
            #endif
            let next = [result] + completed
            try save(next)
            completed = next
        } catch {
            try? fm.removeItem(at: folder)
            throw error
        }
        // Publication is already durable. Failure to remove an empty temporary
        // directory must not turn a completed download into a failed record.
        try? discardPartial(id: item.id)
        return result
    }

    func discardPartial(id: UUID) throws {
        guard let url = pending[id] else { return }
        try validateDirectory(partials)
        try removeOwnedFolder(url.deletingLastPathComponent(), parent: partials)
        pending.removeValue(forKey: id)
    }

    func fileURL(id: UUID) throws -> URL {
        guard let item = completed.first(where: { $0.id == id }) else { throw BrowserDownloadError.missingFile }
        try validateDirectory(directory); try validateDirectory(files)
        let folder = files.appendingPathComponent(id.uuidString, isDirectory: true)
        try validateDirectory(folder)
        let file = folder.appendingPathComponent(item.fileName)
        guard try regularFileSize(file) == item.receivedBytes else { throw BrowserDownloadError.invalidFile }
        return file
    }

    func delete(id: UUID, confirmed: Bool) throws {
        guard confirmed else { throw BrowserDownloadError.confirmationRequired }
        guard completed.contains(where: { $0.id == id }) else { return }
        try validateDirectory(directory); try validateDirectory(files)
        let next = completed.filter { $0.id != id }
        try save(next)
        do {
            try removeOwnedFolder(files.appendingPathComponent(id.uuidString), parent: files)
            completed = next
        } catch {
            try? save(completed)
            throw error
        }
    }

    private func load() throws {
        guard fm.fileExists(atPath: manifest.path) else { return }
        do {
            guard try regularFileSize(manifest) <= Int64(limits.maximumMetadataBytes) else {
                throw BrowserDownloadError.invalidMetadata
            }
            let decoded = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifest))
            guard decoded.version == 1, decoded.items.count <= limits.maximumCount,
                  Set(decoded.items.map(\.id)).count == decoded.items.count else { throw BrowserDownloadError.invalidMetadata }
            for item in decoded.items {
                guard item.status == .completed, item.failureMessage == nil,
                      item.fileName == BrowserDownloadPolicy.sanitizedFilename(item.fileName),
                      item.receivedBytes >= 0, item.receivedBytes <= limits.maximumFileBytes,
                      item.totalBytes == item.receivedBytes, item.completedAt != nil,
                      item.createdAt.timeIntervalSince1970.isFinite,
                      item.completedAt?.timeIntervalSince1970.isFinite == true else { throw BrowserDownloadError.invalidMetadata }
                let folder = files.appendingPathComponent(item.id.uuidString)
                let file = folder.appendingPathComponent(item.fileName)
                // Missing files are pruned. Modified/symlinked files fail closed.
                guard fm.fileExists(atPath: file.path) else { continue }
                try validateDirectory(folder)
                guard try regularFileSize(file) == item.receivedBytes else { throw BrowserDownloadError.invalidMetadata }
                completed.append(item)
            }
            guard completedBytes <= limits.maximumTotalBytes else { throw BrowserDownloadError.invalidMetadata }
            if completed.count != decoded.items.count { try save(completed) }
        } catch { throw BrowserDownloadError.invalidMetadata }
    }

    private func save(_ items: [BrowserDownloadItem]) throws {
        try validateDirectory(directory)
        let data = try JSONEncoder().encode(Manifest(version: 1, items: items))
        guard data.count <= limits.maximumMetadataBytes, items.count <= limits.maximumCount else {
            throw BrowserDownloadError.invalidMetadata
        }
        // Atomic replacement; no full request or WebKit resume state is persisted.
        try data.write(to: manifest, options: .atomic)
        #if os(iOS)
        try fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: manifest.path)
        #endif
    }

    private func makeDirectory(_ url: URL) throws {
        try fm.createDirectory(at: url, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try validateDirectory(url)
    }

    private func validateDirectory(_ url: URL) throws {
        let attributes = try fm.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw BrowserDownloadError.invalidFile }
        // A symlink above a child must not redirect sandbox writes elsewhere.
        if url.standardizedFileURL.path != directory.path {
            let resolvedRoot = directory.resolvingSymlinksInPath().path + "/"
            guard url.resolvingSymlinksInPath().path.hasPrefix(resolvedRoot) else { throw BrowserDownloadError.invalidFile }
        }
    }

    private func regularFileSize(_ url: URL) throws -> Int64 {
        let attributes = try fm.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.referenceCount] as? NSNumber)?.intValue == 1,
              let number = attributes[.size] as? NSNumber else { throw BrowserDownloadError.invalidFile }
        return number.int64Value
    }

    private func removeOwnedFolder(_ url: URL, parent: URL) throws {
        guard url.deletingLastPathComponent().standardizedFileURL.path == parent.standardizedFileURL.path,
              UUID(uuidString: url.lastPathComponent) != nil else { throw BrowserDownloadError.invalidFile }
        if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
    }

    private func cleanupUUIDDirectories(in parent: URL, keeping ids: Set<UUID>) throws {
        try validateDirectory(parent)
        // Enumerate only this level; removeItem removes a symlink itself.
        let enumerator = fm.enumerator(at: parent, includingPropertiesForKeys: nil,
                                       options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles])
        var count = 0
        while let url = enumerator?.nextObject() as? URL {
            count += 1
            guard count <= 1_000 else { throw BrowserDownloadError.unavailable }
            if let id = UUID(uuidString: url.lastPathComponent), !ids.contains(id) {
                try removeOwnedFolder(url, parent: parent)
            }
        }
    }
}
