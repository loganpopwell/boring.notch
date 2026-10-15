import Foundation

/// Reads only usage metadata from local Claude Code JSONL files. No content is decoded or retained.
final class ClaudeLocalUsageReader: @unchecked Sendable {
    static let shared = ClaudeLocalUsageReader()
    struct Event {
        let id: String
        let model: String
        let date: Date
        let usage: TokenUsageReader.Usage
    }
    private struct Header: Decodable { let type: String? }
    private struct Record: Decodable {
        let timestamp: String?
        let requestId: String?
        let uuid: String?
        let message: Message?
        struct Message: Decodable { let id: String?; let model: String?; let usage: RawUsage? }
    }
    struct RawUsage: Decodable {
        let input_tokens: Int64?
        let output_tokens: Int64?
        let cache_read_input_tokens: Int64?
        let cache_creation_input_tokens: Int64?
        let cache_creation: Creation?
        struct Creation: Decodable { let ephemeral_5m_input_tokens: Int64?; let ephemeral_1h_input_tokens: Int64? }
        func normalized() throws -> TokenUsageReader.Usage {
            let fresh = input_tokens ?? 0, output = output_tokens ?? 0, read = cache_read_input_tokens ?? 0
            let five = cache_creation?.ephemeral_5m_input_tokens ?? 0
            let hour = cache_creation?.ephemeral_1h_input_tokens ?? 0
            let parent = cache_creation_input_tokens ?? (five + hour)
            // Claude can emit zero-usage streaming placeholders with stale nested cache metadata.
            if input_tokens == 0 && output_tokens == 0 && cache_read_input_tokens == 0 && cache_creation_input_tokens == 0 {
                return .init(input: 0, cachedInput: 0, output: 0, total: 0)
            }
            let limit: Int64 = 1_000_000_000_000
            guard [fresh, output, read, parent, five, hour].allSatisfy({ (0...limit).contains($0) }),
                  five + hour <= parent else { throw TokenUsageReader.InvalidHistory.invalid }
            // The parent is the total, not an additional cache-write category. Legacy writes default to 5m.
            return .init(input: fresh + read + parent, cachedInput: read, output: output,
                total: fresh + read + parent + output, cacheCreationInput: parent - hour, cacheCreationInput1h: hour)
        }
    }
    private struct CachedFile { let size: Int; let modified: Date; let events: [Event]; let partial: Bool }
    private var cache: [URL: CachedFile] = [:]
    private let lock = NSLock()
    static func parse(_ data: Data) -> (events: [Event], partial: Bool) {
        let decoder = JSONDecoder()
        let dateParser = ISO8601DateFormatter()
        dateParser.formatOptions.insert(.withFractionalSeconds)
        let plainDateParser = ISO8601DateFormatter()
        var events: [Event] = [], partial = false
        let lines = data.split(separator: 10, omittingEmptySubsequences: true)
        for (index, line) in lines.enumerated() {
            do {
                let header = try decoder.decode(Header.self, from: Data(line))
                guard header.type == "assistant" else { continue }
                let record = try decoder.decode(Record.self, from: Data(line))
                guard let message = record.message, let raw = message.usage else { continue }
                guard let timestamp = record.timestamp,
                      let date = dateParser.date(from: timestamp) ?? plainDateParser.date(from: timestamp),
                      let id = message.id ?? record.requestId ?? record.uuid,
                      let model = message.model, model.count <= 200, id.count <= 300 else {
                    partial = true; continue
                }
                let usage = try raw.normalized()
                if usage.total > 0 { events.append(Event(id: id, model: model, date: date, usage: usage)) }
            } catch {
                // A live writer can leave an unfinished final record. Never cache its partial bytes as usage.
                if index != lines.count - 1 || data.last == 10 { partial = true }
            }
        }
        return (events, partial)
    }
    static func aggregate(_ events: [Event], now: Date, timeZone: TimeZone, pricing: [String: NotchTokenRate]) throws -> NotchTokenSource {
        var unique: [String: Event] = [:]
        for event in events where event.date <= now {
            if let old = unique[event.id], old.usage.total > event.usage.total ||
                (old.usage.total == event.usage.total && old.date >= event.date) { continue }
            unique[event.id] = event
        }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone; formatter.dateFormat = "yyyy-MM-dd"
        var buckets: [String: [String: TokenUsageReader.Usage]] = [:]
        func add(_ a: TokenUsageReader.Usage, _ b: TokenUsageReader.Usage) -> TokenUsageReader.Usage {
            .init(input: a.input + b.input, cachedInput: a.cachedInput + b.cachedInput, output: a.output + b.output,
                total: a.total + b.total, cacheCreationInput: (a.cacheCreationInput ?? 0) + (b.cacheCreationInput ?? 0),
                cacheCreationInput1h: (a.cacheCreationInput1h ?? 0) + (b.cacheCreationInput1h ?? 0))
        }
        let zero = TokenUsageReader.Usage(input: 0, cachedInput: 0, output: 0, total: 0)
        for event in unique.values {
            let key = formatter.string(from: event.date)
            buckets[key, default: [:]][event.model] = add(buckets[key]?[event.model] ?? zero, event.usage)
        }
        let days = buckets.mapValues { models in
            let rows = models.map { TokenUsageReader.ModelUsage(name: $0.key, usage: $0.value) }
            return rows
        }
        var reportDays: [String: TokenUsageReader.Day] = [:]
        for (day, rows) in days {
            reportDays[day] = .init(day: day, usage: rows.reduce(zero) { add($0, $1.usage) },
                apiEquivalentUSD: 0, apiEquivalentPricedTokens: 0, lastObservedAt: now, modelBreakdown: rows)
        }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let report = TokenUsageReader.ClaudeHistory(machine: .init(timeZoneIdentifier: timeZone.identifier), localCodexByDay: reportDays, updatedAt: now)
        let value = try TokenUsageReader.decode(encoder.encode(report), now: now, pricing: pricing, provider: "claude")
        return .init(periods: value.periods, months: value.months, sampledAt: now,
            error: reportDays.isEmpty ? "No local Claude Code usage recorded yet." : nil)
    }
    func sample(now: Date = Date(), timeZone: TimeZone, pricing: [String: NotchTokenRate]) -> NotchTokenSource {
        lock.lock(); defer { lock.unlock() }
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey, .isRegularFileKey]
        var partial = false
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles], errorHandler: { _, _ in partial = true; return true }) else {
            return .init(periods: [], months: [], sampledAt: .distantPast, error: "Local Claude Code history is unavailable.")
        }
        var next: [URL: CachedFile] = [:], events: [Event] = []
        for case let file as URL in enumerator {
            do {
                let info = try file.resourceValues(forKeys: keys)
                if info.isSymbolicLink == true { enumerator.skipDescendants(); continue }
                guard info.isRegularFile == true, file.pathExtension == "jsonl" else { continue }
                let size = info.fileSize ?? 0, modified = info.contentModificationDate ?? .distantPast
                let entry: CachedFile
                if let old = cache[file], old.size == size, old.modified == modified { entry = old }
                else {
                    guard size <= 250_000_000 else { partial = true; continue }
                    let result = Self.parse(try Data(contentsOf: file, options: .mappedIfSafe))
                    entry = .init(size: size, modified: modified, events: result.events, partial: result.partial)
                }
                next[file] = entry; events.append(contentsOf: entry.events); partial = partial || entry.partial
            } catch { partial = true }
        }
        cache = next
        do {
            var value = try Self.aggregate(events, now: now, timeZone: timeZone, pricing: pricing)
            if partial { value.notice = "Some local Claude records unavailable · partial totals" }
            return value
        } catch { return .init(periods: [], months: [], sampledAt: .distantPast, error: "Local Claude usage could not be decoded.") }
    }
}
