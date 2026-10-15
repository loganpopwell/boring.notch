import Foundation

/// Reads subscription quota for the AI tools. Claude accounts come from the local CLIProxyAPI management API;
/// native Codex limits come from rate-limit metadata in Codex session files. The management key is read
/// from its owner-only file and sent only to 127.0.0.1. No credentials, prompts, or content are decoded.
final class AIStatusReader: @unchecked Sendable {
    static let shared = AIStatusReader()
    private let lock = NSLock()
    private var details: [String: (at: Date, windows: [NotchQuotaWindow])] = [:]
    private let home: URL

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) { self.home = home }

    struct ProxyConfig { let base: URL; let key: String }

    static func proxyConfig(home: URL) -> ProxyConfig? {
        let folder = home.appendingPathComponent(".config/cliproxyapi")
        guard let keyData = try? Data(contentsOf: folder.appendingPathComponent("management-key")), keyData.count <= 4096,
              let key = String(data: keyData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty, !key.contains("\n") else { return nil }
        var port = 8317
        if let data = try? Data(contentsOf: folder.appendingPathComponent("config.yaml")), data.count <= 1_000_000,
           let text = String(data: data, encoding: .utf8),
           let match = text.range(of: #"(?m)^port:\s*"?(\d{2,5})"?\s*$"#, options: .regularExpression) {
            port = Int(text[match].filter(\.isNumber)) ?? port
        }
        guard (1...65535).contains(port), let base = URL(string: "http://127.0.0.1:\(port)/v0/management/") else { return nil }
        return ProxyConfig(base: base, key: key)
    }

    // MARK: - Proxy management API

    private struct AuthFiles: Decodable { let files: [File] }
    private struct File: Decodable {
        let auth_index: String?
        let type: String?
        let provider: String?
        let email: String?
        let label: String?
        let priority: Int?
        let disabled: Bool?
        let unavailable: Bool?
        let status: String?
        let status_message: String?
        let success: Int64?
        let failed: Int64?
        let quota: Quota?
        let recent_requests: [Bucket]?
        let cooldowns: [Lenient]?
    }
    private struct Quota: Decodable { let observed_at: String?; let signals: [String: Lenient]? }
    private struct Bucket: Decodable { let success: Int?; let failed: Int? }
    /// Accepts any JSON value and keeps it only when it is a string or number.
    struct Lenient: Decodable {
        let text: String?
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            text = (try? c.decode(String.self)) ?? (try? c.decode(Double.self)).map { String($0) }
        }
    }

    private static func request(_ url: URL, key: String, body: Data? = nil, timeout: TimeInterval) -> (Int, Data)? {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        if let body {
            request.httpMethod = "POST"; request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout; config.timeoutIntervalForResource = timeout
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.connectionProxyDictionary = [:]
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        let done = DispatchSemaphore(value: 0)
        var result: (Int, Data)?
        session.dataTask(with: request) { data, response, _ in
            if let status = (response as? HTTPURLResponse)?.statusCode, let data, data.count <= 20_000_000 { result = (status, data) }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + timeout + 1)
        return result
    }

    static func parseDate(_ value: String?) -> Date? {
        guard var value else { return nil }
        // Go timestamps carry microseconds; Foundation's ISO parser accepts at most milliseconds reliably.
        value = value.replacingOccurrences(of: #"(\.\d{3})\d+"#, with: "$1", options: .regularExpression)
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: value)
    }

    static func windowTitle(_ id: String) -> String {
        switch id {
        case "five_hour": return "5-hour"
        case "seven_day": return "Weekly"
        default:
            let scope = id.replacingOccurrences(of: "seven_day_", with: "").replacingOccurrences(of: "weekly_", with: "")
            return "Weekly · " + scope.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// Windows from the rate-limit headers the proxy records on every Claude response. Free to read.
    static func signalWindows(_ signals: [String: String], now: Date) -> [NotchQuotaWindow] {
        var lower: [String: String] = [:]
        for (key, value) in signals { lower[key.lowercased()] = value }
        let prefix = "anthropic-ratelimit-unified-"
        var windows: [NotchQuotaWindow] = []
        for (key, value) in lower where key.hasPrefix(prefix) && key.hasSuffix("-utilization") {
            let claim = String(key.dropFirst(prefix.count).dropLast("-utilization".count))
            guard !claim.isEmpty, claim.count <= 40, let fraction = Double(value), fraction.isFinite else { continue }
            let id = claim == "5h" ? "five_hour" : claim == "7d" ? "seven_day" : "seven_day_" + claim.replacingOccurrences(of: "7d_", with: "")
            var reset = lower[prefix + claim + "-reset"].flatMap(Double.init).map { Date(timeIntervalSince1970: $0) }
            var percent = min(100, max(0, fraction * 100))
            // A recorded window that has already reset says nothing about the new one.
            if let date = reset, date <= now { percent = 0; reset = nil }
            let limited = reset != nil && lower[prefix + claim + "-status"] == "rejected"
            windows.append(NotchQuotaWindow(id: id, title: windowTitle(id), percent: percent, resetsAt: reset, limited: limited))
        }
        return windows.sorted { order($0.id) < order($1.id) }
    }
    private static func order(_ id: String) -> Int { id == "five_hour" ? 0 : id == "seven_day" ? 1 : 2 }

    /// Windows from Anthropic's usage endpoint, read through the proxy with each account's own login.
    static func usageWindows(_ data: Data, now: Date) -> [NotchQuotaWindow]? {
        struct Usage: Decodable {
            struct Window: Decodable { let utilization: Double?; let resets_at: String? }
            struct Limit: Decodable {
                struct Scope: Decodable { struct Model: Decodable { let display_name: String? }; let model: Model? }
                let kind: String?; let group: String?; let percent: Double?; let resets_at: String?; let scope: Scope?
            }
            let five_hour: Window?
            let seven_day: Window?
            let limits: [Limit]?
        }
        guard let usage = try? JSONDecoder().decode(Usage.self, from: data) else { return nil }
        var windows: [NotchQuotaWindow] = []
        func add(_ id: String, _ percent: Double?, _ reset: String?) {
            guard let percent, percent.isFinite, !windows.contains(where: { $0.id == id }) else { return }
            var date = parseDate(reset), value = min(100, max(0, percent))
            if let reset = date, reset <= now { value = 0; date = nil }
            windows.append(NotchQuotaWindow(id: id, title: windowTitle(id), percent: value, resetsAt: date, limited: value >= 100))
        }
        for limit in usage.limits ?? [] {
            switch limit.kind {
            case "session": add("five_hour", limit.percent, limit.resets_at)
            case "weekly_all", "weekly": add("seven_day", limit.percent, limit.resets_at)
            case "weekly_scoped":
                let name = (limit.scope?.model?.display_name ?? "model").lowercased().filter { $0.isLetter || $0.isNumber || $0 == " " }
                add("seven_day_" + name.replacingOccurrences(of: " ", with: "_"), limit.percent, limit.resets_at)
            default: continue
            }
        }
        add("five_hour", usage.five_hour?.utilization, usage.five_hour?.resets_at)
        add("seven_day", usage.seven_day?.utilization, usage.seven_day?.resets_at)
        return windows.sorted { order($0.id) < order($1.id) }
    }

    private func fetchUsage(_ index: String, config: ProxyConfig, now: Date) -> [NotchQuotaWindow]? {
        let body: [String: Any] = ["authIndex": index, "method": "GET", "url": "https://api.anthropic.com/api/oauth/usage",
            "header": ["Authorization": "Bearer $TOKEN$", "anthropic-beta": "oauth-2025-04-20",
                       "Accept": "application/json", "User-Agent": "claude-cli/2.1.280 (external, cli)"]]
        guard let data = try? JSONSerialization.data(withJSONObject: body),
              let (status, reply) = Self.request(config.base.appendingPathComponent("api-call"), key: config.key, body: data, timeout: 25),
              status == 200 else { return nil }
        struct Envelope: Decodable { let status_code: Int?; let body: Lenient? }
        // The proxy wraps the upstream reply; its body is a JSON string or object.
        if let envelope = try? JSONDecoder().decode(Envelope.self, from: reply), envelope.status_code == 200,
           let text = envelope.body?.text { return Self.usageWindows(Data(text.utf8), now: now) }
        if let object = try? JSONSerialization.jsonObject(with: reply) as? [String: Any], object["status_code"] as? Int == 200,
           let inner = object["body"], JSONSerialization.isValidJSONObject(inner),
           let data = try? JSONSerialization.data(withJSONObject: inner) { return Self.usageWindows(data, now: now) }
        return nil
    }

    static func accounts(from data: Data, now: Date) throws -> [NotchQuotaAccount] {
        let files = try JSONDecoder().decode(AuthFiles.self, from: data).files
        guard files.count <= 500 else { throw TokenUsageReader.InvalidHistory.invalid }
        return files.compactMap { file in
            guard (file.type ?? file.provider) == "claude", let index = file.auth_index, index.count <= 100 else { return nil }
            let email = file.email ?? file.label ?? index
            var account = NotchQuotaAccount(id: index, provider: "claude",
                label: String(email.split(separator: "@").first ?? Substring(email)).prefix(40).description,
                priority: file.priority)
            var signals: [String: String] = [:]
            for (key, value) in file.quota?.signals ?? [:] { if let text = value.text { signals[key] = text } }
            account.windows = signalWindows(signals, now: now)
            account.observedAt = parseDate(file.quota?.observed_at)
            account.successes = max(0, file.success ?? 0); account.failures = max(0, file.failed ?? 0)
            account.recentRequests = (file.recent_requests ?? []).suffix(3).reduce(0) { $0 + max(0, $1.success ?? 0) + max(0, $1.failed ?? 0) }
            if file.disabled == true { account.state = "disabled" }
            else if file.unavailable == true || !(file.cooldowns ?? []).isEmpty { account.state = "cooldown" }
            else if let status = file.status, !status.isEmpty, status != "active" {
                account.state = "error"; account.message = (file.status_message?.isEmpty == false ? file.status_message : status)?.prefix(160).description
            }
            if account.state == "ok", account.windows.contains(where: { $0.limited || $0.percent >= 100 }) { account.state = "limited" }
            return account
        }
    }

    // MARK: - Native Codex

    /// The newest rate-limit report in recent Codex session files. Only `token_count` lines are decoded.
    static func codexAccount(home: URL, now: Date) -> NotchQuotaAccount? {
        struct Line: Decodable {
            struct Payload: Decodable {
                struct Limits: Decodable {
                    struct Window: Decodable { let used_percent: Double?; let window_minutes: Int?; let resets_at: Double? }
                    let primary: Window?; let secondary: Window?; let plan_type: String?; let rate_limit_reached_type: String?
                }
                let type: String?; let rate_limits: Limits?
            }
            let timestamp: String?; let payload: Payload?
        }
        let calendar = Calendar(identifier: .gregorian)
        var files: [(URL, Date)] = []
        for offset in 0..<3 {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: now) else { continue }
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            let folder = home.appendingPathComponent(String(format: ".codex/sessions/%04d/%02d/%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0))
            let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for url in urls where url.pathExtension == "jsonl" {
                files.append((url, (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast))
            }
        }
        var best: (Date, Line.Payload.Limits)?
        for (url, _) in files.sorted(by: { $0.1 > $1.1 }).prefix(6) {
            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? handle.close() }
            let size = (try? handle.seekToEnd()) ?? 0
            try? handle.seek(toOffset: size > 1_000_000 ? size - 1_000_000 : 0)
            guard let data = try? handle.readToEnd() else { continue }
            for line in data.split(separator: 10).reversed() {
                guard line.count <= 20_000, let text = String(data: Data(line), encoding: .utf8),
                      text.contains("\"rate_limits\""), text.contains("\"token_count\""),
                      let value = try? JSONDecoder().decode(Line.self, from: Data(line)),
                      value.payload?.type == "token_count", let limits = value.payload?.rate_limits,
                      let date = parseDate(value.timestamp) else { continue }
                if best == nil || date > best!.0 { best = (date, limits) }
                break
            }
        }
        guard let (date, limits) = best else { return nil }
        var account = NotchQuotaAccount(id: "codex-native", provider: "codex", label: "Codex")
        account.observedAt = date
        for window in [limits.primary, limits.secondary].compactMap({ $0 }) {
            guard let percent = window.used_percent, percent.isFinite, let minutes = window.window_minutes, minutes > 0 else { continue }
            let id = minutes == 300 ? "five_hour" : minutes == 10080 ? "seven_day" : "window_\(minutes)"
            var reset = window.resets_at.map { Date(timeIntervalSince1970: $0) }, value = min(100, max(0, percent))
            if let date = reset, date <= now { value = 0; reset = nil }
            account.windows.append(NotchQuotaWindow(id: id, title: id.hasPrefix("window_") ? "\(minutes / 60)-hour" : windowTitle(id),
                percent: value, resetsAt: reset, limited: value >= 100))
        }
        account.windows.sort { order($0.id) < order($1.id) }
        if limits.rate_limit_reached_type != nil || account.windows.contains(where: \.limited) { account.state = "limited" }
        return account
    }

    // MARK: - Restart

    /// The LaunchAgent that runs CLIProxyAPI, found by its program path rather than a hardcoded label.
    static func launchAgentLabel(home: URL) -> String? {
        let folder = home.appendingPathComponent("Library/LaunchAgents")
        let plists = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for url in plists where url.pathExtension == "plist" {
            guard let data = try? Data(contentsOf: url), data.count <= 200_000,
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let label = plist["Label"] as? String else { continue }
            let program = [plist["Program"] as? String, (plist["ProgramArguments"] as? [String])?.first].compactMap { $0 }
            if program.contains(where: { URL(fileURLWithPath: $0).lastPathComponent.lowercased() == "cliproxyapi" }) { return label }
        }
        return nil
    }

    func restartProxy() -> Bool {
        guard let label = Self.launchAgentLabel(home: home) else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["kickstart", "-k", "gui/\(getuid())/\(label)"]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        lock.lock(); details = [:]; lock.unlock()
        return process.terminationStatus == 0
    }

    // MARK: - Sample

    /// `detailed` also asks Anthropic for each account's full limits, at most every two minutes.
    func sample(detailed: Bool, now: Date = Date()) -> NotchAIStatus {
        var status = NotchAIStatus(sampledAt: now)
        status.restartAvailable = Self.launchAgentLabel(home: home) != nil
        if let config = Self.proxyConfig(home: home) {
            status.proxyConfigured = true
            if let (code, data) = Self.request(config.base.appendingPathComponent("auth-files"), key: config.key, timeout: 5) {
                if code == 200, var accounts = try? Self.accounts(from: data, now: now) {
                    status.proxyReachable = true
                    if detailed { refreshDetails(accounts.filter { $0.state != "disabled" }.map(\.id), config: config, now: now) }
                    lock.lock(); let cached = details; lock.unlock()
                    for index in accounts.indices {
                        // Full limits stay valid for ten minutes; the headers keep the 5-hour reading current.
                        guard let detail = cached[accounts[index].id], now.timeIntervalSince(detail.at) < 600 else { continue }
                        var windows = detail.windows
                        if let live = accounts[index].session, let observed = accounts[index].observedAt, observed > detail.at,
                           let slot = windows.firstIndex(where: { $0.id == "five_hour" }) { windows[slot] = live }
                        accounts[index].windows = windows; accounts[index].detailed = true
                        if accounts[index].state == "ok", windows.contains(where: { $0.limited }) { accounts[index].state = "limited" }
                        status.detailedAt = max(status.detailedAt ?? .distantPast, detail.at)
                    }
                    accounts.sort { ($0.priority ?? Int.min, $1.label) > ($1.priority ?? Int.min, $0.label) }
                    status.accounts = accounts
                    status.lastUsedID = accounts.filter { $0.observedAt != nil }.max { $0.observedAt! < $1.observedAt! }?.id
                    status.nextID = accounts.first { $0.usable }?.id
                } else {
                    status.proxyError = code == 401 || code == 403 ? "CLI Proxy rejected the management key" : "CLI Proxy returned HTTP \(code)"
                }
            } else { status.proxyError = "CLI Proxy is not responding" }
        }
        if let codex = Self.codexAccount(home: home, now: now) { status.accounts.append(codex) }
        return status
    }

    private func refreshDetails(_ indexes: [String], config: ProxyConfig, now: Date) {
        lock.lock()
        let due = indexes.filter { details[$0].map { now.timeIntervalSince($0.at) > 120 } ?? true }
        lock.unlock()
        guard !due.isEmpty else { return }
        let group = DispatchGroup()
        for index in due.prefix(20) {
            group.enter()
            DispatchQueue.global(qos: .utility).async { [self] in
                defer { group.leave() }
                guard let windows = fetchUsage(index, config: config, now: now) else { return }
                lock.lock(); details[index] = (now, windows); lock.unlock()
            }
        }
        _ = group.wait(timeout: .now() + 30)
    }
}
