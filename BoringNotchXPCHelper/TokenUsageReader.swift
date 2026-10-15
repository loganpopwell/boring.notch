import Foundation

/// Decodes only aggregate token fields from AI Token Meter, never credentials or raw conversations.
struct TokenUsageReader {
    struct History: Decodable {
        let version: Int
        let localCodexByDay: [String: Day]
        let machine: Machine
        let latestAccountUsage: Account?
        let updatedAt: Date?
    }
    struct Machine: Codable { let timeZoneIdentifier: String }
    struct Account: Decodable {
        struct Summary: Decodable { let lifetimeTokens: Int64 }
        let summary: Summary
        let readAt: Date
    }
    struct Usage: Codable {
        let input: Int64
        let cachedInput: Int64
        let output: Int64
        let total: Int64
        var cacheCreationInput: Int64? = nil
        var cacheCreationInput1h: Int64? = nil
    }
    struct ModelUsage: Codable { let name: String; let usage: Usage }
    struct Day: Codable {
        let day: String
        let usage: Usage
        let apiEquivalentUSD: Double
        let apiEquivalentPricedTokens: Int64
        let lastObservedAt: Date
        var modelBreakdown: [ModelUsage]? = nil
    }
    enum InvalidHistory: Error { case unsupported, invalid }

    static func decode(_ data: Data, now: Date = Date(), pricing: [String: NotchTokenRate]? = nil, provider: String = "codex") throws -> NotchTokenSnapshot {
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
        func accumulate(_ day: Day, models: [NotchTokenModel], into period: inout NotchTokenPeriod) {
            period.tokens += day.usage.total
            period.input += day.usage.input
            period.cached += day.usage.cachedInput
            period.output += day.usage.output
            period.estimatedUSD += pricing == nil ? day.apiEquivalentUSD : models.reduce(0) { $0 + $1.estimatedUSD }
            period.pricedTokens += pricing == nil ? min(day.usage.total, day.apiEquivalentPricedTokens) : models.reduce(0) { $0 + $1.pricedTokens }
            var value = NotchTokenPeriod(id: "models", title: "Models")
            value.models = models
            period.add(value)
        }
        for (key, day) in history.localCodexByDay {
            guard key == day.day, let date = formatter.date(from: key), formatter.string(from: date) == key,
                  day.usage.total >= 0, day.usage.total <= 1_000_000_000_000_000,
                  day.usage.input >= 0, day.usage.input <= day.usage.total,
                  day.usage.cachedInput >= 0, day.usage.cachedInput <= 1_000_000_000_000_000,
                  day.usage.output >= 0, day.usage.output <= day.usage.total,
                  day.apiEquivalentUSD.isFinite, day.apiEquivalentUSD >= 0,
                  day.apiEquivalentPricedTokens >= 0 else { throw InvalidHistory.invalid }
            guard valid(day.usage) else { throw InvalidHistory.invalid }
            guard key <= today else { continue }
            cacheCountsInconsistent = cacheCountsInconsistent || day.usage.cachedInput > day.usage.input
            let rows = try modelRows(day, provider: provider, pricing: pricing ?? [:])
            let monthKey = String(key.prefix(7))
            if key == today { accumulate(day, models: rows, into: &periods[0]) }
            if monthKey == month { accumulate(day, models: rows, into: &periods[1]) }
            accumulate(day, models: rows, into: &periods[2])
            var bucket = months[monthKey] ?? NotchTokenPeriod(id: monthKey, title: monthKey)
            accumulate(day, models: rows, into: &bucket); months[monthKey] = bucket
            observed = max(observed ?? .distantPast, day.lastObservedAt)
            firstDay = min(firstDay ?? key, key)
        }
        guard periods[2].tokens <= 1_000_000_000_000_000_000,
              periods[2].cached <= 1_000_000_000_000_000_000 else { throw InvalidHistory.invalid }
        return NotchTokenSnapshot(periods: periods, months: months.values.sorted { $0.id > $1.id },
            sampledAt: history.updatedAt ?? observed ?? .distantPast, firstDay: firstDay,
            accountLifetimeTokens: history.latestAccountUsage?.summary.lifetimeTokens,
            accountReadAt: history.latestAccountUsage?.readAt,
            cacheCountsInconsistent: cacheCountsInconsistent,
            error: history.localCodexByDay.isEmpty ? "No local usage recorded yet. Open AI Token Meter to scan history." : nil)
    }

    private static func modelRows(_ day: Day, provider: String, pricing: [String: NotchTokenRate]) throws -> [NotchTokenModel] {
        let breakdown = day.modelBreakdown ?? []
        guard breakdown.count <= 1000 else { throw InvalidHistory.invalid }
        var rows: [String: NotchTokenModel] = [:]
        var accounted = Usage(input: 0, cachedInput: 0, output: 0, total: 0, cacheCreationInput: 0, cacheCreationInput1h: 0)
        for model in breakdown {
            let u = model.usage
            guard model.name.count <= 200, valid(u), u.total <= day.usage.total else { throw InvalidHistory.invalid }
            var row = NotchTokenModel(provider: provider, name: model.name, vendor: TokenPricingCatalog.vendor(for: model.name),
                tokens: u.total, input: u.input, cached: u.cachedInput, output: u.output,
                write5m: u.cacheCreationInput ?? 0, write1h: u.cacheCreationInput1h ?? 0)
            row.price(using: TokenPricingCatalog.resolve(model.name, provider: provider, rates: pricing))
            if let old = rows[row.id] { row.add(old) }
            rows[row.id] = row
            accounted = Usage(input: accounted.input + u.input, cachedInput: accounted.cachedInput + u.cachedInput,
                output: accounted.output + u.output, total: accounted.total + u.total,
                cacheCreationInput: (accounted.cacheCreationInput ?? 0) + (u.cacheCreationInput ?? 0),
                cacheCreationInput1h: (accounted.cacheCreationInput1h ?? 0) + (u.cacheCreationInput1h ?? 0))
            guard accounted.total <= day.usage.total else { throw InvalidHistory.invalid }
        }
        if accounted.total < day.usage.total {
            let row = NotchTokenModel(provider: provider, name: "Unattributed model",
                vendor: provider == "codex" ? "openai" : "unknown", tokens: day.usage.total - accounted.total,
                input: max(0, day.usage.input - accounted.input), cached: max(0, day.usage.cachedInput - accounted.cachedInput),
                output: max(0, day.usage.output - accounted.output),
                write5m: max(0, (day.usage.cacheCreationInput ?? 0) - (accounted.cacheCreationInput ?? 0)),
                write1h: max(0, (day.usage.cacheCreationInput1h ?? 0) - (accounted.cacheCreationInput1h ?? 0)))
            rows[row.id] = row
        }
        return rows.values.filter { $0.tokens > 0 }.sorted { $0.tokens > $1.tokens }
    }
    private static func valid(_ u: Usage) -> Bool {
        let limit: Int64 = 1_000_000_000_000_000
        return (0...limit).contains(u.total) && (0...u.total).contains(u.input) && (0...u.total).contains(u.output)
            && (0...limit).contains(u.cachedInput) && (0...limit).contains(u.cacheCreationInput ?? 0)
            && (0...limit).contains(u.cacheCreationInput1h ?? 0)
    }

    struct ClaudeHistory: Encodable {
        let version = 1
        let machine: Machine
        let localCodexByDay: [String: Day]
        let updatedAt: Date
    }

    private func read(_ file: URL, limit: Int) throws -> Data {
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= limit else { throw InvalidHistory.invalid }
        let data = try Data(contentsOf: file)
        guard data.count <= limit else { throw InvalidHistory.invalid }
        return data
    }

    func sample() -> NotchTokenSnapshot {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Codex Token Meter")
        TokenPricingCatalog.shared.refreshIfNeeded()
        let pricing = TokenPricingCatalog.shared.snapshot()
        var value: NotchTokenSnapshot
        var timeZone = TimeZone.current
        do {
            let data = try read(directory.appendingPathComponent("machine-usage-history.json"), limit: 10_000_000)
            value = try Self.decode(data, pricing: pricing)
            // Read only the timezone in addition to the already decoded Codex aggregates.
            if let history = try? JSONDecoder().decode(TimeZoneOnly.self, from: data) {
                timeZone = TimeZone(identifier: history.machine.timeZoneIdentifier) ?? .current
            }
        } catch {
            value = NotchTokenSnapshot(periods: [], months: [], sampledAt: .distantPast,
                error: "Codex history is unavailable. Open AI Token Meter to refresh its local report.")
        }
        value.claude = ClaudeLocalUsageReader.shared.sample(timeZone: timeZone, pricing: pricing)
        return value
    }
    private struct TimeZoneOnly: Decodable { let machine: Machine }
}
