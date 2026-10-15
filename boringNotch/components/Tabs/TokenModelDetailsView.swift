import SwiftUI

private func tokenCount(_ value: Int64) -> String {
    if value >= 1_000_000_000 { return String(format: "%.2fB", Double(value) / 1_000_000_000) }
    if value >= 1_000_000 { return String(format: "%.2fM", Double(value) / 1_000_000) }
    if value >= 1_000 { return String(format: "%.1fK", Double(value) / 1_000) }
    return String(value)
}
private func tokenUSD(_ value: Double) -> String { value.formatted(.currency(code: "USD")) }
private func tokenRate(_ value: Double?) -> String {
    guard let value else { return "n/a" }
    return "$" + value.formatted(.number.precision(.fractionLength(0...4)))
}
private func modelCost(_ model: NotchTokenModel) -> String {
    model.tokens > 0 && model.pricedTokens == 0 ? "Unpriced" : tokenUSD(model.estimatedUSD)
}

struct TokenModelList: View {
    let period: NotchTokenPeriod
    let onSelect: (NotchTokenModel) -> Void
    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text("MODEL"); Spacer()
                Text("TOKEN SHARE").frame(width: 75, alignment: .trailing)
                Text("TOKENS").frame(width: 80, alignment: .trailing)
                Text("EST. USD").frame(width: 80, alignment: .trailing)
            }.font(.system(size: 8, weight: .medium)).foregroundStyle(.secondary).padding(.horizontal, 9)
            ForEach(period.models) { model in
                Button { onSelect(model) } label: {
                    VStack(spacing: 5) {
                        HStack(spacing: 5) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(model.name).fontWeight(.medium).lineLimit(1)
                                Text((model.provider == "claude" ? "Claude Code" : "Codex") + (model.hasProxy ? " · proxy price" : ""))
                                    .font(.system(size: 8)).foregroundStyle(model.hasProxy ? .orange : .secondary)
                            }
                            Spacer(minLength: 3)
                            Text(share(model.tokens)).foregroundStyle(.secondary).frame(width: 75, alignment: .trailing)
                            Text(tokenCount(model.tokens)).frame(width: 80, alignment: .trailing)
                            Text(modelCost(model)).foregroundStyle(.cyan).frame(width: 80, alignment: .trailing)
                        }.font(.system(size: 11)).monospacedDigit()
                        ProgressView(value: period.tokens > 0 ? Double(model.tokens) / Double(period.tokens) : 0)
                            .tint(.cyan).scaleEffect(y: 0.6)
                    }.padding(9).background(RoundedRectangle(cornerRadius: 9).fill(Color(nsColor: .secondarySystemFill)))
                }.buttonStyle(.plain).accessibilityLabel("Details for \(model.name), \(share(model.tokens)) of tokens, \(modelCost(model))")
            }
            if period.models.isEmpty { Text("No model usage recorded for this period.").foregroundStyle(.secondary) }
        }
    }
    private func share(_ tokens: Int64) -> String {
        String(format: "%.1f%%", period.tokens > 0 ? Double(tokens) / Double(period.tokens) * 100 : 0)
    }
}

struct TokenPricingChart: View {
    let period: NotchTokenPeriod
    let onSelect: (NotchTokenModel) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("USD per 1 million tokens · standard rates").font(.system(size: 10)).foregroundStyle(.secondary)
            HStack(spacing: 3) {
                Text("MODEL").frame(maxWidth: .infinity, alignment: .leading)
                heading("Input")
                heading("Cache read")
                heading("Output")
                heading("Write 5m")
                heading("Write 1h")
            }.font(.system(size: 8, weight: .medium)).foregroundStyle(.secondary).padding(.horizontal, 8)
            ForEach(period.models) { model in
                Button { onSelect(model) } label: {
                    HStack(spacing: 3) {
                        Text(model.name + (model.hasProxy ? " *" : "")).lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading).help(model.name)
                        rate(model.rate?.input)
                        rate(model.rate?.cached)
                        rate(model.rate?.output)
                        rate(model.rate?.write5m)
                        rate(model.rate?.write1h)
                    }.font(.system(size: 10)).monospacedDigit().padding(8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .secondarySystemFill)))
                }.buttonStyle(.plain).accessibilityLabel("Pricing details for \(model.name)")
            }
            Text("Input is sent to the model; output is received. Cache reads and writes are part of input. Tap a model for its usage, charges, and price source.")
                .font(.system(size: 9)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if period.models.contains(where: \.hasProxy) {
                Text("* Spark uses GPT-5.3 Codex rates as an explicit proxy.").font(.system(size: 9)).foregroundStyle(.orange)
            }
        }
    }
    private func heading(_ text: String) -> some View { Text(text).frame(width: 62, alignment: .trailing) }
    private func rate(_ value: Double?) -> some View { Text(tokenRate(value)).foregroundStyle(.cyan).frame(width: 62, alignment: .trailing) }
}

struct TokenModelDetail: View {
    let model: NotchTokenModel
    let period: NotchTokenPeriod
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.name).font(.system(size: 13, weight: .semibold))
                    Text("\(tokenCount(model.tokens)) tokens · \(share(model.tokens, total: period.tokens)) of usage · \(period.title)")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text(modelCost(model)).font(.system(size: 18, weight: .semibold)).foregroundStyle(.cyan)
                    Text("\(share(model.estimatedUSD, total: period.estimatedUSD)) of estimated cost").font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
            HStack {
                Text("CATEGORY").frame(maxWidth: .infinity, alignment: .leading)
                Text("TOKENS").frame(width: 90, alignment: .trailing)
                Text("USD / 1M").frame(width: 80, alignment: .trailing)
                Text("EST. USD").frame(width: 90, alignment: .trailing)
            }.font(.system(size: 8)).foregroundStyle(.secondary)
            VStack(spacing: 5) {
                charge("Input sent (uncached)", count: model.chargedInput, rate: model.rate?.input)
                charge("Cache read", count: model.chargedCached, rate: model.rate?.cached)
                charge("Cache write · 5 min", count: model.chargedWrite5m, rate: model.rate?.write5m)
                charge("Cache write · 1 hour", count: model.chargedWrite1h, rate: model.rate?.write1h)
                charge("Output received", count: model.output, rate: model.rate?.output)
            }.padding(9).background(RoundedRectangle(cornerRadius: 9).fill(Color(nsColor: .secondarySystemFill)))
            if let rate = model.rate {
                HStack {
                    if let url = URL(string: rate.sourceURL) { Link("Price source", destination: url).foregroundStyle(.cyan) }
                    Text(rate.source + " · " + rate.checkedAt.formatted(date: .abbreviated, time: .omitted))
                        .foregroundStyle(rate.proxy ? .orange : .secondary)
                }.font(.system(size: 9))
            } else {
                Text("No matching published price. These tokens remain visible and unpriced.").font(.system(size: 9)).foregroundStyle(.orange)
            }
            if model.adjustedCacheCounts {
                Text("Source cache counts exceed input. Charged cache tokens are capped to reported input; recorded totals are retained.")
                    .font(.system(size: 9)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            Text("Standard API-equivalent estimate at current rates. Subscription bills, Fast mode, long-context surcharges, and tool fees are excluded.")
                .font(.system(size: 9)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func share<T: BinaryInteger>(_ value: T, total: T) -> String { share(Double(value), total: Double(total)) }
    private func share(_ value: Double, total: Double) -> String { String(format: "%.1f%%", total > 0 ? value / total * 100 : 0) }
    private func charge(_ title: String, count: Int64, rate: Double?) -> some View {
        HStack {
            Text(title).frame(maxWidth: .infinity, alignment: .leading)
            Text(tokenCount(count)).frame(width: 90, alignment: .trailing)
            Text(tokenRate(rate)).foregroundStyle(.secondary).frame(width: 80, alignment: .trailing)
            Text(rate.map { tokenUSD(Double(count) * $0 / 1_000_000) } ?? (count > 0 ? "Unpriced" : "$0.00"))
                .foregroundStyle(.cyan).frame(width: 90, alignment: .trailing)
        }.font(.system(size: 10)).monospacedDigit()
    }
}
