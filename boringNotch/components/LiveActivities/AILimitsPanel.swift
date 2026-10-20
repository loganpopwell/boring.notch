import SwiftUI

/// Account-limit readings for the Tokens tab. It only polls while a view that shows limits is open.
@MainActor final class AIStatusModel: ObservableObject {
    static let shared = AIStatusModel()
    @Published private(set) var status: NotchAIStatus?
    @Published private(set) var restarting = false
    @Published private(set) var restartFailed = false
    /// Views showing limit summaries. They need only the cheap header readings.
    @Published var viewers = 0 { didSet { viewersChanged(grew: viewers > oldValue) } }
    /// Views showing every account's full limits, which asks Anthropic for weekly windows too.
    @Published var detailedViewers = 0 { didSet { viewersChanged(grew: detailedViewers > oldValue) } }
    private var connection: NSXPCConnection?
    private var loading = false
    private var poller: Task<Void, Never>?

    private init() {}

    private func viewersChanged(grew: Bool) {
        let watching = viewers + detailedViewers > 0
        if watching, poller == nil {
            poller = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    self.refresh()
                    try? await Task.sleep(for: .seconds(self.detailedViewers > 0 ? 45 : 30))
                }
            }
        } else if !watching {
            poller?.cancel(); poller = nil
        } else if grew {
            refresh()
        }
    }

    private func helper() -> BoringNotchXPCHelperProtocol? {
        if connection == nil {
            let value = NSXPCConnection(serviceName: "theboringteam.boringnotch.BoringNotchXPCHelper")
            value.remoteObjectInterface = NSXPCInterface(with: BoringNotchXPCHelperProtocol.self)
            value.invalidationHandler = { Task { @MainActor in AIStatusModel.shared.connection = nil } }
            value.resume(); connection = value
        }
        return connection?.remoteObjectProxyWithErrorHandler { _ in
            Task { @MainActor in AIStatusModel.shared.loading = false }
        } as? BoringNotchXPCHelperProtocol
    }

    func refresh() {
        guard !loading, let helper = helper() else { return }
        loading = true
        helper.readAIStatus(detailedViewers > 0) { data in
            let next = data.flatMap { try? JSONDecoder().decode(NotchAIStatus.self, from: $0) }
            Task { @MainActor in
                let model = AIStatusModel.shared
                model.loading = false
                if let next { model.status = next }
            }
        }
    }

    func restartProxy() {
        guard !restarting, let helper = helper() else { return }
        restarting = true; restartFailed = false
        helper.restartAIProxy { ok in
            Task { @MainActor in
                let model = AIStatusModel.shared
                model.restarting = false
                model.restartFailed = !ok
                try? await Task.sleep(for: .seconds(2))
                model.refresh()
            }
        }
    }

    static func relative(_ date: Date) -> String {
        let seconds = max(0, date.timeIntervalSinceNow)
        if seconds < 60 { return "in <1m" }
        if seconds < 3600 { return "in \(Int(seconds / 60))m" }
        if seconds < 86400 { return "in \(Int(seconds / 3600))h \(Int(seconds.truncatingRemainder(dividingBy: 3600) / 60))m" }
        return "in \(Int(seconds / 86400))d \(Int(seconds.truncatingRemainder(dividingBy: 86400) / 3600))h"
    }

    /// Mint with room left, orange past 75%, red near or at the limit.
    static func tint(_ percent: Double, limited: Bool = false) -> Color {
        if limited || percent >= 95 { return .red }
        if percent >= 75 { return .orange }
        return .mint
    }
}

/// A thin usage bar for one limit window.
struct AILimitBar: View {
    var percent: Double
    var limited = false
    var height: CGFloat = 5
    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.1))
                Capsule().fill(AIStatusModel.tint(percent, limited: limited))
                    .frame(width: max(height, proxy.size.width * min(1, max(0, percent) / 100)))
            }
        }
        .frame(height: height)
        .animation(.smooth, value: percent)
    }
}

/// Every account's limits, for the Tokens tab.
struct AILimitsPanel: View {
    @ObservedObject private var model = AIStatusModel.shared
    var height: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            ScrollView {
                VStack(spacing: 5) {
                    if let status = model.status {
                        ForEach(ordered(status)) { row($0, status: status) }
                        if status.accounts.isEmpty {
                            Text("No accounts found. CLI Proxy needs ~/.config/cliproxyapi/management-key.")
                                .foregroundStyle(.secondary).font(.system(size: 11)).padding(.top, 30)
                        }
                    } else {
                        ProgressView().controlSize(.small).padding(.top, 40)
                    }
                }
            }
            .scrollIndicators(.never)
        }
        .frame(height: height, alignment: .top)
        .onAppear { model.detailedViewers += 1 }
        .onDisappear { model.detailedViewers = max(0, model.detailedViewers - 1) }
    }

    /// The account in use first, then the rest by how soon they would be picked, Codex last.
    private func ordered(_ status: NotchAIStatus) -> [NotchQuotaAccount] {
        let active = status.activeClaude?.id
        return status.accounts.sorted { a, b in
            func rank(_ x: NotchQuotaAccount) -> (Int, Int, Int) {
                (x.provider == "codex" ? 2 : x.id == active ? 0 : 1, x.usable ? 0 : 1, -(x.priority ?? 0))
            }
            return rank(a) < rank(b)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            let status = model.status
            let claude = status?.claudeAccounts ?? []
            Circle().fill(status == nil ? .gray : status!.proxyReachable ? .mint : status!.proxyConfigured ? .orange : .gray)
                .frame(width: 6, height: 6)
            if let status {
                Text(status.proxyReachable ? "CLI Proxy connected" : (status.proxyError ?? "CLI Proxy not set up"))
                if status.proxyReachable, !claude.isEmpty {
                    Text("· \(claude.filter(\.usable).count) of \(claude.count) Claude accounts available").foregroundStyle(.secondary)
                }
            } else {
                Text("Checking CLI Proxy…")
            }
            Spacer()
            if model.restartFailed { Text("Restart failed · check its LaunchAgent").foregroundStyle(.red) }
            if status?.restartAvailable == true {
                Button { model.restartProxy() } label: {
                    if model.restarting { ProgressView().controlSize(.mini) } else { Label("Restart proxy", systemImage: "arrow.counterclockwise") }
                }.buttonStyle(.plain).foregroundStyle(.secondary).disabled(model.restarting)
                    .help("Restart CLI Proxy. Clears stalled connections after a network change.")
            }
        }.font(.system(size: 10)).lineLimit(1)
    }

    private func row(_ account: NotchQuotaAccount, status: NotchAIStatus) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Image(systemName: account.provider == "codex" ? "chevron.left.forwardslash.chevron.right" : "sparkle")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                    Text(account.provider == "codex" ? "Codex" : account.label).font(.system(size: 12, weight: .semibold))
                }
                HStack(spacing: 4) {
                    if let badge = badge(account, status: status) { pill(badge.0, badge.1) }
                    Text(subtitle(account)).foregroundStyle(.secondary)
                }.font(.system(size: 9))
            }
            .frame(width: 160, alignment: .leading)
            if account.windows.isEmpty {
                Text(account.provider == "codex" ? "No Codex session in the last three days" : "No reading yet · appears after its first request")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else {
                ForEach(account.windows.prefix(3)) { window($0) }
                ForEach(0..<max(0, 3 - account.windows.count), id: \.self) { _ in Color.clear.frame(maxWidth: .infinity) }
            }
        }
        .lineLimit(1)
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color(nsColor: .secondarySystemFill).opacity(account.usable ? 1 : 0.55)))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(account.id == status.activeClaude?.id ? Color.cyan.opacity(0.45) : .clear, lineWidth: 1))
        .help(account.message ?? "")
    }

    private func window(_ window: NotchQuotaWindow) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(window.title).font(.system(size: 9)).foregroundStyle(.secondary)
                Spacer(minLength: 2)
                Text("\(Int(window.percent.rounded()))%").font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(AIStatusModel.tint(window.percent, limited: window.limited))
            }
            AILimitBar(percent: window.percent, limited: window.limited)
            Text(window.resetsAt.map { "Resets " + AIStatusModel.relative($0) } ?? "Not started")
                .font(.system(size: 8)).foregroundStyle(.secondary)
                .help(window.resetsAt?.formatted(date: .abbreviated, time: .shortened) ?? "")
        }
        .frame(maxWidth: .infinity)
    }

    private func badge(_ account: NotchQuotaAccount, status: NotchAIStatus) -> (String, Color)? {
        switch account.state {
        case "limited": return ("AT LIMIT", .red)
        case "cooldown": return ("COOLING DOWN", .orange)
        case "disabled": return ("DISABLED", .gray)
        case "error": return ("ERROR", .red)
        default:
            if account.id == status.activeClaude?.id { return ("IN USE", .cyan) }
            if account.id == status.nextID { return ("NEXT", .mint) }
            return nil
        }
    }

    private func subtitle(_ account: NotchQuotaAccount) -> String {
        if account.provider == "codex" { return account.observedAt.map { "Seen " + $0.formatted(.relative(presentation: .named)) } ?? "Native login" }
        if account.state == "error" { return account.message ?? "" }
        var parts: [String] = []
        if let priority = account.priority { parts.append("Priority \(priority)") }
        if account.recentRequests > 0 { parts.append("\(account.recentRequests) recent") }
        return parts.joined(separator: " · ")
    }

    private func pill(_ text: String, _ color: Color) -> some View {
        Text(text).font(.system(size: 7, weight: .bold)).tracking(0.3).foregroundStyle(color)
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.15)))
    }
}

/// A compact limit card for the Tokens overview: the tightest window of the Claude account in use, or of Codex.
struct AILimitSummary: View {
    @ObservedObject private var model = AIStatusModel.shared
    var provider: String
    var onOpen: () -> Void

    private var account: NotchQuotaAccount? {
        provider == "codex" ? model.status?.codex : model.status?.activeClaude
    }
    private var down: Bool { provider != "codex" && model.status.map { $0.proxyConfigured && !$0.proxyReachable } == true }

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 3) {
                Text(provider == "codex" ? "CODEX LIMIT" : "CLAUDE LIMIT")
                    .font(.system(size: 8, weight: .medium)).tracking(0.4).foregroundStyle(.secondary)
                if down {
                    Text("Proxy down").font(.system(size: 17, weight: .semibold, design: .rounded)).foregroundStyle(.orange)
                    Text("Open Limits to restart").font(.system(size: 9)).foregroundStyle(.secondary)
                } else if let account, let window = account.tightest {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("\(Int(window.percent.rounded()))%")
                            .font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
                            .foregroundStyle(AIStatusModel.tint(window.percent, limited: window.limited || account.state == "limited"))
                        Text(window.title.lowercased()).font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                    AILimitBar(percent: window.percent, limited: window.limited || account.state == "limited", height: 4)
                    Text((provider == "codex" ? "" : account.label + " · ") + (window.resetsAt.map { "resets " + AIStatusModel.relative($0) } ?? "not started"))
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                } else {
                    Text("–").font(.system(size: 20, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
                    Text(model.status == nil ? "Reading limits…" : "No reading yet").font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(.horizontal, 11).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 11).fill(Color(nsColor: .secondarySystemFill)))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(.white.opacity(0.08), lineWidth: 0.7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open every account's limits")
        .onAppear { model.viewers += 1 }
        .onDisappear { model.viewers = max(0, model.viewers - 1) }
    }
}
