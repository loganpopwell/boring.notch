import SwiftUI

@MainActor final class TokenUsageModel: ObservableObject {
    @Published var snapshot: NotchTokenSnapshot?
    @Published var failure: String?
    @Published var loading = false
    private var connection: NSXPCConnection?
    private var requestID = UUID()
    private var lastMeterLaunch = Date.distantPast

    func refresh() {
        guard !loading else { return }
        // The report writer is a separate menu-bar app. Relaunch it quietly if it has stopped.
        if !NSRunningApplication.runningApplications(withBundleIdentifier: "local.codex-token-meter").isEmpty {
            lastMeterLaunch = .distantPast
        } else if Date().timeIntervalSince(lastMeterLaunch) > 60,
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
                    self.snapshot = next; self.failure = nil
                } else {
                    self.failure = "Could not read the meter. Try refreshing."
                    self.connection?.invalidate(); self.connection = nil
                }
            }
        }
        if let proxy = connection?.remoteObjectProxyWithErrorHandler({ _ in finish(nil) }) as? BoringNotchXPCHelperProtocol {
            proxy.readTokenUsage(with: finish)
        } else { finish(nil) }
        Task { try? await Task.sleep(for: .seconds(5)); if requestID == id && loading { finish(nil) } }
    }
    deinit { connection?.invalidate() }
}

struct TokenUsageView: View {
    @EnvironmentObject var vm: BoringViewModel
    @StateObject private var model = TokenUsageModel()
    @State private var selected = "month"
    @State private var history = false
    @State private var panel = "overview"
    @State private var selectedModelID: String?
    @State private var provider = "all"
    private var source: NotchTokenSource? { model.snapshot?.source(provider) }
    private var failure: String? { model.failure ?? source?.error }
    private var providerTitle: String { provider == "codex" ? "Codex" : provider == "claude" ? "Claude Code" : "Codex + Claude" }
    private var expanded: Bool { history || panel != "overview" }
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
            HStack(spacing: 6) {
                ForEach([("all", "All"), ("codex", "Codex"), ("claude", "Claude Code")], id: \.0) { id, title in
                    Button { provider = id; selectedModelID = nil; if panel == "detail" { panel = "models" } } label: {
                        Text(title).padding(.horizontal, 9).padding(.vertical, 3)
                            .background(Capsule().fill(provider == id ? Color.white.opacity(0.12) : .clear))
                    }.buttonStyle(.plain).foregroundStyle(provider == id ? .primary : .secondary)
                }
                Spacer()
                Text("Local token usage").foregroundStyle(.secondary)
            }.font(.system(size: 10))
            HStack(spacing: 7) {
                if history {
                    Button { history = false } label: { Label("Overview", systemImage: "chevron.left") }.buttonStyle(.plain)
                    Spacer()
                    Text("Monthly history").fontWeight(.semibold)
                } else {
                    ForEach([("today", "Today"), ("month", "This month"), ("lifetime", "Lifetime")], id: \.0) { id, title in
                        Button { selected = id } label: {
                            Text(title).padding(.horizontal, 10).padding(.vertical, 4)
                                .background(Capsule().fill(selected == id ? Color.white.opacity(0.12) : .clear))
                        }.buttonStyle(.plain).foregroundStyle(selected == id ? .primary : .secondary)
                    }
                    Spacer()
                    Button("Models") { panel = panel == "models" ? "overview" : "models"; selectedModelID = nil }.buttonStyle(.plain)
                        .foregroundStyle(panel == "models" || panel == "detail" ? .cyan : .secondary)
                    Button("Pricing") { panel = panel == "pricing" ? "overview" : "pricing"; selectedModelID = nil }.buttonStyle(.plain)
                        .foregroundStyle(panel == "pricing" ? .cyan : .secondary)
                    Button { history = true; panel = "overview" } label: { Image(systemName: "calendar") }.buttonStyle(.plain).help("Monthly history").accessibilityLabel("Monthly token history")
                }
                Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).disabled(model.loading).help("Refresh Codex and Claude usage").accessibilityLabel("Refresh token usage")
                Button(action: openMeter) { Image(systemName: "arrow.up.forward.app") }
                    .buttonStyle(.plain).help("Open AI Token Meter to update history").accessibilityLabel("Open AI Token Meter")
            }.font(.system(size: 11))
            if let failure = failure {
                VStack(spacing: 8) {
                    Text(failure).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Open AI Token Meter", action: openMeter).buttonStyle(.plain)
                }.font(.system(size: 12)).frame(maxWidth: .infinity, minHeight: history ? 198 : 70)
            } else if history, let snapshot = source {
                ScrollView {
                    LazyVStack(spacing: 5) {
                        ForEach(snapshot.months) { month in
                            HStack {
                                Text(month.title).fontWeight(.medium)
                                Spacer()
                                Text(count(month.tokens) + " tokens").foregroundStyle(.secondary)
                                Text(cost(month)).foregroundStyle(.cyan).frame(width: 105, alignment: .trailing)
                                if month.coverage < 1 { Image(systemName: "circle.lefthalf.filled").help("Partially priced") }
                            }.font(.system(size: 12)).monospacedDigit().padding(9)
                                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .secondarySystemFill)))
                        }
                    }
                }.frame(height: 176)
            } else if panel != "overview", let p = period {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Button { panel = panel == "detail" ? "models" : "overview"; selectedModelID = nil } label: {
                            Label(panel == "detail" ? "Models" : "Overview", systemImage: "chevron.left")
                        }.buttonStyle(.plain)
                        Spacer()
                        Text(panel == "pricing" ? "Model prices" : panel == "detail" ? "Model details" : "Models · " + p.title).fontWeight(.semibold)
                    }.font(.system(size: 10))
                    ScrollView {
                        if panel == "pricing" { TokenPricingChart(period: p, onSelect: openModel) }
                        else if panel == "detail", let chosenModel { TokenModelDetail(model: chosenModel, period: p) }
                        else { TokenModelList(period: p, onSelect: openModel) }
                    }.frame(height: 161)
                }
            } else if let p = period {
                HStack(spacing: 8) {
                    metric(providerTitle.uppercased() + " TOKENS", value: count(p.tokens), subtitle: selected == "lifetime" ? (provider == "codex" ? "Recorded history on this Mac" : "Retained history on this Mac") : p.title, accent: false)
                    metric("API-EQUIVALENT COST", value: cost(p), subtitle: p.coverage < 1 ? String(format: "%.1f%% priced · partial USD estimate", floor(p.coverage * 1000) / 10) : (p.models.contains(where: \.hasProxy) ? "Estimated USD · includes proxy pricing" : "Estimated USD · not your bill"), accent: true)
                }
                HStack(spacing: 6) {
                    tokenPiece("Input", p.input)
                    tokenPiece("Cached", p.cached)
                    tokenPiece("Output", p.output)
                    Spacer(minLength: 0)
                    if provider == "codex", selected == "lifetime", let account = model.snapshot?.accountLifetimeTokens {
                        Text("Account: " + count(account)).foregroundStyle(.secondary)
                            .help("AI Token Meter's separate account lifetime total, as of \(model.snapshot?.accountReadAt?.formatted(date: .abbreviated, time: .shortened) ?? "unknown"). It is not added to local usage or used to estimate cost.")
                    }
                }.font(.system(size: 10)).lineLimit(1)
            } else {
                Text("Reading token history…").font(.system(size: 12)).foregroundStyle(.secondary).frame(height: 80)
            }
            HStack(spacing: 5) {
                Circle().fill(stale ? .orange : .mint).frame(width: 4, height: 4)
                if let date = source?.sampledAt, date > .distantPast {
                    Text(stale ? "Last scan" : "Updated")
                    Text(date, style: .relative)
                    Text(provider == "claude" ? "ago · Local Claude Code" : provider == "codex" ? "ago · AI Token Meter" : "ago · Local sources")
                } else { Text("Local history · AI Token Meter") }
                Spacer(minLength: 0)
                Text(source?.notice ?? (history ? "USD estimate · partial pricing marked" : (source?.cacheCountsInconsistent == true ? "Some source cache counts inconsistent" : "Cached tokens are part of input")))
            }.font(.system(size: 9)).foregroundStyle(stale || source?.notice != nil ? .orange : .secondary).lineLimit(1)
        }
        .padding(.horizontal, 12).frame(width: 600)
        .onChange(of: expanded) { _, value in
            withAnimation(.smooth(duration: 0.25)) { vm.notchSize.height = value ? 320 : max(openNotchSize.height, 210) }
        }
        .onDisappear { if vm.notchState == .open { vm.notchSize.height = openNotchSize.height } }
        .task {
            withAnimation(.smooth(duration: 0.25)) { vm.notchSize.height = expanded ? 320 : max(openNotchSize.height, 210) }
            while !Task.isCancelled {
                model.refresh()
                do { try await Task.sleep(for: .seconds(30)) } catch { break }
            }
        }
    }
    private func openModel(_ value: NotchTokenModel) { selectedModelID = value.id; panel = "detail" }
    private func tokenPiece(_ title: String, _ amount: Int64) -> some View {
        HStack(spacing: 3) { Text(title).foregroundStyle(.secondary); Text(count(amount)).monospacedDigit() }
            .padding(.trailing, 8).help(amount.formatted() + " " + title.lowercased() + " tokens")
    }
    private func metric(_ title: String, value: String, subtitle: String, accent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 8, weight: .medium)).tracking(0.4).foregroundStyle(.secondary)
            Text(value).font(.system(size: 23, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(accent ? Color.cyan : .white).lineLimit(1).minimumScaleFactor(0.7)
            Text(subtitle).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 11).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 11).fill(Color(nsColor: .secondarySystemFill)))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(.white.opacity(0.08), lineWidth: 0.7))
    }
}
