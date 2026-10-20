import SwiftUI

@MainActor final class TokenUsageModel: ObservableObject {
    @Published var snapshot: NotchTokenSnapshot?
    @Published var failure: String?
    @Published var loading = false
    @Published var lateRefresh = false
    private var connection: NSXPCConnection?
    private var requestID = UUID()
    private var lastMeterLaunch = Date.distantPast

    func refresh(includeCodex: Bool = true) {
        guard !loading else { return }
        // The report writer is a separate menu-bar app. Relaunch it quietly if it has stopped.
        if includeCodex, !NSRunningApplication.runningApplications(withBundleIdentifier: "local.codex-token-meter").isEmpty {
            lastMeterLaunch = .distantPast
        } else if includeCodex, Date().timeIntervalSince(lastMeterLaunch) > 60,
                  let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "local.codex-token-meter") {
            lastMeterLaunch = Date()
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in }
        }
        if connection == nil {
            let value = NSXPCConnection(serviceName: "theboringteam.boringnotch.BoringNotchXPCHelper")
            value.remoteObjectInterface = NSXPCInterface(with: BoringNotchXPCHelperProtocol.self)
            value.resume(); connection = value
        }
        loading = true
        let id = UUID(); requestID = id
        let finish: @Sendable (Data?) -> Void = { [weak self] data in
            Task { @MainActor in
                guard let self, self.requestID == id, self.loading else { return }
                self.loading = false
                if let data, let next = try? JSONDecoder().decode(NotchTokenSnapshot.self, from: data) {
                    self.snapshot = next; self.failure = nil; self.lateRefresh = false
                } else if self.snapshot != nil {
                    // Keep showing the last good reading; the footer says the refresh is late.
                    self.lateRefresh = true
                } else {
                    self.failure = "Could not read local usage. Try refreshing."
                    self.connection?.invalidate(); self.connection = nil
                }
            }
        }
        if let proxy = connection?.remoteObjectProxyWithErrorHandler({ _ in finish(nil) }) as? BoringNotchXPCHelperProtocol {
            proxy.readTokenUsage(with: finish)
        } else { finish(nil) }
        // The first scan of a large Claude history can take several seconds; later scans read only new lines.
        Task { try? await Task.sleep(for: .seconds(snapshot == nil ? 45 : 20)); if requestID == id && loading { finish(nil) } }
    }
    deinit { connection?.invalidate() }
}

struct TokenUsageView: View {
    @EnvironmentObject var vm: BoringViewModel
    @StateObject private var model = TokenUsageModel()
    @State private var selected = "month"
    @State private var panel = "overview"
    @State private var selectedModelID: String?
    @State private var provider = "all"
    /// One height for every panel, so switching panels never resizes the notch.
    private let contentHeight: CGFloat = 186
    private let sections = [("overview", "Overview"), ("models", "Models"), ("pricing", "Pricing"), ("history", "History"), ("limits", "Limits")]
    private var source: NotchTokenSource? {
        guard let snapshot = model.snapshot else { return nil }
        if provider.hasPrefix("vendor:") { return snapshot.source("all").filtered(vendor: String(provider.dropFirst(7))) }
        return snapshot.source(provider)
    }
    private var vendorFilters: [(String, String)] {
        (model.snapshot?.source("all").vendors ?? []).map { ("vendor:" + $0, NotchTokenModel.vendorTitle($0)) }
    }
    private var failure: String? { model.failure ?? source?.error }
    private var providerTitle: String {
        if provider.hasPrefix("vendor:") { return NotchTokenModel.vendorTitle(String(provider.dropFirst(7))) + " models" }
        return provider == "codex" ? "Codex" : provider == "claude" ? "Claude Code" : "All tools"
    }
    private var section: String { panel == "detail" ? "models" : panel }
    private var chosenModel: NotchTokenModel? { period?.models.first { $0.id == selectedModelID } }
    private var period: NotchTokenPeriod? { source?.periods.first { $0.id == selected } }
    private var stale: Bool { source.map { Date().timeIntervalSince($0.sampledAt) > 3600 } ?? false }
    private func count(_ value: Int64) -> String {
        if value >= 1_000_000_000 { return String(format: "%.2fB", Double(value) / 1_000_000_000) }
        if value >= 1_000_000 { return String(format: "%.2fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fK", Double(value) / 1_000) }
        return String(value)
    }
    private func cost(_ p: NotchTokenPeriod) -> String {
        if p.tokens > 0 && p.pricedTokens == 0 { return "Unpriced" }
        return p.estimatedUSD.formatted(.currency(code: "USD"))
    }
    private func openMeter() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "local.codex-token-meter") {
            NSWorkspace.shared.open(url)
        } else { model.failure = "Install AI Token Meter to populate this tab." }
    }
    var body: some View {
        VStack(spacing: 7) {
            HStack(spacing: 4) {
                ForEach(sections, id: \.0) { id, title in
                    pill(title, on: section == id, tint: .cyan) { panel = id; selectedModelID = nil }
                }
                Spacer()
                Button { model.refresh(includeCodex: provider != "claude"); AIStatusModel.shared.refresh() } label: {
                    if model.loading { ProgressView().controlSize(.mini) } else { Image(systemName: "arrow.clockwise") }
                }
                    .buttonStyle(.plain).frame(width: 16).disabled(model.loading).help("Refresh usage and limits").accessibilityLabel("Refresh token usage")
                Button(action: openMeter) { Image(systemName: "arrow.up.forward.app") }
                    .buttonStyle(.plain).help("Open AI Token Meter to update history").accessibilityLabel("Open AI Token Meter")
            }.font(.system(size: 11))
            if section != "limits" {
                HStack(spacing: 3) {
                    ForEach([("all", "All"), ("codex", "Codex"), ("claude", "Claude Code")] + vendorFilters, id: \.0) { id, title in
                        if id == vendorFilters.first?.0 { Divider().frame(height: 10).padding(.horizontal, 3) }
                        pill(title, on: provider == id, tint: .white) { provider = id; selectedModelID = nil; if panel == "detail" { panel = "models" } }
                            .help(id.hasPrefix("vendor:") ? "Usage of this company's models from every tool" : "Usage logged by this tool")
                    }
                    Spacer()
                    if section != "history" {
                        Picker("Period", selection: $selected) {
                            Text("Today").tag("today"); Text("This month").tag("month"); Text("Lifetime").tag("lifetime")
                        }.pickerStyle(.segmented).labelsHidden().controlSize(.mini).frame(width: 200)
                    }
                }.font(.system(size: 10))
            }
            Group {
                if section == "limits" {
                    AILimitsPanel(height: contentHeight)
                } else if let failure = failure {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle").font(.system(size: 18)).foregroundStyle(.orange)
                        Text(failure).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        if provider != "claude" { Button("Open AI Token Meter", action: openMeter).buttonStyle(.plain).foregroundStyle(.cyan) }
                    }.font(.system(size: 12)).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if section == "history", let snapshot = source {
                    TokenHistoryChart(months: snapshot.months, count: count, cost: cost)
                } else if let p = period {
                    switch panel {
                    case "detail":
                        VStack(alignment: .leading, spacing: 5) {
                            Button { panel = "models"; selectedModelID = nil } label: { Label("All models", systemImage: "chevron.left") }
                                .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(.secondary)
                            ScrollView { if let chosenModel { TokenModelDetail(model: chosenModel, period: p) } }.scrollIndicators(.never)
                        }
                    case "models": ScrollView { TokenModelList(period: p, onSelect: openModel) }.scrollIndicators(.never)
                    case "pricing": ScrollView { TokenPricingChart(period: p, onSelect: openModel) }.scrollIndicators(.never)
                    default: overview(p)
                    }
                } else {
                    ProgressView("Reading token history…").controlSize(.small).font(.system(size: 11)).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }.frame(height: contentHeight, alignment: .top)
            footer
        }
        .padding(.horizontal, 12).frame(width: 600)
        .onDisappear { if vm.notchState == .open { vm.notchSize.height = openNotchSize.height } }
        .task {
            withAnimation(.smooth(duration: 0.25)) { vm.notchSize.height = 320 }
            while !Task.isCancelled {
                model.refresh(includeCodex: provider != "claude")
                do { try await Task.sleep(for: .seconds(30)) } catch { break }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 5) {
            if section == "limits" {
                Circle().fill(.mint).frame(width: 4, height: 4)
                if let date = AIStatusModel.shared.status?.sampledAt, date > .distantPast {
                    Text("Updated"); Text(date, style: .relative); Text("ago · CLI Proxy and Codex sessions")
                } else { Text("CLI Proxy and Codex sessions") }
                Spacer(minLength: 0)
                Text("Weekly limits refresh every two minutes while this is open")
            } else {
                Circle().fill(stale ? .orange : .mint).frame(width: 4, height: 4)
                if let date = source?.sampledAt, date > .distantPast {
                    Text(stale ? "Last scan" : "Updated")
                    Text(date, style: .relative)
                    Text(provider == "claude" ? "ago · Local Claude Code" : provider == "codex" ? "ago · AI Token Meter" : "ago · Local sources")
                } else { Text("Local history · AI Token Meter") }
                Spacer(minLength: 0)
                Text(model.lateRefresh ? "Refresh is taking longer · showing last reading" : source?.notice ?? (source?.cacheCountsInconsistent == true ? "Some source cache counts inconsistent" : "Estimates use standard API prices · not your bill"))
            }
        }
        .font(.system(size: 9)).foregroundStyle(section != "limits" && (stale || source?.notice != nil) ? .orange : .secondary).lineLimit(1)
    }

    @ViewBuilder private func overview(_ p: NotchTokenPeriod) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 7) {
                metric(providerTitle.uppercased() + " · TOKENS", value: count(p.tokens),
                       subtitle: selected == "lifetime" ? lifetimeNote : p.title, accent: false)
                metric("ESTIMATED COST", value: cost(p),
                       subtitle: p.coverage < 1 ? String(format: "%.1f%% of tokens priced", floor(p.coverage * 1000) / 10)
                           : p.models.contains(where: \.hasProxy) ? "Includes proxy pricing" : "At standard API prices",
                       accent: true)
                if provider != "codex" && provider != "vendor:openai" { AILimitSummary(provider: "claude") { panel = "limits" } }
                if provider != "claude" && provider != "vendor:anthropic" { AILimitSummary(provider: "codex") { panel = "limits" } }
            }.frame(height: 66)
            composition(p)
            topModels(p)
        }
    }

    private var lifetimeNote: String {
        if provider == "codex", let account = model.snapshot?.accountLifetimeTokens { return "Account total " + count(account) }
        return "Retained history on this Mac"
    }

    /// Where the tokens went: new input, cache reads, and output, as one stacked bar.
    private func composition(_ p: NotchTokenPeriod) -> some View {
        let cached = min(p.cached, p.input)
        let parts: [(String, Int64, Color)] = [("New input", max(0, p.input - cached), .cyan), ("Cache reads", cached, .indigo), ("Output", p.output, .mint)]
        let total = max(1, parts.reduce(0) { $0 + $1.1 })
        return VStack(spacing: 5) {
            GeometryReader { proxy in
                HStack(spacing: 2) {
                    ForEach(parts, id: \.0) { part in
                        if part.1 > 0 {
                            RoundedRectangle(cornerRadius: 2).fill(part.2.opacity(0.85))
                                .frame(width: max(3, (proxy.size.width - 4) * CGFloat(part.1) / CGFloat(total)))
                        }
                    }
                }
            }.frame(height: 6).clipShape(Capsule())
            HStack(spacing: 14) {
                ForEach(parts, id: \.0) { part in
                    HStack(spacing: 4) {
                        Circle().fill(part.2).frame(width: 5, height: 5)
                        Text(part.0).foregroundStyle(.secondary)
                        Text(count(part.1)).monospacedDigit()
                        Text(String(format: "%.0f%%", Double(part.1) / Double(total) * 100)).foregroundStyle(.secondary).monospacedDigit()
                    }.help(part.1.formatted() + " tokens")
                }
                Spacer(minLength: 0)
            }.font(.system(size: 10)).lineLimit(1)
        }
    }

    private func topModels(_ p: NotchTokenPeriod) -> some View {
        VStack(spacing: 3) {
            HStack {
                Text("TOP MODELS").font(.system(size: 8, weight: .medium)).tracking(0.4).foregroundStyle(.secondary)
                Spacer()
                if p.models.count > 3 {
                    Button("All \(p.models.count) models ›") { panel = "models" }.buttonStyle(.plain).font(.system(size: 9)).foregroundStyle(.cyan)
                }
            }
            ForEach(p.models.prefix(3)) { item in
                Button { openModel(item) } label: {
                    HStack(spacing: 8) {
                        Text(item.name).lineLimit(1).frame(width: 170, alignment: .leading)
                        AILimitBarShare(fraction: p.tokens > 0 ? Double(item.tokens) / Double(p.tokens) : 0)
                        Text(String(format: "%.0f%%", p.tokens > 0 ? Double(item.tokens) / Double(p.tokens) * 100 : 0))
                            .foregroundStyle(.secondary).frame(width: 34, alignment: .trailing)
                        Text(count(item.tokens)).frame(width: 58, alignment: .trailing)
                        Text(item.tokens > 0 && item.pricedTokens == 0 ? "Unpriced" : item.estimatedUSD.formatted(.currency(code: "USD")))
                            .foregroundStyle(.cyan).frame(width: 72, alignment: .trailing)
                    }
                    .font(.system(size: 10)).monospacedDigit()
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .secondarySystemFill).opacity(0.6)))
                    .contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("Details for \(item.name)")
            }
            if p.models.isEmpty { Text("No usage recorded for this period.").font(.system(size: 10)).foregroundStyle(.secondary).padding(.top, 6) }
        }
    }

    private func openModel(_ value: NotchTokenModel) { selectedModelID = value.id; panel = "detail" }
    private func pill(_ title: String, on: Bool, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).padding(.horizontal, 9).padding(.vertical, 3)
                .background(Capsule().fill(on ? tint.opacity(tint == .white ? 0.12 : 0.18) : .clear))
                .contentShape(Capsule())
        }.buttonStyle(.plain).foregroundStyle(on ? (tint == .white ? Color.primary : tint) : .secondary)
    }
    private func metric(_ title: String, value: String, subtitle: String, accent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 8, weight: .medium)).tracking(0.4).foregroundStyle(.secondary).lineLimit(1)
            Text(value).font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(accent ? Color.cyan : .white).lineLimit(1).minimumScaleFactor(0.6)
            Text(subtitle).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading).padding(.horizontal, 11).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 11).fill(Color(nsColor: .secondarySystemFill)))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(.white.opacity(0.08), lineWidth: 0.7))
    }
}

/// A neutral share bar for model rows.
struct AILimitBarShare: View {
    var fraction: Double
    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule().fill(Color.cyan.opacity(0.7)).frame(width: max(3, proxy.size.width * min(1, max(0, fraction))))
            }
        }.frame(height: 4)
    }
}

/// Monthly totals as bars, newest on the right, with the selected month's numbers above.
struct TokenHistoryChart: View {
    let months: [NotchTokenPeriod]
    let count: (Int64) -> String
    let cost: (NotchTokenPeriod) -> String
    @State private var hovered: String?
    private var shown: [NotchTokenPeriod] { Array(months.prefix(12).reversed()) }
    private var focus: NotchTokenPeriod? { shown.first { $0.id == hovered } ?? shown.last }
    /// Month IDs are "yyyy-MM".
    private func label(_ month: NotchTokenPeriod, long: Bool) -> String {
        let parser = DateFormatter(); parser.dateFormat = "yyyy-MM"; parser.locale = Locale(identifier: "en_US_POSIX")
        guard let date = parser.date(from: month.id) else { return month.title }
        return date.formatted(long ? .dateTime.month(.wide).year() : .dateTime.month(.abbreviated))
    }

    var body: some View {
        if shown.isEmpty {
            Text("No monthly history yet.").font(.system(size: 11)).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let peak = max(1, shown.map(\.tokens).max() ?? 1)
            VStack(alignment: .leading, spacing: 8) {
                if let focus {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(label(focus, long: true)).font(.system(size: 12, weight: .semibold))
                        Text(count(focus.tokens) + " tokens").font(.system(size: 12)).monospacedDigit()
                        Text(cost(focus)).font(.system(size: 12, weight: .semibold)).foregroundStyle(.cyan).monospacedDigit()
                        if focus.coverage < 1 {
                            Text(String(format: "%.0f%% priced", focus.coverage * 100)).font(.system(size: 9)).foregroundStyle(.orange)
                        }
                        Spacer()
                        Text("\(shown.count) months · hover a bar").font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                }
                HStack(alignment: .bottom, spacing: 6) {
                    ForEach(shown) { month in
                        VStack(spacing: 4) {
                            Spacer(minLength: 0)
                            RoundedRectangle(cornerRadius: 3)
                                .fill(month.id == focus?.id ? Color.cyan : Color.cyan.opacity(0.35))
                                .frame(height: max(2, 120 * CGFloat(month.tokens) / CGFloat(peak)))
                            Text(label(month, long: false)).font(.system(size: 8)).foregroundStyle(month.id == focus?.id ? .primary : .secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                        .onHover { hovered = $0 ? month.id : (hovered == month.id ? nil : hovered) }
                        .help("\(label(month, long: true)): \(count(month.tokens)) tokens · \(cost(month))")
                    }
                }
            }
        }
    }
}
