import SwiftUI

@MainActor final class SystemStatsModel: ObservableObject {
    @Published var sample = SystemStatsSample()
    @Published var history: [Double] = []
    private let queue = DispatchQueue(label: "local.boringnotch.stats", qos: .utility)
    private let reader = SystemStatsReader()
    @Published var processes: NotchProcessSnapshot?
    @Published var processError: String?
    private var processConnection: NSXPCConnection?
    private var requestInFlight = false
    private var requestID = UUID()
    func readProcesses() {
        guard !requestInFlight else { return }
        if processConnection == nil {
            let connection = NSXPCConnection(serviceName: "theboringteam.boringnotch.BoringNotchXPCHelper")
            connection.remoteObjectInterface = NSXPCInterface(with: BoringNotchXPCHelperProtocol.self)
            connection.resume()
            processConnection = connection
        }
        requestInFlight = true
        let id = UUID(); requestID = id
        let finish: @Sendable (Data?) -> Void = { [weak self] data in
            Task { @MainActor in
                guard let self, self.requestID == id, self.requestInFlight else { return }
                self.requestInFlight = false
                self.processes = data.flatMap { try? JSONDecoder().decode(NotchProcessSnapshot.self, from: $0) }
                self.processError = self.processes == nil ? "Process readings unavailable. Open Activity Monitor for details." : nil
            }
        }
        let proxy = processConnection?.remoteObjectProxyWithErrorHandler { _ in finish(nil) } as? BoringNotchXPCHelperProtocol
        if let proxy { proxy.readProcessStats(with: finish) } else { finish(nil) }
        Task { try? await Task.sleep(for: .seconds(4)); if requestID == id && requestInFlight { finish(nil) } }
    }
    deinit { processConnection?.invalidate() }

    func refresh() async {
        let next = await withCheckedContinuation { continuation in
            queue.async { [reader] in continuation.resume(returning: reader.sample()) }
        }
        guard !Task.isCancelled else { return }
        sample = next
        if let cpu = next.cpu { history = Array((history + [cpu]).suffix(30)) }
    }
}

struct StatsView: View {
    @EnvironmentObject var vm: BoringViewModel
    @StateObject private var model = SystemStatsModel()
    @State private var selected = "CPU"
    @State private var expanded = false
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)
    private var s: SystemStatsSample { model.sample }
    private func bytes(_ value: Double?) -> String {
        guard let value else { return "Unavailable" }
        return ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .memory)
    }
    private func percent(_ value: Double?) -> String {
        value.map { String(format: "%.0f%%", $0) } ?? "—"
    }
    private func rate(_ value: Double?) -> String {
        guard let value else { return "Measuring…" }
        return ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .decimal) + "/s"
    }
    private var thermal: String {
        switch s.thermal { case .nominal: return "Normal"; case .fair: return "Warm"; case .serious: return "Hot"; case .critical: return "Critical"; @unknown default: return "Unknown" }
    }
    private var detail: String {
        switch selected {
        case "CPU": return "\(ProcessInfo.processInfo.activeProcessorCount) cores · Thermal state: \(thermal) · 30-second history"
        case "Memory": return "\(bytes(s.memoryUsed)) used of \(bytes(s.memoryTotal)) · \(bytes(s.compressed)) compressed"
        case "GPU": return s.gpu == nil ? "GPU utilization is not exposed by this Mac's driver." : "GPU utilization from the graphics driver · Thermal state: \(thermal)"
        case "Network": return "Download \(rate(s.received)) · Upload \(rate(s.sent)) · Active Wi-Fi / Ethernet"
        case "Storage": return "\(bytes(s.diskUsed)) used · \(bytes(s.diskTotal.flatMap { total in s.diskUsed.map { total - $0 } })) free · Startup data volume"
        default: return s.battery == nil ? "No internal battery reading available." : "Battery \(percent(s.battery)) · \(s.charging ? "Charging" : "Not charging") · Thermal state: \(thermal)"
        }
    }
    var body: some View {
        VStack(spacing: 7) {
            if expanded {
                detailPanel
            } else {
            LazyVGrid(columns: columns, spacing: 7) {
                card("CPU", icon: "cpu", value: percent(s.cpu), caption: "PROCESSOR", color: .cyan, fraction: s.cpu.map { $0 / 100 }, chart: true)
                card("Memory", icon: "memorychip", value: bytes(s.memoryUsed), caption: "OF \(bytes(s.memoryTotal))", color: .cyan, fraction: s.memoryUsed.map { $0 / s.memoryTotal })
                card("GPU", icon: "square.stack.3d.up", value: percent(s.gpu), caption: s.gpu == nil ? "NOT EXPOSED" : "GRAPHICS", color: .cyan, fraction: s.gpu.map { $0 / 100 })
                card("Network", icon: "network", value: "↓ " + rate(s.received), caption: "↑ " + rate(s.sent), color: .blue, fraction: nil)
                card("Storage", icon: "internaldrive", value: s.diskUsed.flatMap { used in s.diskTotal.map { percent(used / $0 * 100) } } ?? "—", caption: "DISK USED", color: .cyan, fraction: s.diskUsed.flatMap { used in s.diskTotal.map { used / $0 } })
                card("Battery", icon: s.charging ? "battery.100percent.bolt" : "battery.75percent", value: percent(s.battery), caption: s.batteryHealth.map { "HEALTH " + percent($0) } ?? (s.charging ? "CHARGING" : "BATTERY"), color: .cyan, fraction: s.battery.map { $0 / 100 })
            }
            }
            HStack(spacing: 5) {
                Circle().fill(.mint).frame(width: 4, height: 4)
                Text(detail).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 0)
                Button { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")) } label: {
                    Image(systemName: "waveform.path.ecg").font(.system(size: 11))
                }.buttonStyle(.plain).help("Open Activity Monitor").accessibilityLabel("Open Activity Monitor")
            }
        }
        .padding(.horizontal, 12)
        .frame(width: 600)
        .onChange(of: expanded) { _, value in
            withAnimation(.smooth(duration: 0.25)) { vm.notchSize.height = value ? 320 : openNotchSize.height }
        }
        .onDisappear { if vm.notchState == .open { vm.notchSize.height = openNotchSize.height } }
        .task {
            while !Task.isCancelled {
                await model.refresh()
                if expanded && ["CPU", "Memory", "Battery"].contains(selected) { model.readProcesses() }
                do { try await Task.sleep(for: .seconds(1)) } catch { break }
            }
        }
    }
    private var rankedProcesses: [NotchProcessRow] {
        (model.processes?.rows ?? []).sorted {
            if selected == "Memory" { return $0.memory > $1.memory }
            return ($0.cpu ?? 0) > ($1.cpu ?? 0)
        }
    }
    private var detailPanel: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Button { expanded = false } label: { Label("Overview", systemImage: "chevron.left") }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Text(selected == "Battery" ? "Battery health & active apps" : selected + " details").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(selected == "Memory" ? "RESIDENT RAM" : (["CPU", "Battery"].contains(selected) ? "CPU · 100% = 1 CORE" : "LIVE")).font(.system(size: 8)).foregroundStyle(.secondary)
            }
            if selected == "Battery" {
                Text("Health \(percent(s.batteryHealth)) · \(s.cycles.map { String($0) } ?? "—") cycles · \(s.charging ? "Charging" : "Not charging")")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.green)
            }
            if ["CPU", "Memory", "Battery"].contains(selected) {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        if let error = model.processError { Text(error).font(.caption).foregroundStyle(.secondary) }
                        else if model.processes == nil { Text("Reading apps…").font(.caption).foregroundStyle(.secondary) }
                        ForEach(rankedProcesses.prefix(30)) { row in
                            HStack(spacing: 7) {
                                Image(systemName: row.appPath == nil ? "gearshape" : "app.fill").foregroundStyle(.secondary).frame(width: 14)
                                Text(row.name).lineLimit(1)
                                if row.count > 1 { Text("\(row.count) processes").font(.system(size: 9)).foregroundStyle(.secondary) }
                                Spacer()
                                Text(bytes(Double(row.memory))).foregroundStyle(selected == "Memory" ? .primary : .secondary)
                                Text(row.cpu.map { String(format: "%.1f%%", $0) } ?? "…").foregroundStyle(.cyan).frame(width: 56, alignment: .trailing)
                            }.font(.system(size: 11)).monospacedDigit().padding(.horizontal, 8).padding(.vertical, 3)
                                .background(RoundedRectangle(cornerRadius: 5).fill(.white.opacity(0.035)))
                        }
                    }
                }.frame(height: selected == "Battery" ? 178 : 198)
                Text(selected == "Battery" ? "CPU activity is shown for context, not per-app battery drain. Health is a capacity estimate." : "Your apps and helpers grouped together. Shared RAM can be counted in multiple processes.")
                    .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
            } else {
                VStack(alignment: .leading, spacing: 9) {
                    if selected == "Network" {
                        Label("Download  \(rate(s.received))", systemImage: "arrow.down").foregroundStyle(.cyan)
                        Label("Upload  \(rate(s.sent))", systemImage: "arrow.up").foregroundStyle(.mint)
                        Text("Combined active Wi-Fi and Ethernet traffic. VPN interfaces excluded to avoid double-counting.").font(.system(size: 10)).foregroundStyle(.secondary)
                    } else { Text(detail).font(.system(size: 13)); Text("Open Activity Monitor for additional system details.").font(.system(size: 10)).foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity, minHeight: 210, alignment: .leading)
            }
        }.frame(height: 233)
    }
    private func card(_ name: String, icon: String, value: String, caption: String, color: Color, fraction: Double?, chart: Bool = false) -> some View {
        Button { selected = name; expanded = true; model.readProcesses() } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: icon).foregroundStyle(.secondary).font(.system(size: 12))
                    Text(value).font(.system(size: 17, weight: .semibold, design: .rounded)).monospacedDigit().contentTransition(.numericText())
                    Spacer(minLength: 0)
                    if chart {
                        StatsSparkline(values: model.history).stroke(color, style: StrokeStyle(lineWidth: 1.4, lineCap: .round)).frame(width: 47, height: 18)
                    }
                }
                HStack(spacing: 8) {
                    Text(caption).font(.system(size: 9, weight: .medium)).tracking(0.2).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 0)
                    if let fraction {
                        GeometryReader { geometry in
                            Capsule().fill(color.opacity(0.12))
                                .overlay(alignment: .leading) { Capsule().fill(color.opacity(0.8)).frame(width: geometry.size.width * min(1, max(0, fraction))) }
                        }.frame(width: 48, height: 3)
                    }
                }
            }.padding(.horizontal, 10).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 11).fill(Color(nsColor: .secondarySystemFill)))
                .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Color.white.opacity(0.08), lineWidth: 0.7))
                .contentShape(RoundedRectangle(cornerRadius: 11))
        }.buttonStyle(.plain).foregroundStyle(.white)
            .accessibilityLabel("\(name), \(value)").accessibilityHint("Show details")
            .help(name == "CPU" ? "Total CPU utilization, normalized to 100%" : "Show \(name.lowercased()) details")
    }
}

struct StatsSparkline: Shape {
    let values: [Double]
    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard values.count > 1 else { return path }
        for (i, value) in values.enumerated() {
            let point = CGPoint(x: rect.width * Double(i) / Double(values.count - 1), y: rect.height * (1 - min(100, max(0, value)) / 100))
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }
}
