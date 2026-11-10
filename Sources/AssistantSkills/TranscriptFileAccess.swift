#if !SKILL_EXECUTION_SMOKE && !SKILLS_CORE_SMOKE && !SKILL_AUTHORING_SMOKE
import Darwin
import Foundation

/// Selection records only a URL and its display name. No file bytes are accessed
/// until read(approving:) consumes the exact review token.
@MainActor public final class TranscriptFileAccess {
    private var selected: (review: TranscriptFileReview, url: URL)?
    private var operation: TranscriptReadOperation?
    private let readTimeout: TimeInterval
    public init() { readTimeout = 30 }
    // Testable shorter deadline, never a production extension of the bound.
    init(readTimeout: TimeInterval) { self.readTimeout = min(30, max(0.01, readTimeout)) }

    public func select(_ url: URL) throws -> TranscriptFileReview {
        cancel()
        guard url.isFileURL, url.query == nil, url.fragment == nil else { throw TranscriptError.invalidSelection }
        guard ["txt", "srt", "vtt", "md"].contains(url.pathExtension.lowercased()) else { throw TranscriptError.unsupportedType }
        let name = url.lastPathComponent
        guard !name.isEmpty, name.utf8.count <= 512,
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw TranscriptError.invalidSelection }
        let review = TranscriptFileReview(id: UUID(), filename: name)
        selected = (review, url)
        return review
    }

    public func read(approving id: UUID) async throws -> TranscriptSnapshot {
        guard let selected, selected.review.id == id else { throw TranscriptError.approvalRequired }
        self.selected = nil
        let operation = TranscriptReadOperation(url: selected.url, filename: selected.review.filename, timeout: readTimeout)
        self.operation = operation
        defer { if self.operation === operation { self.operation = nil } }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await operation.run()
        } onCancel: { operation.cancel(.cancelled) }
    }

    public func cancel() {
        selected = nil; operation?.cancel(.cancelled); operation = nil
    }
}

/// The continuation is resolved once, even when a file provider ignores cancel.
/// A late accessor cannot publish data. Its security scope closes on return.
private final class TranscriptReadOperation: @unchecked Sendable {
    private let lock = NSLock()
    private let coordinator = NSFileCoordinator(filePresenter: nil)
    private let url: URL
    private let filename: String
    private let timeout: TimeInterval
    private var continuation: CheckedContinuation<TranscriptSnapshot, Error>?
    private var terminal: Result<TranscriptSnapshot, Error>?
    init(url: URL, filename: String, timeout: TimeInterval) { self.url = url; self.filename = filename; self.timeout = timeout }

    func run() async throws -> TranscriptSnapshot {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let terminal { lock.unlock(); continuation.resume(with: terminal); return }
            self.continuation = continuation
            lock.unlock()
            DispatchQueue.global(qos: .userInitiated).async { self.performRead() }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.cancel(.readTimedOut)
            }
        }
    }

    func cancel(_ error: TranscriptError) {
        finish(.failure(error)); coordinator.cancel()
    }

    private func checkActive() throws {
        lock.lock(); let finished = terminal != nil; lock.unlock()
        if finished { throw TranscriptError.cancelled }
    }

    private func finish(_ result: Result<TranscriptSnapshot, Error>) {
        lock.lock()
        guard terminal == nil else { lock.unlock(); return }
        terminal = result; let pending = continuation; continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }

    private func performRead() {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            try checkActive()
            guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                throw TranscriptError.invalidSelection
            }
            var error: NSError?
            var result: Result<TranscriptSnapshot, Error>?
            coordinator.coordinate(readingItemAt: url, options: [], error: &error) { accessorURL in
                result = Result {
                    try self.checkActive()
                    guard try accessorURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                        throw TranscriptError.invalidSelection
                    }
                    // O_NOFOLLOW closes the final-component symlink race after
                    // metadata checking. Validate the opened descriptor, not a
                    // second path lookup. Only type and size are read from stat.
                    let descriptor = accessorURL.withUnsafeFileSystemRepresentation {
                        $0.map { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK) } ?? -1
                    }
                    guard descriptor >= 0 else { throw TranscriptError.invalidSelection }
                    defer { Darwin.close(descriptor) }
                    var info = stat()
                    guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
                        throw TranscriptError.invalidSelection
                    }
                    guard info.st_size >= 0, info.st_size <= TranscriptSnapshot.maximumBytes else { throw TranscriptError.tooLarge }
                    var data = Data(), buffer = [UInt8](repeating: 0, count: 8192)
                    while true {
                        try self.checkActive()
                        let available = min(buffer.count, TranscriptSnapshot.maximumBytes + 1 - data.count)
                        let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress!, available) }
                        if count < 0 { if errno == EINTR { continue }; throw TranscriptError.invalidSelection }
                        if count == 0 { break }
                        data.append(contentsOf: buffer.prefix(count))
                        guard data.count <= TranscriptSnapshot.maximumBytes else { throw TranscriptError.tooLarge }
                    }
                    try self.checkActive()
                    return try TranscriptSnapshot(filename: self.filename, data: data)
                }
            }
            try checkActive()
            guard error == nil, let result else { throw TranscriptError.invalidSelection }
            finish(result)
        } catch let error as TranscriptError { finish(.failure(error)) }
        catch { finish(.failure(TranscriptError.invalidSelection)) }
    }
}
#endif
