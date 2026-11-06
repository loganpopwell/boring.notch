import SwiftUI

@MainActor final class FanControlModel: ObservableObject {
    @Published var snapshot: FanControlSnapshot?
    @Published var busy: String?
    @Published var message: String?
    private var connection: NSXPCConnection?
    private var readInFlight = false

    private func helper(_ onError: @escaping @Sendable () -> Void) -> BoringNotchXPCHelperProtocol? {
        if connection == nil {
            let next = NSXPCConnection(serviceName: "theboringteam.boringnotch.BoringNotchXPCHelper")
            next.remoteObjectInterface = NSXPCInterface(with: BoringNotchXPCHelperProtocol.self)
            next.invalidationHandler = { Task { @MainActor [weak self] in self?.connection = nil } }
            next.resume()
            connection = next
        }
        return connection?.remoteObjectProxyWithErrorHandler { _ in onError() } as? BoringNotchXPCHelperProtocol
    }
    deinit { connection?.invalidate() }

    var state: FanControlState { snapshot?.state ?? FanControlState() }
    var averageRPM: Double? {
        guard let fans = snapshot?.fans, !fans.isEmpty else { return nil }
        return fans.map(\.actual).reduce(0, +) / Double(fans.count)
    }
    var speedFraction: Double? {
        guard let fans = snapshot?.fans, !fans.isEmpty else { return nil }
        return fans.map { $0.maximum > 0 ? $0.actual / $0.maximum : 0 }.max()
    }

    func read() {
        guard !readInFlight else { return }
        readInFlight = true
        let finish: @Sendable (Data?) -> Void = { data in
            Task { @MainActor [weak self] in
                guard let self, self.readInFlight else { return }
                self.readInFlight = false
                if let data, let next = try? JSONDecoder().decode(FanControlSnapshot.self, from: data) { self.snapshot = next }
            }
        }
        if let proxy = helper({ finish(nil) }) { proxy.readFanControl(with: finish) } else { finish(nil) }
        Task { try? await Task.sleep(for: .seconds(5)); if readInFlight { finish(nil) } }
    }

    private func run(_ label: String, _ body: (BoringNotchXPCHelperProtocol, @escaping @Sendable (String?) -> Void) -> Void) {
        guard busy == nil else { return }
        busy = label; message = nil
        let done: @Sendable (String?) -> Void = { error in
            Task { @MainActor [weak self] in
                guard let self, self.busy != nil else { return }
                self.busy = nil
                self.message = error
                self.readInFlight = false
                self.read()
            }
        }
        guard let proxy = helper({ done("The BoringNotch helper did not respond.") }) else { return done("The BoringNotch helper is unavailable.") }
        body(proxy, done)
    }

    func set(_ mode: FanControlState.Mode, level: Double = 0, duration: TimeInterval = 0) {
        let label = mode == .automatic ? "Handing fans back to macOS…" : "Taking control of the fans…"
        run(label) { proxy, done in proxy.setFanControl(mode.rawValue, level: level, duration: duration, with: done) }
    }
    func install() { run("Waiting for your password…") { proxy, done in proxy.installFanHelper(with: done) } }
    func uninstall() { run("Removing the fan helper…") { proxy, done in proxy.uninstallFanHelper(with: done) } }
}

struct FanControlPanel: View {
    @ObservedObject var model: FanControlModel
    @State private var level: Double = 0.5
    @State private var editingLevel = false
    private let cooldowns: [(String, TimeInterval)] = [("5 min", 300), ("15 min", 900), ("30 min", 1800), ("1 hr", 3600), ("Until off", 0)]

    private var snapshot: FanControlSnapshot? { model.snapshot }
    private var state: FanControlState { model.state }
    private var ready: Bool { snapshot?.helper == .ready }
    private func rpm(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0))) + " rpm" }
    private func degrees(_ value: Double?) -> String { value.map { String(format: "%.0f°C", $0) } ?? "—" }
    private var levelRPM: String {
        guard let fan = snapshot?.fans.first else { return "" }
        return "≈ " + rpm(fan.minimum + (fan.maximum - fan.minimum) * level)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                ForEach(snapshot?.fans ?? []) { fan in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Image(systemName: "fan").foregroundStyle(.secondary)
                            Text("Fan \(fan.id + 1)").foregroundStyle(.secondary)
                            Spacer()
                            Text(rpm(fan.actual)).monospacedDigit().contentTransition(.numericText())
                        }.font(.system(size: 11))
                        GeometryReader { geometry in
                            Capsule().fill(Color.cyan.opacity(0.12)).overlay(alignment: .leading) {
                                Capsule().fill(Color.cyan.opacity(0.8)).frame(width: geometry.size.width * min(1, fan.maximum > 0 ? fan.actual / fan.maximum : 0))
                            }
                        }.frame(height: 3)
                        Text("\(rpm(fan.minimum)) – \(rpm(fan.maximum))").font(.system(size: 8)).foregroundStyle(.tertiary)
                    }.padding(.horizontal, 9).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.04)))
                }
                VStack(alignment: .leading, spacing: 3) {
                    Label("CPU \(degrees(snapshot?.cpuTemperature))", systemImage: "cpu")
                    Label("GPU \(degrees(snapshot?.gpuTemperature))", systemImage: "square.stack.3d.up")
                }.font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary).frame(width: 92, alignment: .leading)
            }
            if snapshot == nil {
                Text("Reading fans…").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 120)
            } else if snapshot?.fans.isEmpty == true {
                Text(snapshot?.error ?? "This Mac reports no fans.").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 120)
            } else if !ready {
                installPrompt
            } else {
                controls
            }
            HStack(spacing: 6) {
                if let busy = model.busy {
                    ProgressView().controlSize(.mini)
                    Text(busy)
                } else if state.releasePending == true {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("Handing the fans back to macOS… retrying every 2 seconds.")
                } else if let message = model.message {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(message)
                } else if let note = state.note, state.mode == .automatic {
                    Image(systemName: "info.circle").foregroundStyle(.secondary)
                    Text("\(note). Fans are back on Auto.")
                } else {
                    Text("Timers and heat hand control back to macOS, even if BoringNotch quits.")
                }
                Spacer(minLength: 0)
                if ready && model.busy == nil {
                    Button("Remove helper") { model.uninstall() }.buttonStyle(.plain).foregroundStyle(.tertiary)
                        .help("Uninstall the fan helper. Asks for your password.")
                }
            }.font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
        }
        .onAppear { model.read(); level = state.mode == .manual ? state.level : level }
        .onChange(of: state) { _, value in if value.mode == .manual && !editingLevel { level = value.level } }
    }

    private var installPrompt: some View {
        VStack(spacing: 8) {
            Image(systemName: "fan.badge.automatic").font(.system(size: 22)).foregroundStyle(.cyan)
            Text(snapshot?.helper == .outdated ? "The fan helper needs an update." : (snapshot?.helper == .unreachable ? "The fan helper is installed but not responding." : "Manual fan control needs a small helper that runs as root."))
                .font(.system(size: 12, weight: .medium))
            Text("macOS asks for your password once. Readings work without it.").font(.system(size: 10)).foregroundStyle(.secondary)
            Button { model.install() } label: {
                Text(snapshot?.helper == .notInstalled ? "Install fan helper" : "Reinstall fan helper").font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 12).padding(.vertical, 5).background(Capsule().fill(Color.cyan.opacity(0.25)))
            }.buttonStyle(.plain).disabled(model.busy != nil)
        }.frame(maxWidth: .infinity, minHeight: 120)
    }

    private func modeButton(_ title: String, icon: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon).font(.system(size: 11, weight: .medium)).frame(maxWidth: .infinity).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 7).fill(active ? Color.cyan.opacity(0.28) : Color.white.opacity(0.05)))
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(.plain).foregroundStyle(active ? .white : .secondary).disabled(model.busy != nil)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                modeButton("Auto", icon: "a.circle", active: state.mode == .automatic) { model.set(.automatic) }
                modeButton("Manual", icon: "slider.horizontal.3", active: state.mode == .manual) { model.set(.manual, level: level) }
                modeButton("Max", icon: "snowflake", active: state.mode == .maximum && state.until == nil) { model.set(.maximum) }
            }
            if state.mode == .manual {
                HStack(spacing: 8) {
                    Text("Speed").font(.system(size: 10)).foregroundStyle(.secondary)
                    Slider(value: $level, in: 0...1) { editing in
                        editingLevel = editing
                        if !editing { model.set(.manual, level: level) }
                    }.controlSize(.mini).tint(.cyan).disabled(model.busy != nil)
                    Text(levelRPM).font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary).frame(width: 74, alignment: .trailing)
                }
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "snowflake").font(.system(size: 11)).foregroundStyle(.cyan)
                    Text("Cool down").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                    ForEach(cooldowns, id: \.0) { title, seconds in
                        Button(title) { model.set(.maximum, duration: seconds) }
                            .buttonStyle(.plain).font(.system(size: 10, weight: .medium)).padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Capsule().fill(Color.white.opacity(0.06))).disabled(model.busy != nil)
                    }
                    Spacer(minLength: 0)
                }
            }
            if state.mode != .automatic {
                HStack(spacing: 6) {
                    Image(systemName: state.mode == .maximum ? "snowflake" : "slider.horizontal.3").foregroundStyle(.cyan)
                    if let until = state.until, until > Date() {
                        Text(state.mode == .maximum ? "Cooling at max · back to Auto in " : "Manual · back to Auto in ") + Text(until, style: .timer).monospacedDigit()
                    } else {
                        Text(state.mode == .maximum ? "Fans at max until you turn it off" : "Manual until you change it")
                    }
                    Spacer()
                    Button("Stop") { model.set(.automatic) }.buttonStyle(.plain).font(.system(size: 10, weight: .semibold)).foregroundStyle(.cyan)
                        .disabled(model.busy != nil)
                }.font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }.frame(minHeight: 120, alignment: .top)
    }
}
