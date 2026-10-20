import Foundation

let now = ISO8601DateFormatter().date(from: "2026-10-01T00:30:00Z")!
func day(_ date: String, tokens: Int, cost: Double, priced: Int) -> [String: Any] {
    ["day": date, "usage": ["input": tokens - 20, "cachedInput": 30, "output": 20, "total": tokens],
     "apiEquivalentUSD": cost, "apiEquivalentPricedTokens": priced, "lastObservedAt": "2026-10-01T00:00:00Z"]
}
var fixture: [String: Any] = [
    "version": 1, "machine": ["timeZoneIdentifier": "America/Chicago"],
    "localCodexByDay": ["2026-08-31": day("2026-08-31", tokens: 100, cost: 1, priced: 100),
                        "2026-09-01": day("2026-09-01", tokens: 200, cost: 2, priced: 200),
                        "2026-09-30": day("2026-09-30", tokens: 300, cost: 0, priced: 0)],
    "latestAccountUsage": ["readAt": "2026-10-01T00:00:00.000Z", "summary": ["lifetimeTokens": 99999]]
]
func decode() throws -> NotchTokenSnapshot { try TokenUsageReader.decode(JSONSerialization.data(withJSONObject: fixture), now: now) }
let snapshot = try decode()
assert(snapshot.periods[0].tokens == 300, "Use meter timezone, not UTC, for today")
assert(snapshot.periods[1].tokens == 500, "This month must be calendar month, not rolling 30 days")
assert(snapshot.periods[2].tokens == 600, "Do not add account totals or cached tokens again")
assert(snapshot.periods[2].estimatedUSD == 3)
assert(snapshot.periods[1].coverage == 0.4, "Unpriced tokens must reduce coverage")
assert(snapshot.periods[0].coverage == 0)
assert(snapshot.months.map(\.id) == ["2026-09", "2026-08"])
assert(snapshot.accountLifetimeTokens == 99999)
var inconsistent = day("2026-09-30", tokens: 100, cost: 1, priced: 100)
inconsistent["usage"] = ["input": 80, "cachedInput": 120, "output": 20, "total": 100]
fixture["localCodexByDay"] = ["2026-09-30": inconsistent]
let oldCache = try decode()
assert(oldCache.cacheCountsInconsistent && oldCache.periods[2].tokens == 100)
fixture["version"] = 2
assert((try? decode()) == nil, "Unsupported schema must be unavailable")
fixture["version"] = 1
fixture["localCodexByDay"] = [String: Any]()
let empty = try decode()
assert(empty.error != nil, "Missing data is not zero usage")
let chicago = TimeZone(identifier: "America/Chicago")!
func event(_ id: String, _ date: String, _ usage: TokenUsageReader.Usage, model: String = "claude-opus-5-5") -> ClaudeLocalUsageReader.Event {
    .init(id: id, model: model, date: ISO8601DateFormatter().date(from: date)!, usage: usage)
}
let claude = try ClaudeLocalUsageReader.aggregate([
    event("a", "2026-08-31T18:00:00Z", .init(input: 80, cachedInput: 50, output: 20, total: 100)),
    event("b", "2026-09-30T18:00:00Z", .init(input: 180, cachedInput: 100, output: 20, total: 200, cacheCreationInput: 40)),
    event("c", "2026-10-01T12:00:00Z", .init(input: 900, cachedInput: 0, output: 100, total: 1000))
], now: now, timeZone: chicago, pricing: [:])
assert(claude.periods[0].tokens == 200 && claude.periods[1].tokens == 200)
assert(claude.periods[2].tokens == 300, "Ignore future usage and do not count cache creation twice")
assert(claude.periods[0].input == 180 && claude.periods[0].cached == 100)
assert(claude.periods[2].pricedTokens == 0 && claude.periods[2].coverage == 0, "Never invent Claude pricing")
var combined = snapshot
combined.claude = claude
assert(combined.source("all").periods[2].tokens == 900)
assert(combined.source("all").periods[2].pricedTokens == 300)
assert(combined.source("all").months.map(\.tokens) == [700, 200])
assert(combined.source("claude").periods[2].tokens == 300)
combined.error = "Missing Codex"
assert(combined.source("all").periods[2].tokens == 300 && combined.source("all").notice != nil)
combined = snapshot
assert(combined.source("all").periods[2].tokens == 600 && combined.source("all").notice != nil)
assert(combined.source("claude").error != nil, "Missing Claude report must not appear as zero")
let encoded = try JSONEncoder().encode(combined)
let roundTrip = try JSONDecoder().decode(NotchTokenSnapshot.self, from: encoded)
assert(roundTrip.source("all").periods[2].tokens == 600)
let priceJSON = Data(#"{"data":[{"id":"anthropic/claude-opus-5.5","pricing":{"prompt":"0.000004","completion":"0.00002","input_cache_read":"0.0000002","input_cache_write":"0.000005","input_cache_write_1h":"0.000008"}},{"id":"openai/gpt-test","pricing":{"prompt":"-1","completion":"0.1"}}]}"#.utf8)
let prices = try TokenPricingCatalog.parse(priceJSON, now: now)
let opus = TokenPricingCatalog.resolve("claude-opus-5-5", provider: "claude", rates: prices)!
assert(zip([opus.input, opus.cached!, opus.output, opus.write5m!, opus.write1h!], [4, 0.2, 20, 5, 8]).allSatisfy { abs($0 - $1) < 0.000001 })
assert(prices["openai/gpt-test"] == nil && TokenPricingCatalog.resolve("claude-opus-5-6", provider: "claude", rates: prices) == nil)
assert(TokenPricingCatalog.resolve("gpt-5.3-codex-spark", provider: "codex", rates: TokenPricingCatalog.seed)?.proxy == true)
var priced = NotchTokenModel(provider: "claude", name: "claude-opus-5-5", tokens: 1_100_000, input: 1_000_000,
    cached: 500_000, output: 100_000, write5m: 200_000, write1h: 100_000)
priced.price(using: opus)
assert(abs(priced.estimatedUSD - 4.7) < 0.000001 && priced.pricedTokens == 1_100_000)
assert(priced.chargedInput == 200_000 && priced.chargedCached == 500_000, "Cache categories are subsets of input")
var overCache = NotchTokenModel(provider: "claude", name: priced.name, tokens: 1_000_000, input: 800_000, cached: 900_000, output: 200_000)
overCache.price(using: opus)
assert(overCache.adjustedCacheCounts && abs(overCache.estimatedUSD - 4.16) < 0.000001)
var dailyPriced = fixture
dailyPriced["localCodexByDay"] = ["2026-09-30": ["day": "2026-09-30", "usage": ["input": 1_000_000, "cachedInput": 500_000, "output": 100_000, "total": 1_100_000],
    "apiEquivalentUSD": 9999, "apiEquivalentPricedTokens": 1_100_000, "lastObservedAt": "2026-10-01T00:00:00Z", "modelBreakdown": [
        ["name": "claude-opus-5-5", "usage": ["input": 1_000_000, "cachedInput": 500_000, "output": 100_000, "total": 1_100_000, "cacheCreationInput": 200_000, "cacheCreationInput1h": 100_000]]
    ]]]
let aggregatePriced = try TokenUsageReader.decode(JSONSerialization.data(withJSONObject: dailyPriced), now: now, pricing: prices, provider: "claude")
assert(abs(aggregatePriced.periods[0].estimatedUSD - 4.7) < 0.000001, "Use our category prices instead of an unrelated aggregate USD total")
assert(aggregatePriced.periods[0].models.count == 1 && aggregatePriced.periods[0].models[0].tokens == 1_100_000)
let unpriced = try TokenUsageReader.decode(JSONSerialization.data(withJSONObject: dailyPriced), now: now, pricing: [:], provider: "claude")
assert(unpriced.periods[0].estimatedUSD == 0 && unpriced.periods[0].pricedTokens == 0)
var mergedModels = aggregatePriced.periods[0]; mergedModels.add(aggregatePriced.periods[0])
assert(mergedModels.models.count == 1 && mergedModels.models[0].tokens == 2_200_000 && abs(mergedModels.estimatedUSD - 9.4) < 0.000001)
let localLines = Data(#"""
{"type":"assistant","timestamp":"2026-09-30T18:00:00Z","message":{"id":"message-1","model":"claude-opus-5-5","usage":{"input_tokens":100,"output_tokens":20,"cache_read_input_tokens":200,"cache_creation_input_tokens":300,"cache_creation":{"ephemeral_5m_input_tokens":100,"ephemeral_1h_input_tokens":200}}}}
{"type":"assistant","timestamp":"2026-09-30T18:00:01Z","message":{"id":"message-1","model":"claude-opus-5-5","usage":{"input_tokens":100,"output_tokens":40,"cache_read_input_tokens":200,"cache_creation_input_tokens":300,"cache_creation":{"ephemeral_5m_input_tokens":100,"ephemeral_1h_input_tokens":200}}}}
{"type":"assistant","timestamp":"2026-09-30T18:00:02Z","message":{"id":"message-2","model":"claude-opus-5-5","usage":{"input_tokens":10,"output_tokens":10,"cache_creation_input_tokens":100}}}
{"type":"user","message":{"content":"Ignored private contents"}}
"""#.utf8)
let placeholder = Data(#"{"type":"assistant","timestamp":"2026-09-30T18:00:00Z","message":{"id":"placeholder","model":"claude-opus-5-5","usage":{"input_tokens":0,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"cache_creation":{"ephemeral_1h_input_tokens":654,"ephemeral_5m_input_tokens":0}}}}"#.utf8)
assert(ClaudeLocalUsageReader.parse(placeholder).events.isEmpty && !ClaudeLocalUsageReader.parse(placeholder).partial)
let parsed = ClaudeLocalUsageReader.parse(localLines)
assert(!parsed.partial && parsed.events.count == 3)
let direct = try ClaudeLocalUsageReader.aggregate(parsed.events + parsed.events, now: now, timeZone: TimeZone(identifier: "America/Chicago")!, pricing: prices)
let directModel = direct.periods[0].models[0]
assert(directModel.tokens == 760 && directModel.input == 710 && directModel.output == 50, "Dedupe streaming messages and repeated files")
assert(directModel.write5m == 200 && directModel.write1h == 200 && directModel.cached == 200, "Parent cache writes counted once with duration breakdown")
assert(abs(directModel.estimatedUSD - 0.00408) < 0.00000001, "Fresh input, read, both write durations, and output charges reconcile")
assert(direct.periods[0].pricedTokens == 760)
assert(ClaudeLocalUsageReader.parse(Data("{bad}\n".utf8)).partial)
assert(!ClaudeLocalUsageReader.parse(Data("{unfinished".utf8)).partial)
// Proxied tools: the model name, not the logging tool, decides the maker and the price.
assert(TokenPricingCatalog.vendor(for: "gpt-6.1-sol") == "openai" && TokenPricingCatalog.vendor(for: "claude-opus-5-5") == "anthropic")
assert(TokenPricingCatalog.vendor(for: "openrouter/google/gemini-3-pro") == "openrouter" || TokenPricingCatalog.vendor(for: "gemini-3-pro") == "google")
assert(TokenPricingCatalog.vendor(for: "o4-mini") == "openai" && TokenPricingCatalog.vendor(for: "<synthetic>") == "unknown")
let seed = TokenPricingCatalog.seed
assert(TokenPricingCatalog.resolve("gpt-6.1-sol", provider: "claude", rates: seed)?.modelID == "openai/gpt-6.1-sol", "GPT through Claude Code is priced as GPT")
assert(TokenPricingCatalog.resolve("claude-opus-5-5[1m]", provider: "claude", rates: seed)?.modelID == "anthropic/claude-opus-5.5")
assert(TokenPricingCatalog.resolve("anthropic/claude-sonnet-5-5", provider: "codex", rates: seed)?.modelID == "anthropic/claude-sonnet-5.5", "Claude through Codex is priced as Claude")
assert(TokenPricingCatalog.resolve("gpt-6.1-sol-high", provider: "codex", rates: seed)?.modelID == "openai/gpt-6.1-sol")
assert(TokenPricingCatalog.resolve("claude-sonnet-5-5-thinking", provider: "claude", rates: seed)?.modelID == "anthropic/claude-sonnet-5.5")
assert(TokenPricingCatalog.resolve("gpt-5.4-mini", provider: "codex", rates: seed)?.modelID == "openai/gpt-5.4-mini", "Size names are not effort suffixes")
let alias = TokenPricingCatalog.resolve("opus", provider: "claude", rates: seed)
assert(alias?.modelID == "anthropic/claude-opus-5.5" && alias?.proxy == true, "Family aliases use the newest family rate, labeled")
assert(TokenPricingCatalog.resolve("sonnet", provider: "claude", rates: seed)?.modelID == "anthropic/claude-sonnet-5.5")
assert(TokenPricingCatalog.resolve("claude-opus-5-6", provider: "claude", rates: seed) == nil, "Never guess a successor model")
let mixed = try ClaudeLocalUsageReader.aggregate([
    event("m1", "2026-09-30T18:00:00Z", .init(input: 900, cachedInput: 0, output: 100, total: 1000)),
    event("m2", "2026-09-30T18:01:00Z", .init(input: 450, cachedInput: 0, output: 50, total: 500), model: "gpt-6.1-sol")
], now: now, timeZone: chicago, pricing: seed)
let gptRow = mixed.periods[0].models.first { $0.name == "gpt-6.1-sol" }!
assert(gptRow.provider == "claude" && gptRow.vendor == "openai" && gptRow.pricedTokens == 500)
let openAIOnly = mixed.filtered(vendor: "openai")
assert(openAIOnly.periods[0].tokens == 500 && openAIOnly.periods[0].models.count == 1 && openAIOnly.months.map(\.tokens) == [500])
assert(abs(openAIOnly.periods[0].estimatedUSD - gptRow.estimatedUSD) < 0.0000001)
assert(mixed.vendors == ["anthropic", "openai"])
// Growing session files are read from the last complete line; an unfinished record waits for its newline.
let folder = FileManager.default.temporaryDirectory.appendingPathComponent("boring-token-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: folder) }
let sessionFile = folder.appendingPathComponent("session.jsonl")
let line1 = #"{"type":"assistant","timestamp":"2026-09-30T18:00:00Z","message":{"id":"i1","model":"gpt-6.1-sol","usage":{"input_tokens":10,"output_tokens":5}}}"#
let line2 = #"{"type":"assistant","timestamp":"2026-09-30T18:00:05Z","message":{"id":"i2","model":"claude-opus-5-5","usage":{"input_tokens":20,"output_tokens":5}}}"#
try Data((line1 + "\n" + line2.prefix(40)).utf8).write(to: sessionFile)
let reader = ClaudeLocalUsageReader()
let first = reader.sample(now: now, timeZone: chicago, pricing: seed, root: folder)
assert(first.periods[0].tokens == 15 && first.notice == nil, "An unfinished last record is neither counted nor partial")
let handle = try FileHandle(forWritingTo: sessionFile); try handle.seekToEnd()
try handle.write(contentsOf: Data((line2.dropFirst(40) + "\n").utf8)); try handle.close()
let second = reader.sample(now: now, timeZone: chicago, pricing: seed, root: folder)
assert(second.periods[0].tokens == 40 && second.periods[0].models.count == 2, "Appended records are read incrementally")
try Data((line2 + "\n").utf8).write(to: sessionFile)
assert(reader.sample(now: now, timeZone: chicago, pricing: seed, root: folder).periods[0].tokens == 25, "A replaced file is read again from the start")
// Quota: proxy rate-limit headers, Anthropic usage replies, and native Codex session metadata.
let quotaNow = Date(timeIntervalSince1970: 1_792_040_000)
let signals = ["Anthropic-Ratelimit-Unified-5h-Utilization": "0.38", "Anthropic-Ratelimit-Unified-5h-Reset": "1792056600",
               "Anthropic-Ratelimit-Unified-5h-Status": "allowed", "Anthropic-Ratelimit-Unified-7d-Utilization": "1.0",
               "Anthropic-Ratelimit-Unified-7d-Reset": "1792050000", "Anthropic-Ratelimit-Unified-7d-Status": "rejected",
               "Anthropic-Ratelimit-Unified-Fallback-Percentage": "0.5"]
let fromSignals = AIStatusReader.signalWindows(signals, now: quotaNow)
assert(fromSignals.map(\.id) == ["five_hour", "seven_day"] && abs(fromSignals[0].percent - 38) < 0.001 && !fromSignals[0].limited)
assert(fromSignals[1].limited && fromSignals[1].percent == 100, "A rejected window is at its limit")
assert(AIStatusReader.signalWindows(signals, now: Date(timeIntervalSince1970: 1_792_060_000)).allSatisfy { $0.percent == 0 && $0.resetsAt == nil },
       "A window that already reset reads as empty")
let usageReply = Data(#"{"five_hour":{"utilization":38.0,"resets_at":"2026-10-15T09:29:59.690227+00:00"},"seven_day":null,"limits":[{"kind":"session","group":"session","percent":38,"resets_at":"2026-10-15T09:29:59.690227+00:00"},{"kind":"weekly_scoped","group":"weekly","percent":25,"resets_at":"2026-10-21T22:00:00+00:00","scope":{"model":{"display_name":"Fable"}}}]}"#.utf8)
let fromUsage = AIStatusReader.usageWindows(usageReply, now: quotaNow)!
assert(fromUsage.map(\.title) == ["5-hour", "Weekly · Fable"] && fromUsage[1].percent == 25 && fromUsage[0].resetsAt != nil)
let authFiles = Data(#"{"files":[{"auth_index":"a1","type":"claude","email":"one@example.com","priority":500,"status":"active","quota":{"observed_at":"2026-10-15T00:06:16.230138-05:00","signals":{"Anthropic-Ratelimit-Unified-5h-Utilization":"0.5","Anthropic-Ratelimit-Unified-5h-Reset":"1792056600"}},"recent_requests":[{"success":3,"failed":1}],"cooldowns":[]},{"auth_index":"a2","type":"claude","email":"two@example.com","priority":400,"disabled":true},{"auth_index":"a3","type":"claude","email":"three@example.com","priority":300,"unavailable":true,"cooldowns":[{"until":"x"}]},{"auth_index":"c1","type":"codex","id_token":{"chatgpt_account_id":"never-decoded"}}]}"#.utf8)
let pooled = try AIStatusReader.accounts(from: authFiles, now: quotaNow)
assert(pooled.map(\.id) == ["a1", "a2", "a3"] && pooled.map(\.label) == ["one", "two", "three"], "Only Claude logins, labeled without the domain")
assert(pooled.map(\.state) == ["ok", "disabled", "cooldown"] && pooled[0].recentRequests == 4 && pooled[0].session?.percent == 50)
assert(pooled[0].observedAt != nil, "Microsecond proxy timestamps parse")
let codexHome = FileManager.default.temporaryDirectory.appendingPathComponent("boring-codex-\(UUID().uuidString)")
let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: quotaNow)
let codexDay = codexHome.appendingPathComponent(String(format: ".codex/sessions/%04d/%02d/%02d", parts.year!, parts.month!, parts.day!))
try FileManager.default.createDirectory(at: codexDay, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: codexHome) }
try Data(("""
{"timestamp":"2026-10-15T04:00:00.000Z","type":"response_item","payload":{"type":"message","content":"private text never decoded"}}
{"timestamp":"2026-10-15T04:53:35.007Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":15.0,"window_minutes":10080,"resets_at":1792483216},"secondary":{"used_percent":40,"window_minutes":300,"resets_at":1792050000},"plan_type":"prolite","rate_limit_reached_type":null}}}

""").utf8).write(to: codexDay.appendingPathComponent("rollout-test.jsonl"))
let codexLimits = AIStatusReader.codexAccount(home: codexHome, now: quotaNow)!
assert(codexLimits.windows.map(\.id) == ["five_hour", "seven_day"] && codexLimits.windows[1].percent == 15 && codexLimits.state == "ok")
var poolStatus = NotchAIStatus(proxyConfigured: true, proxyReachable: true, accounts: pooled + [codexLimits])
poolStatus.lastUsedID = "a1"; assert(poolStatus.activeClaude?.id == "a1")
poolStatus.lastUsedID = nil; poolStatus.nextID = nil; assert(poolStatus.activeClaude == nil, "Codex is never the active Claude account")
assert(AIStatusReader.launchAgentLabel(home: codexHome) == nil)
if CommandLine.arguments.contains("--live") {
let meterFile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Codex Token Meter/machine-usage-history.json")
let meterBefore = try Data(contentsOf: meterFile)
let live = TokenUsageReader().sample()
// AI Token Meter rewrites its report every few minutes; compare totals only against an unchanged file.
let meterStable = (try? Data(contentsOf: meterFile)) == meterBefore
assert(live.error == nil, "Installed meter aggregate should parse")
assert(live.periods.count == 3 && !live.months.isEmpty)
assert(live.periods[2].tokens >= live.periods[1].tokens)
assert(live.claude?.error == nil && live.source("claude").periods.count == 3)
assert(live.periods.allSatisfy { (0...1).contains($0.coverage) })
let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Codex Token Meter/machine-usage-history.json")
let original = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
let originalDays = original["localCodexByDay"] as! [String: [String: Any]]
let originalTotal = originalDays.values.reduce(Int64(0)) { $0 + (($1["usage"] as! [String: Any])["total"] as! NSNumber).int64Value }
let originalCost = originalDays.values.reduce(0.0) { $0 + ($1["apiEquivalentUSD"] as! NSNumber).doubleValue }
assert(!meterStable || live.periods[2].tokens == originalTotal)
let legacy = try TokenUsageReader.decode(Data(contentsOf: file))
assert(abs(legacy.periods[2].estimatedUSD - originalCost) < 0.0001)
assert(abs(live.periods[2].estimatedUSD - live.periods[2].models.reduce(0) { $0 + $1.estimatedUSD }) < 0.0001)
let claudeTotal = live.source("claude").periods[2].tokens
// Independent reconciliation uses identical file snapshots, so a live writer cannot race the comparison.
let validationNow = Date()
let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
var metadataEvents: [ClaudeLocalUsageReader.Event] = []
var independent: [String: Int64] = [:]
for case let localFile as URL in enumerator where localFile.pathExtension == "jsonl" {
    let data = try Data(contentsOf: localFile)
    let parsed = ClaudeLocalUsageReader.parse(data)
    assert(!parsed.partial, "All completed live usage records must decode")
    metadataEvents.append(contentsOf: parsed.events)
    for line in data.split(separator: 10) {
        guard let r = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any], r["type"] as? String == "assistant",
              let m = r["message"] as? [String: Any], m["model"] as? String != nil, let u = m["usage"] as? [String: Any],
              let id = m["id"] as? String ?? r["requestId"] as? String ?? r["uuid"] as? String,
              let timestamp = r["timestamp"] as? String else { continue }
        let dates = ISO8601DateFormatter(); dates.formatOptions.insert(.withFractionalSeconds)
        guard let date = dates.date(from: timestamp) ?? ISO8601DateFormatter().date(from: timestamp), date <= validationNow else { continue }
        let total = ["input_tokens", "output_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"].reduce(Int64(0)) {
            $0 + ((u[$1] as? NSNumber)?.int64Value ?? 0)
        }
        independent[id] = max(independent[id] ?? 0, total)
    }
}
let independentlyValidated = try ClaudeLocalUsageReader.aggregate(metadataEvents, now: validationNow, timeZone: .current, pricing: TokenPricingCatalog.seed)
assert(independentlyValidated.periods[2].tokens == independent.values.reduce(0, +), "Claude counts must match independent raw-field sums and message deduplication")
assert(live.claude?.notice == nil)
assert(!meterStable || live.source("all").periods[2].tokens == originalTotal + claudeTotal)
if !meterStable { print("Note: AI Token Meter updated its report during the live check; Codex total equality skipped") }
for source in [live.source("codex"), live.source("claude"), live.source("all")] {
    for period in source.periods {
        assert(period.models.reduce(0) { $0 + $1.tokens } == period.tokens)
        assert(abs(period.models.reduce(0) { $0 + $1.estimatedUSD } - period.estimatedUSD) < 0.001)
        assert(period.models.reduce(0) { $0 + $1.pricedTokens } == period.pricedTokens)
    }
}
assert(live.source("claude").periods[2].estimatedUSD > 0, "Live Claude usage must now be priced")
let liveStatus = AIStatusReader.shared.sample(detailed: false)
assert(!liveStatus.proxyConfigured || liveStatus.proxyReachable, "Configured proxy should answer locally")
assert(liveStatus.accounts.allSatisfy { $0.windows.allSatisfy { (0...100).contains($0.percent) } })
}
print("Token usage checks passed: calendar boundaries, cache accounting, price coverage, schema validation, Claude cache accounting, combined and partial totals, price conversion and category charges, model reconciliation, proxy-routed model attribution, incremental session reads, account quota parsing, and live aggregate reconciliation")
