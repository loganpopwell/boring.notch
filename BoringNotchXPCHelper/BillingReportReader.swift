import Foundation

/// Reads the LumaCore billing report from the dashboard's read-only notch feed. The billing-scoped key is read
/// from an owner-only file and sent only to the dashboard over HTTPS; redirects are refused so it can't leak.
final class BillingReportReader: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = BillingReportReader()
    static let endpoint = URL(string: "https://app.lumacoredesign.com/api/internal/billing/notch")!
    private let lock = NSLock()
    private var last: (report: NotchBillingReport, at: Date)?
    private let home: URL

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) { self.home = home }

    static func keyFile(home: URL) -> URL { home.appendingPathComponent(".config/lumacore/notch-billing-key") }

    /// The key, only when the file is owned by this user and unreadable by anyone else.
    static func readKey(home: URL) -> String? {
        let file = keyFile(home: home)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue, mode & 0o077 == 0,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              let data = try? Data(contentsOf: file), data.count <= 512,
              let key = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty, key.allSatisfy({ $0.isASCII && !$0.isWhitespace }) else { return nil }
        return key
    }

    func sample() -> NotchBillingStatus {
        var status = NotchBillingStatus()
        lock.lock(); status.report = last?.report; status.fetchedAt = last?.at; lock.unlock()
        guard let key = Self.readKey(home: home) else { status.problem = .missingKey; return status }

        var request = URLRequest(url: Self.endpoint, timeoutInterval: 30)
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 45
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.urlCache = nil
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let done = DispatchSemaphore(value: 0)
        var result: (Int, Data)?
        session.dataTask(with: request) { data, response, _ in
            if let code = (response as? HTTPURLResponse)?.statusCode, let data, data.count <= 2_000_000 { result = (code, data) }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 46)

        switch result {
        case nil: status.problem = .offline
        case let (code, _)? where code == 401 || code == 403: status.problem = .unauthorized
        case let (200, data)?:
            if let report = try? NotchBillingReport.decode(data) {
                let now = Date()
                lock.lock(); last = (report, now); lock.unlock()
                status.report = report; status.fetchedAt = now
            } else { status.problem = .unavailable }
        default: status.problem = .unavailable
        }
        return status
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
