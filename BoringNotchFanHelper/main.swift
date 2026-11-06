// BoringNotchFanHelper: a small root launch daemon that writes fan speeds to the SMC.
//
// Safety rules:
// - Only the signed BoringNotch XPC helper inside /Applications/boringNotch.app may connect.
// - Requests are limited to automatic, a manual level within each fan's own min–max, or maximum.
// - Timed modes hand control back to macOS when they expire, even if the app has quit.
// - A manual level below maximum is abandoned when macOS reports serious thermal pressure.
// - Control returns to macOS when the daemon starts (stale state), stops, or goes idle.
//
// Build: see LOCAL_STATS.md ("Fan control").

import Darwin
import Foundation

final class FanService: NSObject, BoringNotchFanHelperProtocol, NSXPCListenerDelegate {
    private let queue = DispatchQueue(label: "theboringteam.boringnotch.FanHelper.smc")
    private let smc: SMCConnection
    private var state = FanControlState()
    private var connections = 0
    private var lastActivity = Date()

    init(smc: SMCConnection) {
        self.smc = smc
        super.init()
    }

    // MARK: Lifecycle

    func start() {
        queue.sync {
            // A previous instance may have crashed while holding manual control.
            if SMCFan.needsReset(smc) { SMCFan.resetAutomatic(smc) }
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: queue)
            source.setEventHandler { [weak self] in self?.shutdown() }
            source.resume()
            signalSources.append(source)
        }
    }

    private var timer: DispatchSourceTimer?
    private var signalSources: [DispatchSourceSignal] = []

    private func shutdown() -> Never {
        SMCFan.resetAutomatic(smc)
        exit(0)
    }

    /// Runs every 5 seconds on `queue`.
    private func tick() {
        if state.mode != .automatic {
            if let until = state.until, until <= Date() {
                revert("Timer finished")
            } else if state.mode == .manual, state.level < 1, ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue {
                revert("Mac got hot, so macOS took the fans back")
            } else {
                // The SMC or thermalmonitord can drop forced mode, e.g. after sleep. Re-assert it.
                _ = enforce()
            }
        } else if connections == 0, Date().timeIntervalSince(lastActivity) > 60 {
            shutdown() // launchd starts the daemon again on the next request.
        }
    }

    private func revert(_ note: String?) {
        SMCFan.resetAutomatic(smc)
        state = FanControlState(mode: .automatic, level: 0, until: nil, note: note)
        lastActivity = Date()
    }

    private func targetRPM(for fan: FanControlFan) -> Double {
        switch state.mode {
        case .maximum: return fan.maximum
        case .manual: return fan.minimum + (fan.maximum - fan.minimum) * min(1, max(0, state.level))
        case .automatic: return 0
        }
    }

    /// Puts every fan in manual mode at its target. Returns an error message on failure.
    private func enforce() -> String? {
        let fans = SMCFan.readFans(smc)
        guard !fans.isEmpty else { return "This Mac reports no controllable fans." }
        for fan in fans where fan.maximum > 0 {
            let rpm = targetRPM(for: fan)
            if fan.manual, let target = fan.target, abs(target - rpm) < 1 { continue }
            guard SMCFan.unlock(smc, fan.id) else { return "macOS did not hand over fan \(fan.id + 1)." }
            guard SMCFan.setTarget(smc, fan.id, rpm: rpm) else { return "Could not set fan \(fan.id + 1) speed." }
        }
        return nil
    }

    // MARK: BoringNotchFanHelperProtocol

    func version(with reply: @escaping (String) -> Void) { reply(FanHelperConstants.version) }

    func state(with reply: @escaping (Data?) -> Void) {
        queue.async { [self] in
            lastActivity = Date()
            reply(try? JSONEncoder().encode(state))
        }
    }

    func apply(_ mode: String, level: Double, duration: Double, with reply: @escaping (String?) -> Void) {
        queue.async { [self] in
            lastActivity = Date()
            guard let mode = FanControlState.Mode(rawValue: mode), level.isFinite, duration.isFinite,
                  (0...1).contains(level), (0...86_400).contains(duration) else { return reply("Invalid fan request.") }
            if mode == .automatic {
                revert(nil)
                return reply(SMCFan.needsReset(smc) ? "macOS has not taken the fans back yet." : nil)
            }
            state = FanControlState(mode: mode, level: mode == .maximum ? 1 : level,
                                    until: duration > 0 ? Date().addingTimeInterval(duration) : nil, note: nil)
            if let error = enforce() {
                revert(error)
                return reply(error)
            }
            reply(nil)
        }
    }

    // MARK: NSXPCListenerDelegate

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.setCodeSigningRequirement("identifier \"\(FanHelperConstants.clientIdentifier)\"")
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(connection.processIdentifier, &buffer, UInt32(buffer.count)) > 0,
              String(cString: buffer).hasPrefix(FanHelperConstants.clientPathPrefix) else {
            NSLog("BoringNotchFanHelper: refused a client outside the installed app")
            return false
        }
        connection.exportedInterface = NSXPCInterface(with: BoringNotchFanHelperProtocol.self)
        connection.exportedObject = self
        connection.invalidationHandler = { [weak self] in
            self?.queue.async { self?.connections -= 1; self?.lastActivity = Date() }
        }
        queue.async { self.connections += 1 }
        connection.resume()
        return true
    }
}

guard getuid() == 0 else {
    FileHandle.standardError.write("BoringNotchFanHelper must run as root from launchd.\n".data(using: .utf8)!)
    exit(1)
}
guard let smc = SMCConnection() else {
    NSLog("BoringNotchFanHelper: AppleSMC is unavailable")
    exit(1)
}
let service = FanService(smc: smc)
service.start()
let listener = NSXPCListener(machServiceName: FanHelperConstants.label)
listener.delegate = service
listener.resume()
dispatchMain()
