import Foundation

struct NotchTokenPeriod: Codable, Identifiable {
    var id: String
    var title: String
    var tokens: Int64 = 0
    var input: Int64 = 0
    var cached: Int64 = 0
    var output: Int64 = 0
    var estimatedUSD: Double = 0
    var pricedTokens: Int64 = 0
    var models: [NotchTokenModel] = []
    var coverage: Double { tokens > 0 ? min(1, Double(pricedTokens) / Double(tokens)) : 1 }

    mutating func add(_ other: Self) {
        tokens += other.tokens; input += other.input; cached += other.cached; output += other.output
        estimatedUSD += other.estimatedUSD; pricedTokens += other.pricedTokens
        for model in other.models {
            if let index = models.firstIndex(where: { $0.id == model.id }) { models[index].add(model) }
            else { models.append(model) }
        }
        models.sort { $0.tokens > $1.tokens }
    }
}

struct NotchTokenSnapshot: Codable {
    var periods: [NotchTokenPeriod]
    var months: [NotchTokenPeriod]
    var sampledAt: Date
    var firstDay: String?
    var accountLifetimeTokens: Int64?
    var accountReadAt: Date?
    var cacheCountsInconsistent = false
    var error: String?
    var claude: NotchTokenSource?

    func source(_ id: String) -> NotchTokenSource {
        let codex = NotchTokenSource(periods: periods, months: months, sampledAt: sampledAt,
            cacheCountsInconsistent: cacheCountsInconsistent, error: error)
        if id == "codex" { return codex }
        let claude = claude ?? NotchTokenSource(periods: [], months: [], sampledAt: .distantPast,
            error: "Local Claude Code history is unavailable.")
        if id == "claude" { return claude }
        let available = [codex, claude].filter { $0.error == nil }
        guard !available.isEmpty else { return codex }
        var periods = available[0].periods
        var months: [String: NotchTokenPeriod] = [:]
        for source in available {
            for month in source.months {
                var bucket = months[month.id] ?? NotchTokenPeriod(id: month.id, title: month.title)
                bucket.add(month); months[month.id] = bucket
            }
        }
        for source in available.dropFirst() {
            for index in periods.indices {
                if let other = source.periods.first(where: { $0.id == periods[index].id }) { periods[index].add(other) }
            }
        }
        return NotchTokenSource(periods: periods, months: months.values.sorted { $0.id > $1.id },
            sampledAt: available.map(\.sampledAt).min() ?? .distantPast,
            cacheCountsInconsistent: available.contains { $0.cacheCountsInconsistent },
            notice: available.count < 2 ? "Partial total: \(codex.error == nil ? "Claude Code" : "Codex") unavailable"
                : available.compactMap(\.notice).isEmpty ? nil : available.compactMap(\.notice).joined(separator: " · "))
    }
}

struct NotchTokenSource: Codable {
    var periods: [NotchTokenPeriod]
    var months: [NotchTokenPeriod]
    var sampledAt: Date
    var cacheCountsInconsistent = false
    var error: String?
    var notice: String?

    /// Only usage from one model maker, with totals rebuilt from the matching model rows.
    func filtered(vendor: String) -> NotchTokenSource {
        func keep(_ period: NotchTokenPeriod) -> NotchTokenPeriod {
            var value = NotchTokenPeriod(id: period.id, title: period.title)
            for model in period.models where model.vendor == vendor {
                value.tokens += model.tokens; value.input += model.input; value.cached += model.cached
                value.output += model.output; value.estimatedUSD += model.estimatedUSD; value.pricedTokens += model.pricedTokens
                value.models.append(model)
            }
            return value
        }
        var value = self
        value.periods = periods.map(keep)
        value.months = months.map(keep).filter { $0.tokens > 0 }
        return value
    }
    var vendors: [String] {
        let all = periods.first { $0.id == "lifetime" }?.models ?? periods.flatMap(\.models)
        return Array(Set(all.filter { $0.tokens > 0 }.map(\.vendor))).sorted {
            let order = ["anthropic", "openai"]
            return (order.firstIndex(of: $0) ?? 9, $0) < (order.firstIndex(of: $1) ?? 9, $1)
        }
    }
}

// All prices are USD per one million tokens. These are standard API equivalents.
struct NotchTokenRate: Codable {
    var modelID: String
    var input: Double
    var cached: Double?
    var output: Double
    var write5m: Double?
    var write1h: Double?
    var source: String
    var sourceURL: String
    var checkedAt: Date
    var proxy = false
}

struct NotchTokenModel: Codable, Identifiable {
    var id: String { provider + ":" + name }
    var provider: String
    var name: String
    /// Model maker inferred from the model name. `provider` is the tool that logged the usage.
    var vendor = "unknown"
    var tokens: Int64 = 0
    var input: Int64 = 0
    var cached: Int64 = 0
    var output: Int64 = 0
    var write5m: Int64 = 0
    var write1h: Int64 = 0
    var estimatedUSD: Double = 0
    var pricedTokens: Int64 = 0
    var rate: NotchTokenRate?
    var adjustedCacheCounts = false
    var chargedInput: Int64 = 0
    var chargedCached: Int64 = 0
    var chargedWrite5m: Int64 = 0
    var chargedWrite1h: Int64 = 0
    // Cache read/write counts are included in source input. Never add them to totals again.
    var billableCached: Int64 { min(cached, input) }
    var billableWrite5m: Int64 { min(write5m, max(0, input - billableCached)) }
    var billableWrite1h: Int64 { min(write1h, max(0, input - billableCached - billableWrite5m)) }
    var freshInput: Int64 { max(0, input - billableCached - billableWrite5m - billableWrite1h) }
    var hasProxy: Bool { rate?.proxy == true }
    static func vendorTitle(_ vendor: String) -> String {
        ["anthropic": "Anthropic", "openai": "OpenAI", "google": "Google", "x-ai": "xAI", "z-ai": "Z.ai", "qwen": "Qwen",
         "deepseek": "DeepSeek", "moonshotai": "Moonshot", "mistralai": "Mistral", "meta-llama": "Meta"][vendor]
            ?? (vendor == "unknown" ? "Other" : vendor.capitalized)
    }

    mutating func price(using rate: NotchTokenRate?) {
        self.rate = rate
        adjustedCacheCounts = cached > input || write5m > input - billableCached
            || write1h > input - billableCached - billableWrite5m
        chargedInput = freshInput; chargedCached = billableCached
        chargedWrite5m = billableWrite5m; chargedWrite1h = billableWrite1h
        estimatedUSD = 0; pricedTokens = 0
        guard let rate else { return }
        let categories: [(Int64, Double?)] = [(freshInput, rate.input), (billableCached, rate.cached),
            (output, rate.output), (billableWrite5m, rate.write5m), (billableWrite1h, rate.write1h)]
        for (count, price) in categories {
            if let price { estimatedUSD += Double(count) * price / 1_000_000; pricedTokens += count }
        }
        pricedTokens = min(tokens, pricedTokens)
    }
    mutating func add(_ other: Self) {
        tokens += other.tokens; input += other.input; cached += other.cached; output += other.output
        write5m += other.write5m; write1h += other.write1h
        estimatedUSD += other.estimatedUSD; pricedTokens += other.pricedTokens
        adjustedCacheCounts = adjustedCacheCounts || other.adjustedCacheCounts
        chargedInput += other.chargedInput; chargedCached += other.chargedCached
        chargedWrite5m += other.chargedWrite5m; chargedWrite1h += other.chargedWrite1h
    }
}
