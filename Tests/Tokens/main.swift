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
// The details cache uses Foundation reference-date timestamps, not Unix time.
func claudeFixture(version: Int = 10, days: [[String: Any]]? = nil) throws -> Data {
    try JSONSerialization.data(withJSONObject: ["version": version, "snapshot": ["claude": [
        "scannedAt": now.timeIntervalSinceReferenceDate,
        "byDay": days ?? [
            ["day": "2026-08-31", "usage": ["input": 80, "cachedInput": 50, "output": 20, "total": 100]],
            ["day": "2026-09-30", "usage": ["input": 180, "cachedInput": 100, "cacheCreationInput": 40, "output": 20, "total": 200]],
            ["day": "2026-10-01", "usage": ["input": 900, "cachedInput": 0, "output": 100, "total": 1000]]
        ]
    ]]])
}
let claude = try TokenUsageReader.decodeClaude(claudeFixture(), now: now, timeZone: TimeZone(identifier: "America/Chicago")!)
assert(claude.periods[0].tokens == 200 && claude.periods[1].tokens == 200)
assert(claude.periods[2].tokens == 300, "Ignore future calendar days and do not count cache creation twice")
assert(claude.periods[0].input == 180 && claude.periods[0].cached == 100)
assert(claude.periods[2].pricedTokens == 0 && claude.periods[2].coverage == 0, "Never invent Claude pricing")
assert(abs(claude.sampledAt.timeIntervalSince(now)) < 1)
assert((try? TokenUsageReader.decodeClaude(claudeFixture(version: 99))) == nil)
let duplicate: [String: Any] = ["day": "2026-09-30", "usage": ["input": 80, "cachedInput": 0, "output": 20, "total": 100]]
assert((try? TokenUsageReader.decodeClaude(claudeFixture(days: [duplicate, duplicate]))) == nil)
let invalid: [String: Any] = ["day": "2026-09-30", "usage": ["input": -1, "cachedInput": 0, "output": 20, "total": 100]]
assert((try? TokenUsageReader.decodeClaude(claudeFixture(days: [invalid]))) == nil)
let oldClaude = try JSONSerialization.jsonObject(with: claudeFixture()) as! [String: Any]
var olderDetails = oldClaude
var reports = olderDetails["snapshot"] as! [String: Any]
var report = reports["claude"] as! [String: Any]
report["scannedAt"] = now.addingTimeInterval(-3600).timeIntervalSinceReferenceDate
reports["claude"] = report; olderDetails["snapshot"] = reports
let recentCache = try JSONSerialization.data(withJSONObject: ["version": 6, "entries": [[
    "quota": "claude", "windowHours": 24, "report": ["scannedAt": now.timeIntervalSinceReferenceDate, "byDay": [
        ["day": "2026-09-29", "usage": ["input": 800, "cachedInput": 0, "output": 100, "total": 900]],
        ["day": "2026-09-30", "usage": ["input": 380, "cachedInput": 200, "output": 20, "total": 400]]
    ]]
]]])
let recentClaude = try TokenUsageReader.decodeClaude(JSONSerialization.data(withJSONObject: olderDetails), dashboard: recentCache,
    now: now, timeZone: TimeZone(identifier: "America/Chicago")!)
assert(recentClaude.periods[0].tokens == 400 && recentClaude.periods[2].tokens == 500,
    "Replace the complete current day with fresher usage; exclude the rolling window's partial first day")
assert(abs(recentClaude.sampledAt.timeIntervalSince(now)) < 1)
let fallNow = ISO8601DateFormatter().date(from: "2026-11-02T05:30:00Z")! // 23:30 on a 25-hour Chicago day.
let fallDay: [String: Any] = ["day": "2026-11-01", "usage": ["input": 180, "cachedInput": 0, "output": 20, "total": 200]]
let fallDetails = try JSONSerialization.data(withJSONObject: ["version": 10, "snapshot": ["claude": [
    "scannedAt": fallNow.addingTimeInterval(-3600).timeIntervalSinceReferenceDate, "byDay": [fallDay]
]]])
let fallDashboard = try JSONSerialization.data(withJSONObject: ["version": 6, "entries": [[
    "quota": "claude", "windowHours": 24, "report": ["scannedAt": fallNow.timeIntervalSinceReferenceDate,
        "byDay": [["day": "2026-11-01", "usage": ["input": 380, "cachedInput": 0, "output": 20, "total": 400]]]]
]]])
let fall = try TokenUsageReader.decodeClaude(fallDetails, dashboard: fallDashboard, now: fallNow, timeZone: TimeZone(identifier: "America/Chicago")!)
assert(fall.periods[0].tokens == 200, "A 24-hour report cannot replace a current calendar day already longer than 24 hours")
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
if CommandLine.arguments.contains("--live") {
let live = TokenUsageReader().sample()
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
assert(live.periods[2].tokens == originalTotal)
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
assert(live.source("all").periods[2].tokens == originalTotal + claudeTotal)
for source in [live.source("codex"), live.source("claude"), live.source("all")] {
    for period in source.periods {
        assert(period.models.reduce(0) { $0 + $1.tokens } == period.tokens)
        assert(abs(period.models.reduce(0) { $0 + $1.estimatedUSD } - period.estimatedUSD) < 0.001)
        assert(period.models.reduce(0) { $0 + $1.pricedTokens } == period.pricedTokens)
    }
}
assert(live.source("claude").periods[2].estimatedUSD > 0, "Live Claude usage must now be priced")
}
print("Token usage checks passed: calendar boundaries, cache accounting, price coverage, schema validation, Claude cache accounting, combined and partial totals, price conversion and category charges, model reconciliation, and live aggregate reconciliation")
