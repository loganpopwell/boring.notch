import Foundation

/// Fetches a public price list only. No identifiers, usage, prompts, or credentials are sent.
final class TokenPricingCatalog: @unchecked Sendable {
    static let shared = TokenPricingCatalog()
    private let lock = NSLock()
    private var rates: [String: NotchTokenRate]
    private var lastAttempt = Date.distantPast
    private var inFlight = false
    private let cacheURL: URL
    private struct Cache: Codable { let version: Int; let rates: [String: NotchTokenRate] }

    init() {
        cacheURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/BoringNotch/token-prices.json")
        rates = Self.seed
        if let size = try? cacheURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 5_000_000,
           let data = try? Data(contentsOf: cacheURL), let cache = try? JSONDecoder().decode(Cache.self, from: data),
           cache.version == 1, cache.rates.count <= 10000 {
            rates.merge(cache.rates.filter { Self.valid($0.value) }) { _, new in new }
        }
    }

    func snapshot() -> [String: NotchTokenRate] {
        lock.lock(); defer { lock.unlock() }
        return rates
    }
    func refreshIfNeeded() {
        lock.lock()
        let newest = rates.values.map(\.checkedAt).max() ?? .distantPast
        guard !inFlight, Date().timeIntervalSince(newest) > 86400,
              Date().timeIntervalSince(lastAttempt) > 300 else { lock.unlock(); return }
        inFlight = true; lastAttempt = Date(); lock.unlock()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 20
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        let session = URLSession(configuration: config)
        session.dataTask(with: URL(string: "https://openrouter.ai/api/v1/models")!) { [weak self] data, response, _ in
            defer { session.finishTasksAndInvalidate() }
            guard let self else { return }
            let parsed: [String: NotchTokenRate]?
            if (response as? HTTPURLResponse)?.statusCode == 200, let data, data.count <= 5_000_000 {
                parsed = try? Self.parse(data)
            } else { parsed = nil }
            self.lock.lock()
            if let parsed, !parsed.isEmpty { self.rates.merge(parsed) { _, new in new } }
            let current = self.rates
            self.inFlight = false; self.lock.unlock()
            if let parsed, !parsed.isEmpty, let data = try? JSONEncoder().encode(Cache(version: 1, rates: current)) {
                try? FileManager.default.createDirectory(at: self.cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: self.cacheURL, options: .atomic)
            }
        }.resume()
    }

    static func valid(_ rate: NotchTokenRate) -> Bool {
        [rate.input, rate.output].allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 100000 }
            && [rate.cached, rate.write5m, rate.write1h].compactMap { $0 }.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 100000 }
            && rate.checkedAt <= Date().addingTimeInterval(300)
    }
    static func parse(_ data: Data, now: Date = Date()) throws -> [String: NotchTokenRate] {
        struct Catalog: Decodable {
            let data: [Model]
            struct Model: Decodable { let id: String; let canonical_slug: String?; let pricing: [String: Amount] }
            struct Amount: Decodable {
                let value: Double?
                init(from decoder: Decoder) throws {
                    let c = try decoder.singleValueContainer()
                    value = (try? c.decode(Double.self)) ?? (try? c.decode(String.self)).flatMap(Double.init)
                }
            }
        }
        let catalog = try JSONDecoder().decode(Catalog.self, from: data)
        guard catalog.data.count <= 10000 else { throw TokenUsageReader.InvalidHistory.invalid }
        var rates: [String: NotchTokenRate] = [:]
        for model in catalog.data where model.id.hasPrefix("openai/") || model.id.hasPrefix("anthropic/") {
            guard !model.id.contains(":"), let input = model.pricing["prompt"]?.value,
                  let output = model.pricing["completion"]?.value else { continue }
            let rate = NotchTokenRate(modelID: model.id, input: input * 1_000_000,
                cached: model.pricing["input_cache_read"]?.value.map { $0 * 1_000_000 }, output: output * 1_000_000,
                write5m: model.pricing["input_cache_write"]?.value.map { $0 * 1_000_000 },
                write1h: model.pricing["input_cache_write_1h"]?.value.map { $0 * 1_000_000 },
                source: "OpenRouter standard catalog", sourceURL: "https://openrouter.ai/" + model.id, checkedAt: now)
            guard valid(rate) else { continue }
            rates[model.id.lowercased()] = rate
            if let alias = model.canonical_slug { rates[alias.lowercased()] = rate }
        }
        return rates
    }

    static func resolve(_ name: String, provider: String, rates: [String: NotchTokenRate]) -> NotchTokenRate? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let prefix = provider == "claude" ? "anthropic/" : "openai/"
        let aliases = ["claude-opus-5-5": "claude-opus-5.5", "claude-sonnet-5-5": "claude-sonnet-5.5",
                       "claude-opus-4-6": "claude-opus-4.6", "claude-sonnet-4-6": "claude-sonnet-4.6",
                       "claude-sonnet-4-5": "claude-sonnet-4.5", "claude-haiku-4-5": "claude-haiku-4.5"]
        if let exact = rates[name] ?? rates[prefix + name] { return exact }
        // Only explicit aliases are accepted. Similar-looking future models are never silently matched.
        if let alias = aliases[name], let rate = rates[prefix + alias] { return rate }
        if name == "gpt-5.3-codex-spark", var proxy = rates["openai/gpt-5.3-codex"] {
            proxy.proxy = true
            proxy.source = "Proxy: GPT-5.3 Codex (Spark has no published rate)"
            return proxy
        }
        return nil
    }

    // Verified public catalog snapshot, 2026-10-01 UTC. Used offline until the next daily refresh.
    static let seed: [String: NotchTokenRate] = {
        let checkedAt = Date(timeIntervalSince1970: 1790827956)
        var result: [String: NotchTokenRate] = [:]
        result["openai/gpt-6.1-sol"] = NotchTokenRate(modelID: "openai/gpt-6.1-sol", input: 2.0, cached: 0.09999999999999999, output: 10.0, write5m: 2.5, write1h: nil, source: "OpenRouter standard catalog", sourceURL: "https://openrouter.ai/openai/gpt-6.1-sol", checkedAt: checkedAt)
        result["anthropic/claude-sonnet-5.5"] = NotchTokenRate(modelID: "anthropic/claude-sonnet-5.5", input: 2.0, cached: 0.19999999999999998, output: 10.0, write5m: 2.5, write1h: 4.0, source: "OpenRouter standard catalog", sourceURL: "https://openrouter.ai/anthropic/claude-sonnet-5.5", checkedAt: checkedAt)
        result["openai/gpt-6-luna"] = NotchTokenRate(modelID: "openai/gpt-6-luna", input: 0.09999999999999999, cached: 0.01, output: 0.5, write5m: 0.125, write1h: nil, source: "OpenRouter standard catalog", sourceURL: "https://openrouter.ai/openai/gpt-6-luna", checkedAt: checkedAt)
        result["openai/gpt-6-sol"] = NotchTokenRate(modelID: "openai/gpt-6-sol", input: 2.0, cached: 0.19999999999999998, output: 10.0, write5m: 2.5, write1h: nil, source: "OpenRouter standard catalog", sourceURL: "https://openrouter.ai/openai/gpt-6-sol", checkedAt: checkedAt)
        result["anthropic/claude-opus-5.5"] = NotchTokenRate(modelID: "anthropic/claude-opus-5.5", input: 4.0, cached: 0.19999999999999998, output: 20.0, write5m: 5.0, write1h: 8.0, source: "OpenRouter standard catalog", sourceURL: "https://openrouter.ai/anthropic/claude-opus-5.5", checkedAt: checkedAt)
        result["openai/gpt-6-astra"] = NotchTokenRate(modelID: "openai/gpt-6-astra", input: 10.0, cached: 1.0, output: 50.0, write5m: 12.5, write1h: nil, source: "OpenRouter standard catalog", sourceURL: "https://openrouter.ai/openai/gpt-6-astra", checkedAt: checkedAt)
        result["openai/gpt-5.6-luna"] = NotchTokenRate(modelID: "openai/gpt-5.6-luna", input: 0.19999999999999998, cached: 0.02, output: 1.2, write5m: 0.25, write1h: nil, source: "OpenRouter standard catalog", sourceURL: "https://openrouter.ai/openai/gpt-5.6-luna", checkedAt: checkedAt)
        result["openai/gpt-5.6-terra"] = NotchTokenRate(modelID: "openai/gpt-5.6-terra", input: 2.0, cached: 0.19999999999999998, output: 12.0, write5m: 2.5, write1h: nil, source: "OpenRouter standard catalog", sourceURL: "https://openrouter.ai/openai/gpt-5.6-terra", checkedAt: checkedAt)
        result["openai/gpt-5.6-sol"] = NotchTokenRate(modelID: "openai/gpt-5.6-sol", input: 2.0, cached: 0.19999999999999998, output: 10.0, write5m: 2.5, write1h: nil, source: "OpenRouter standard catalog", sourceURL: "https://openrouter.ai/openai/gpt-5.6-sol", checkedAt: checkedAt)
        result["anthropic/claude-sonnet-5"] = NotchTokenRate(modelID: "anthropic/claude-sonnet-5", input: 2.0, cached: 0.19999999999999998, output: 10.0, write5m: 2.5, write1h: 4.0, source: "OpenRouter standard catalog", sourceURL: "https://openrouter.ai/anthropic/claude-sonnet-5", checkedAt: checkedAt)
        result["openai/gpt-5.5"] = NotchTokenRate(modelID: "openai/gpt-5.5", input: 5.0, cached: 0.5, output: 30.0, write5m: nil, write1h: nil, source: "OpenRouter standard catalog", sourceURL: "https://openrouter.ai/openai/gpt-5.5", checkedAt: checkedAt)
        result["openai/gpt-5.4-mini"] = NotchTokenRate(modelID: "openai/gpt-5.4-mini", input: 0.75, cached: 0.075, output: 4.5, write5m: nil, write1h: nil, source: "OpenRouter standard catalog", sourceURL: "https://openrouter.ai/openai/gpt-5.4-mini", checkedAt: checkedAt)
        result["openai/gpt-5.3-codex"] = NotchTokenRate(modelID: "openai/gpt-5.3-codex", input: 1.75, cached: 0.175, output: 14.0, write5m: nil, write1h: nil, source: "OpenRouter standard catalog", sourceURL: "https://openrouter.ai/openai/gpt-5.3-codex", checkedAt: checkedAt)
        return result
    }()
}
