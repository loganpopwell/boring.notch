import Foundation

/// Reads only AI Token Meter's aggregate report, never credentials or raw conversations.
struct TokenUsageReader {
    struct History: Decodable {
        let version: Int
        let localCodexByDay: [String: Day]
        let machine: Machine
        let latestAccountUsage: Account?
    }
    struct Machine: Decodable { let timeZoneIdentifier: String }
    struct Account: Decodable {
        struct Summary: Decodable { let lifetimeTokens: Int64 }
        let summary: Summary
        let readAt: Date
    }
    struct Usage: Decodable {
        let input: Int64
        let cachedInput: Int64
        let output: Int64
        let total: Int64
    }
    struct Day: Decodable {
        let day: String
        let usage: Usage
        let apiEquivalentUSD: Double
        let apiEquivalentPricedTokens: Int64
        let lastObservedAt: Date
    }
    enum InvalidHistory: Error { case unsupported, invalid }

    static func decode(_ data: Data, now: Date = Date()) throws -> NotchTokenSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter()
            if let date = formatter.date(from: value) { return date }
            formatter.formatOptions.insert(.withFractionalSeconds)
            guard let date = formatter.date(from: value) else { throw InvalidHistory.invalid }
            return date
        }
        let history = try decoder.decode(History.self, from: data)
        guard history.version == 1 else { throw InvalidHistory.unsupported }
        guard history.localCodexByDay.count <= 5000 else { throw InvalidHistory.invalid }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: history.machine.timeZoneIdentifier) ?? .current
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        let today = formatter.string(from: now)
        let month = String(today.prefix(7))
        var periods = [NotchTokenPeriod(id: "today", title: "Today"), NotchTokenPeriod(id: "month", title: "This month"), NotchTokenPeriod(id: "lifetime", title: "Lifetime")]
        var months: [String: NotchTokenPeriod] = [:]
        var observed: Date?
        var firstDay: String?
        var cacheCountsInconsistent = false
        func accumulate(_ day: Day, into period: inout NotchTokenPeriod) {
            period.tokens += day.usage.total
            period.input += day.usage.input
            period.cached += day.usage.cachedInput
            period.output += day.usage.output
            period.estimatedUSD += day.apiEquivalentUSD
            period.pricedTokens += min(day.usage.total, day.apiEquivalentPricedTokens)
        }
        for (key, day) in history.localCodexByDay {
            guard key == day.day, let date = formatter.date(from: key), formatter.string(from: date) == key,
                  day.usage.total >= 0, day.usage.total <= 1_000_000_000_000_000,
                  day.usage.input >= 0, day.usage.input <= day.usage.total,
                  day.usage.cachedInput >= 0, day.usage.cachedInput <= 1_000_000_000_000_000,
                  day.usage.output >= 0, day.usage.output <= day.usage.total,
                  day.apiEquivalentUSD.isFinite, day.apiEquivalentUSD >= 0,
                  day.apiEquivalentPricedTokens >= 0 else { throw InvalidHistory.invalid }
            guard key <= today else { continue }
            cacheCountsInconsistent = cacheCountsInconsistent || day.usage.cachedInput > day.usage.input
            let monthKey = String(key.prefix(7))
            if key == today { accumulate(day, into: &periods[0]) }
            if monthKey == month { accumulate(day, into: &periods[1]) }
            accumulate(day, into: &periods[2])
            var bucket = months[monthKey] ?? NotchTokenPeriod(id: monthKey, title: monthKey)
            accumulate(day, into: &bucket); months[monthKey] = bucket
            observed = max(observed ?? .distantPast, day.lastObservedAt)
            firstDay = min(firstDay ?? key, key)
        }
        return NotchTokenSnapshot(periods: periods, months: months.values.sorted { $0.id > $1.id },
            sampledAt: observed ?? .distantPast, firstDay: firstDay,
            accountLifetimeTokens: history.latestAccountUsage?.summary.lifetimeTokens,
            accountReadAt: history.latestAccountUsage?.readAt,
            cacheCountsInconsistent: cacheCountsInconsistent,
            error: history.localCodexByDay.isEmpty ? "No local usage recorded yet. Open AI Token Meter to scan history." : nil)
    }

    func sample() -> NotchTokenSnapshot {
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Codex Token Meter/machine-usage-history.json")
        do {
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size < 10_000_000 else { throw InvalidHistory.invalid }
            return try Self.decode(Data(contentsOf: file))
        } catch {
            return NotchTokenSnapshot(periods: [], months: [], sampledAt: Date(),
                error: "AI Token Meter history is unavailable. Open the meter to refresh its local report.")
        }
    }
}
