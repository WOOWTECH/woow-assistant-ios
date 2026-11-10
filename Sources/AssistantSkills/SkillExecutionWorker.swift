import Foundation

/// Opt-in protocol client; there is deliberately no default/live endpoint.
/// Production requires a separately provisioned HTTPS gateway and authenticated transport.
public struct SkillExecutionHTTPWorker: SkillExecutionPDFWorker {
    public static let scriptSHA256 = "41c2e2b51cd23173e0891084d0cd93d54e300e5fd571876740de36ac5968817c"
    public let destination: String
    private let endpoint: URL
    private let authorizationBearer: String?

    public init(endpoint: URL, authorizationBearer: String? = nil, allowLoopbackForTesting: Bool = false) throws {
        let loopback = ["127.0.0.1", "localhost", "[::1]"].contains(endpoint.host ?? "")
        guard endpoint.scheme == "https" || (allowLoopbackForTesting && endpoint.scheme == "http" && loopback),
              endpoint.host != nil, endpoint.user == nil, endpoint.password == nil,
              endpoint.query == nil, endpoint.fragment == nil else { throw SkillExecutionError.unavailable }
        if let authorizationBearer {
            guard !authorizationBearer.isEmpty, authorizationBearer.utf8.count <= 4096,
                  authorizationBearer.unicodeScalars.allSatisfy({ (33...126).contains($0.value) }) else {
                throw SkillExecutionError.unavailable
            }
        }
        self.endpoint = endpoint; destination = endpoint.absoluteString
        self.authorizationBearer = authorizationBearer
    }

    public func extract(data: Data, options: SkillExecutionPDFOptions) async throws -> SkillExecutionPDFResult {
        guard data.count <= SkillExecutionLimits.fileBytes else { throw SkillExecutionError.fileTooLarge }
        let requestID = UUID().uuidString
        var payload: [String: Any] = ["version": 1, "requestID": requestID, "operation": "extract_pdf",
            "revision": BundledSkillCatalog.pinnedCommit, "scriptSHA256": Self.scriptSHA256,
            "pdfBase64": data.base64EncodedString(), "inputSHA256": skillExecutionDigest(data), "metadataOnly": options.metadataOnly]
        if let pages = options.pages { payload["pages"] = pages }
        if let password = options.password { payload["password"] = password }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"; request.timeoutInterval = 65
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let authorizationBearer { request.setValue("Bearer " + authorizationBearer, forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCache = nil; config.urlCredentialStorage = nil
        config.timeoutIntervalForResource = 65
        let delegate = SkillExecutionNoRedirect()
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (stream, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  response.expectedContentLength <= Int64(SkillExecutionLimits.outputBytes * 3) else {
                throw SkillExecutionError.workerFailed
            }
            var body = Data()
            for try await byte in stream {
                guard body.count < SkillExecutionLimits.outputBytes * 3 else { throw SkillExecutionError.outputTooLarge }
                body.append(byte)
            }
            return try decode(body, requestID: requestID, input: data, options: options)
        } catch is CancellationError { throw CancellationError() }
        catch let error as SkillExecutionError { throw error }
        catch { throw SkillExecutionError.workerFailed }
    }

    private func decode(_ body: Data, requestID: String, input: Data, options: SkillExecutionPDFOptions) throws -> SkillExecutionPDFResult {
        guard let response = try? JSONDecoder().decode(Response.self, from: body), response.version == 1,
              response.requestID == requestID, response.scriptSHA256 == Self.scriptSHA256,
              response.revision == BundledSkillCatalog.pinnedCommit, response.inputSHA256 == skillExecutionDigest(input) else {
            throw SkillExecutionError.invalidWorkerResponse
        }
        if let failure = response.error {
            switch failure {
            case "invalidPDF": throw SkillExecutionError.invalidPDF
            case "passwordRequired": throw SkillExecutionError.passwordRequired
            case "invalidPages": throw SkillExecutionError.invalidPages
            case "outputTooLarge": throw SkillExecutionError.outputTooLarge
            default: throw SkillExecutionError.workerFailed
            }
        }
        guard let count = response.pageCount, count > 0, count <= 100_000,
              let pages = response.pages, let metadata = response.metadata,
              let emptyPages = response.emptyPages else { throw SkillExecutionError.invalidWorkerResponse }
        let expected = options.metadataOnly ? [] : try SkillExecutionPageRange.parse(options.pages, pageCount: count)
        guard pages.map(\.number) == expected, emptyPages == pages.filter({ $0.text.isEmpty }).map(\.number),
              pages.reduce(0, { $0 + $1.text.utf8.count + 32 }) + metadata.reduce(0, { $0 + $1.key.utf8.count + $1.value.utf8.count }) <= SkillExecutionLimits.outputBytes else {
            throw SkillExecutionError.invalidWorkerResponse
        }
        return SkillExecutionPDFResult(pageCount: count, pages: pages.map { .init(number: $0.number, text: $0.text) },
            metadata: metadata, emptyPages: emptyPages, inputSHA256: response.inputSHA256,
            engine: "Mika extract_pdf.py / pypdf", originalScriptSHA256: response.scriptSHA256)
    }

    private struct Response: Decodable {
        let version: Int
        let requestID: String
        let revision: String
        let scriptSHA256: String
        let inputSHA256: String
        let error: String?
        let pageCount: Int?
        let pages: [Page]?
        let metadata: [String: String]?
        let emptyPages: [Int]?
        struct Page: Decodable { let number: Int; let text: String }
    }
}

private final class SkillExecutionNoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
