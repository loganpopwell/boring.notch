import Defaults
import SwiftUI

/// A short closed-notch message about the AI accounts, such as the proxy going down or an account hitting its limit.
struct AIAlert: Equatable, Identifiable {
    let id = UUID()
    var title: String
    var subtitle: String
    var icon: String
    var tint: Color
}

/// Shared account-quota state for the closed-notch ring, its alerts, and the Tokens tab's Limits view.
@MainActor final class AIStatusModel: ObservableObject {
    static let shared = AIStatusModel()
    @Published private(set) var status: NotchAIStatus?
    @Published private(set) var alert: AIAlert?
    @Published private(set) var restarting = false
    /// Set while the Limits view is open; it asks for each account's full limits.
    @Published var detailedViewers = 0 { didSet { if detailedViewers > oldValue { refresh() } } }
    private var connection: NSXPCConnection?
    private var loading = false
    private var hideTask: Task<Void, Never>?
    private var warned: Set<String> = []

    private init() {
        Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if Defaults[.showAIQuotaRing] || Defaults[.showAIAlerts] || self.detailedViewers > 0 { self.refresh() }
                try? await Task.sleep(for: .seconds(self.detailedViewers > 0 ? 45 : 30))
            }
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
                guard let next else { return }
                if let previous = model.status { model.compare(previous, next) }
                model.status = next
            }
        }
    }

    func restartProxy() {
        guard !restarting, let helper = helper() else { return }
        restarting = true
        helper.restartAIProxy { ok in
            Task { @MainActor in
                let model = AIStatusModel.shared
                model.restarting = false
                if !ok { model.show(AIAlert(title: "Couldn't restart CLI Proxy", subtitle: "Check its LaunchAgent", icon: "xmark.octagon.fill", tint: .red)) }
                try? await Task.sleep(for: .seconds(2))
                model.refresh()
            }
        }
    }

    func dismissAlert() { hideTask?.cancel(); alert = nil }

    private func show(_ value: AIAlert) {
        guard Defaults[.showAIAlerts] else { return }
        alert = value
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.alert = nil
        }
    }

    /// Alerts fire on changes only, never for the state found at launch.
    private func compare(_ old: NotchAIStatus, _ new: NotchAIStatus) {
        if old.proxyReachable && !new.proxyReachable && new.proxyConfigured {
            show(AIAlert(title: "CLI Proxy stopped responding", subtitle: "Claude Code requests will fail · restart it in Tokens › Limits",
                         icon: "exclamationmark.triangle.fill", tint: .orange))
            return
        }
        if !old.proxyReachable && old.proxyConfigured && new.proxyReachable {
            show(AIAlert(title: "CLI Proxy is back", subtitle: "\(new.claudeAccounts.filter(\.usable).count) Claude accounts available",
                         icon: "checkmark.circle.fill", tint: .green))
            return
        }
        for account in new.accounts {
            guard let before = old.accounts.first(where: { $0.id == account.id }) else { continue }
            if account.state == "limited" && before.state != "limited" {
                let window = account.windows.first { $0.limited || $0.percent >= 100 }
                show(AIAlert(title: "\(account.label) hit its \(window?.title.lowercased() ?? "usage") limit",
                             subtitle: window?.resetsAt.map { "Resets " + Self.relative($0) } ?? "Requests move to the next account",
                             icon: "gauge.with.dots.needle.100percent", tint: .red))
                return
            }
        }
        if let previous = old.lastUsed, let current = new.lastUsed, previous.id != current.id,
           let then = new.accounts.first(where: { $0.id == previous.id }), !then.usable {
            show(AIAlert(title: "Switched to \(current.label)", subtitle: "\(previous.label) is \(then.state == "limited" ? "at its limit" : "unavailable")",
                         icon: "arrow.triangle.swap", tint: .cyan))
            return
        }
        let threshold = Defaults[.aiRingWarnPercent]
        if let account = new.ringAccount, let window = account.tightest {
            let key = account.id + window.id + String(window.resetsAt?.timeIntervalSince1970 ?? 0)
            if window.percent >= threshold, window.percent < 100, !warned.contains(key),
               (old.ringAccount?.windows.first { $0.id == window.id }?.percent ?? 0) < threshold {
                warned.insert(key)
                show(AIAlert(title: "\(account.label) at \(Int(window.percent))% of its \(window.title.lowercased()) limit",
                             subtitle: window.resetsAt.map { "Resets " + Self.relative($0) } ?? "",
                             icon: "gauge.with.dots.needle.67percent", tint: .orange))
            }
        }
    }

    static func relative(_ date: Date) -> String {
        let seconds = max(0, date.timeIntervalSinceNow)
        if seconds < 3600 { return "in \(Int(seconds / 60))m" }
        if seconds < 86400 { return "in \(Int(seconds / 3600))h \(Int(seconds.truncatingRemainder(dividingBy: 3600) / 60))m" }
        return "in \(Int(seconds / 86400))d \(Int(seconds.truncatingRemainder(dividingBy: 86400) / 3600))h"
    }
}

/// The closed-notch ring: the tightest limit of the account that last answered through the proxy.
struct AIQuotaRing: View {
    var status: NotchAIStatus
    var size: CGFloat
    @Default(.aiRingWarnPercent) private var warn

    private var account: NotchQuotaAccount? { status.ringAccount }
    private var window: NotchQuotaWindow? { account?.tightest }
    private var down: Bool { status.proxyConfigured && !status.proxyReachable }
    private var fraction: Double { down ? 1 : min(1, max(0, (window?.percent ?? 0) / 100)) }
    private var tint: Color { AIQuotaRing.tint(window: window, state: account?.state, down: down, warn: warn) }

    static func tint(window: NotchQuotaWindow?, state: String?, down: Bool = false, warn: Double) -> Color {
        if down { return .gray }
        if state == "limited" || state == "error" || (window?.percent ?? 0) >= 95 { return .red }
        if (window?.percent ?? 0) >= warn || state == "cooldown" { return .orange }
        return .mint
    }

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.14), lineWidth: max(2, size * 0.13))
            Circle().trim(from: 0, to: fraction)
                .stroke(tint, style: StrokeStyle(lineWidth: max(2, size * 0.13), lineCap: .round))
                .rotationEffect(.degrees(-90))
            if down {
                Image(systemName: "exclamationmark").font(.system(size: size * 0.45, weight: .bold)).foregroundStyle(.gray)
            } else {
                Text(window.map { String(Int($0.percent.rounded())) } ?? "–")
                    .font(.system(size: size * 0.36, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(.white.opacity(0.9)).minimumScaleFactor(0.5)
            }
        }
        .frame(width: size, height: size)
        .animation(.smooth, value: fraction)
        .help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(help)
    }

    private var help: String {
        if down { return status.proxyError ?? "CLI Proxy is not responding" }
        guard let account, let window else { return "No quota reading yet" }
        let reset = window.resetsAt.map { " · resets " + AIStatusModel.relative($0) } ?? ""
        return "\(account.label): \(Int(window.percent))% of \(window.title.lowercased()) limit\(reset)"
    }
}

/// Wide closed-notch banner for an `AIAlert`, matching the now-playing fallback notice.
struct AIAlertBanner: View {
    var alert: AIAlert
    var width: CGFloat
    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: alert.icon).font(.system(size: 16, weight: .semibold)).foregroundStyle(alert.tint)
                .frame(width: 24, height: 24).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(alert.title).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                if !alert.subtitle.isEmpty { Text(alert.subtitle).font(.caption).foregroundStyle(.white.opacity(0.62)) }
            }.lineLimit(2)
            Spacer(minLength: 5)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .frame(width: width).frame(minHeight: 58)
        .accessibilityElement(children: .combine)
        .onTapGesture { AIStatusModel.shared.dismissAlert() }
    }
}

/// Every account's limits, for the Tokens tab.
struct AILimitsPanel: View {
    @ObservedObject private var model = AIStatusModel.shared
    @Default(.showAIQuotaRing) private var showRing
    @Default(.aiRingWarnPercent) private var warn

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            ScrollView {
                VStack(spacing: 4) {
                    if let status = model.status {
                        ForEach(status.accounts) { row($0, status: status) }
                        if status.accounts.isEmpty {
                            Text("No accounts found. CLI Proxy needs ~/.config/cliproxyapi/management-key.")
                                .foregroundStyle(.secondary).font(.system(size: 11)).padding(.top, 20)
                        }
                    } else {
                        Text("Reading account limits…").foregroundStyle(.secondary).font(.system(size: 11)).padding(.top, 20)
                    }
                }
            }.frame(height: 161)
        }
        .onAppear { model.detailedViewers += 1 }
        .onDisappear { model.detailedViewers = max(0, model.detailedViewers - 1) }
    }

    private var header: some View {
        HStack(spacing: 6) {
            let status = model.status
            Circle().fill(status == nil ? .gray : status!.proxyReachable ? .mint : status!.proxyConfigured ? .orange : .gray).frame(width: 6, height: 6)
            Text(status.map { $0.proxyReachable ? "CLI Proxy connected" : ($0.proxyError ?? "CLI Proxy not set up") } ?? "Checking CLI Proxy…")
            if let next = status?.next { Text("· next: \(next.label)").foregroundStyle(.secondary) }
            Spacer()
            Toggle("Ring in notch", isOn: $showRing).toggleStyle(.switch).controlSize(.mini)
                .help("Show the quota ring in the closed notch")
            if status?.restartAvailable == true {
                Button { model.restartProxy() } label: {
                    if model.restarting { ProgressView().controlSize(.mini) } else { Label("Restart", systemImage: "arrow.counterclockwise") }
                }.buttonStyle(.plain).disabled(model.restarting)
                    .help("Restart CLI Proxy. Clears stalled connections after a network change.")
            }
        }.font(.system(size: 10)).lineLimit(1)
    }

    private func row(_ account: NotchQuotaAccount, status: NotchAIStatus) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Image(systemName: account.provider == "codex" ? "chevron.left.forwardslash.chevron.right" : "sparkle")
                        .font(.system(size: 8)).foregroundStyle(.secondary)
                    Text(account.label).fontWeight(.medium)
                    if account.id == status.lastUsedID { badge("LAST USED", .cyan) }
                    else if account.id == status.nextID { badge("NEXT", .mint) }
                }
                Text(subtitle(account)).font(.system(size: 9)).foregroundStyle(account.usable ? Color.secondary : Color.orange)
            }.frame(width: 150, alignment: .leading)
            HStack(spacing: 8) {
                if account.windows.isEmpty {
                    Text(account.provider == "codex" ? "No recent Codex session" : "No reading yet · opens with first request")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                }
                ForEach(account.windows.prefix(3)) { window in bar(window, state: account.state) }
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 11)).lineLimit(1)
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .secondarySystemFill)))
        .help(account.message ?? "")
    }

    private func subtitle(_ account: NotchQuotaAccount) -> String {
        switch account.state {
        case "limited": return "At limit"
        case "cooldown": return "Cooling down"
        case "disabled": return "Disabled in CLI Proxy"
        case "error": return account.message ?? "Error"
        default:
            if account.provider == "codex" { return "Native login" + (account.observedAt.map { " · seen " + $0.formatted(.relative(presentation: .named)) } ?? "") }
            return (account.priority.map { "Priority \($0)" } ?? "") + (account.recentRequests > 0 ? " · \(account.recentRequests) recent requests" : "")
        }
    }

    private func bar(_ window: NotchQuotaWindow, state: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 3) {
                Text(window.title).foregroundStyle(.secondary)
                Spacer(minLength: 2)
                Text("\(Int(window.percent.rounded()))%").monospacedDigit()
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.1))
                    Capsule().fill(AIQuotaRing.tint(window: window, state: window.limited ? "limited" : nil, warn: warn))
                        .frame(width: max(2, proxy.size.width * min(1, window.percent / 100)))
                }
            }.frame(height: 4)
            Text(window.resetsAt.map { "resets " + AIStatusModel.relative($0) } ?? "not started").font(.system(size: 8)).foregroundStyle(.secondary)
        }
        .font(.system(size: 9)).frame(width: 112)
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text).font(.system(size: 7, weight: .bold)).tracking(0.3).foregroundStyle(color)
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.15)))
    }
}
