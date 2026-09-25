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
if CommandLine.arguments.contains("--live") {
let live = TokenUsageReader().sample()
assert(live.error == nil, "Installed meter aggregate should parse")
assert(live.periods.count == 3 && !live.months.isEmpty)
assert(live.periods[2].tokens >= live.periods[1].tokens)
assert(live.periods.allSatisfy { (0...1).contains($0.coverage) })
let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Codex Token Meter/machine-usage-history.json")
let original = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
let originalDays = original["localCodexByDay"] as! [String: [String: Any]]
let originalTotal = originalDays.values.reduce(Int64(0)) { $0 + (($1["usage"] as! [String: Any])["total"] as! NSNumber).int64Value }
let originalCost = originalDays.values.reduce(0.0) { $0 + ($1["apiEquivalentUSD"] as! NSNumber).doubleValue }
assert(live.periods[2].tokens == originalTotal)
assert(abs(live.periods[2].estimatedUSD - originalCost) < 0.0001)
}
print("Token usage checks passed: calendar boundaries, cache accounting, price coverage, schema validation, and live aggregate parsing")
