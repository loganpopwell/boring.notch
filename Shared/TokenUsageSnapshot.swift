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
    var coverage: Double { tokens > 0 ? min(1, Double(pricedTokens) / Double(tokens)) : 1 }
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
}
