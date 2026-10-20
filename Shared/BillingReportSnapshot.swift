import Foundation

/// The LumaCore billing report's Overview tab, as served by the dashboard's notch feed. Amounts are cents.
struct NotchBillingReport: Codable, Equatable {
    struct YearMonth: Codable, Equatable { let year: Int; let month: Int }
    struct Recurring: Codable, Equatable {
        let mrr: Int?; let arr: Int?; let atRiskMRR: Int?; let trialMRR: Int?; let potentialMRR: Int?
        let customers: Int; let complete: Bool; let pastDue: Int; let trials: Int
    }
    struct ThisMonth: Codable, Equatable {
        let collectedMonth: Int; let refundedMonth: Int; let netMonth: Int
        let availableBalance: Int; let pendingBalance: Int
        let payingCustomers: Int; let eligibleSubscriptions: Int; let fees: Int
    }
    struct ThisYear: Codable, Equatable {
        let year: Int; let collected: Int; let paymentCount: Int; let averageMonth: Int; let monthsCounted: Int; let annualized: Int
    }
    struct Expected: Codable, Equatable { let next30Days: Int; let next90Days: Int }
    struct Month: Codable, Equatable, Identifiable {
        let year: Int; let month: Int; let collected: Int
        var id: String { "\(year)-\(month)" }
    }
    struct Source: Codable, Equatable, Identifiable {
        let source: String; let label: String; let amount: Int
        var id: String { source }
    }
    struct Upcoming: Codable, Equatable { let date: Date; let customer: String; let amount: Int; let collection: String }
    struct Payment: Codable, Equatable { let date: Date; let customer: String; let source: String; let method: String; let amount: Int }

    let generatedAt: Date
    let currency: String
    let now: YearMonth
    let recurring: Recurring
    let thisMonth: ThisMonth
    let thisYear: ThisYear
    let expected: Expected
    let months: [Month]
    let sources: [Source]
    let upcoming: [Upcoming]
    let recent: [Payment]
    let warnings: [String]

    static func decode(_ data: Data) throws -> NotchBillingReport {
        struct Version: Decodable { let version: Int }
        guard try JSONDecoder().decode(Version.self, from: data).version == 1 else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Unsupported billing feed version"))
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: text) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: text) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad date \(text)"))
        }
        return try decoder.decode(NotchBillingReport.self, from: data)
    }
}

/// What the helper returns: the latest verified report, and why it couldn't refresh if it couldn't.
struct NotchBillingStatus: Codable {
    enum Problem: String, Codable { case missingKey, unauthorized, unavailable, offline }
    var report: NotchBillingReport?
    /// When the report was last fetched successfully.
    var fetchedAt: Date?
    var problem: Problem?
}
