import SwiftUI

@MainActor final class TokenUsageModel: ObservableObject {
    @Published var snapshot: NotchTokenSnapshot?
    @Published var failure: String?
    @Published var loading = false
    private var connection: NSXPCConnection?
    private var requestID = UUID()

    func refresh() {
        guard !loading else { return }
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
                    self.snapshot = next; self.failure = next.error
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
    private var period: NotchTokenPeriod? { model.snapshot?.periods.first { $0.id == selected } }
    private var stale: Bool { model.snapshot.map { Date().timeIntervalSince($0.sampledAt) > 3600 } ?? false }
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
                    Button { history = true } label: { Image(systemName: "calendar") }.buttonStyle(.plain).help("Monthly history").accessibilityLabel("Monthly token history")
                }
                Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).disabled(model.loading).help("Reload AI Token Meter report").accessibilityLabel("Refresh token usage")
                Button(action: openMeter) { Image(systemName: "arrow.up.forward.app") }
                    .buttonStyle(.plain).help("Open AI Token Meter to update history").accessibilityLabel("Open AI Token Meter")
            }.font(.system(size: 11))
            if let failure = model.failure {
                VStack(spacing: 8) {
                    Text(failure).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Open AI Token Meter", action: openMeter).buttonStyle(.plain)
                }.font(.system(size: 12)).frame(maxWidth: .infinity, minHeight: history ? 198 : 70)
            } else if history, let snapshot = model.snapshot {
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
                }.frame(height: 198)
            } else if let p = period {
                HStack(spacing: 8) {
                    metric("LOCAL CODEX TOKENS", value: count(p.tokens), subtitle: selected == "lifetime" ? "Recorded history on this Mac" : p.title, accent: false)
                    metric("API-EQUIVALENT COST", value: cost(p), subtitle: p.coverage < 1 ? String(format: "%.1f%% priced · partial USD estimate", floor(p.coverage * 1000) / 10) : "Estimated USD · not your bill", accent: true)
                }
                HStack(spacing: 6) {
                    tokenPiece("Input", p.input)
                    tokenPiece("Cached", p.cached)
                    tokenPiece("Output", p.output)
                    Spacer(minLength: 0)
                    if selected == "lifetime", let account = model.snapshot?.accountLifetimeTokens {
                        Text("Account: " + count(account)).foregroundStyle(.secondary)
                            .help("AI Token Meter's separate account lifetime total, as of \(model.snapshot?.accountReadAt?.formatted(date: .abbreviated, time: .shortened) ?? "unknown"). It is not added to local usage or used to estimate cost.")
                    }
                }.font(.system(size: 10)).lineLimit(1)
            } else {
                Text("Reading token history…").font(.system(size: 12)).foregroundStyle(.secondary).frame(height: 80)
            }
            HStack(spacing: 5) {
                Circle().fill(stale ? .orange : .mint).frame(width: 4, height: 4)
                if let date = model.snapshot?.sampledAt, date > .distantPast {
                    Text(stale ? "Last scan" : "Updated")
                    Text(date, style: .relative)
                    Text("ago · AI Token Meter")
                } else { Text("Local history · AI Token Meter") }
                Spacer(minLength: 0)
                Text(history ? "USD estimate · partial pricing marked" : (model.snapshot?.cacheCountsInconsistent == true ? "Some source cache counts inconsistent" : "Cached tokens are part of input"))
            }.font(.system(size: 9)).foregroundStyle(stale ? .orange : .secondary).lineLimit(1)
        }
        .padding(.horizontal, 12).frame(width: 600)
        .onChange(of: history) { _, value in
            withAnimation(.smooth(duration: 0.25)) { vm.notchSize.height = value ? 320 : openNotchSize.height }
        }
        .onDisappear { if vm.notchState == .open { vm.notchSize.height = openNotchSize.height } }
        .task {
            while !Task.isCancelled {
                model.refresh()
                do { try await Task.sleep(for: .seconds(30)) } catch { break }
            }
        }
    }
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
