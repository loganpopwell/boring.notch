import Foundation

/// One rate-limit window, such as a 5-hour session or a weekly allowance. `percent` is 0-100.
struct NotchQuotaWindow: Codable, Identifiable, Equatable {
    var id: String
    var title: String
    var percent: Double
    var resetsAt: Date?
    var limited = false
}

/// One subscription account: a Claude login pooled by CLIProxy, or native Codex.
struct NotchQuotaAccount: Codable, Identifiable, Equatable {
    var id: String
    var provider: String
    var label: String
    var priority: Int?
    /// "ok", "limited", "cooldown", "disabled", or "error".
    var state = "ok"
    var message: String?
    var windows: [NotchQuotaWindow] = []
    /// When this account last answered a request through the proxy.
    var observedAt: Date?
    var detailed = false
    var successes: Int64 = 0
    var failures: Int64 = 0
    /// Requests in the proxy's most recent activity buckets.
    var recentRequests = 0

    /// The window closest to blocking requests. A full weekly allowance blocks even with 5-hour room left.
    var tightest: NotchQuotaWindow? { windows.max { $0.percent < $1.percent } }
    var session: NotchQuotaWindow? { windows.first { $0.id == "five_hour" } }
    var usable: Bool { state == "ok" }
}

struct NotchAIStatus: Codable, Equatable {
    var proxyConfigured = false
    var proxyReachable = false
    var proxyError: String?
    var accounts: [NotchQuotaAccount] = []
    /// The account that most recently answered a request through the proxy.
    var lastUsedID: String?
    /// The account a new session would get: highest priority among usable accounts.
    var nextID: String?
    var restartAvailable = false
    var sampledAt = Date.distantPast
    var detailedAt: Date?

    var claudeAccounts: [NotchQuotaAccount] { accounts.filter { $0.provider == "claude" } }
    var codex: NotchQuotaAccount? { accounts.first { $0.provider == "codex" } }
    var lastUsed: NotchQuotaAccount? { accounts.first { $0.id == lastUsedID } }
    var next: NotchQuotaAccount? { accounts.first { $0.id == nextID } }
    /// The account the closed-notch ring follows.
    var ringAccount: NotchQuotaAccount? { lastUsed ?? next ?? codex }
}
