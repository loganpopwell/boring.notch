// BoringNotchFanHelper: a small root launch daemon that writes fan speeds to the SMC.
//
// Handing the fans back to macOS is the one thing this daemon must never get wrong:
// - Every handback is confirmed by reading the SMC back (all fan modes 0, Ftst 0). An
//   unconfirmed handback is retried every 2 seconds until it succeeds, and the daemon
//   refuses to exit while it may still hold the fans.
// - Timers live here, so they end even if BoringNotch quits.
// - SIGTERM (launchctl bootout, logout, shutdown) and system sleep interrupt any
//   in-progress takeover within 100 ms and hand the fans back before the daemon exits or
//   the Mac sleeps. A crash (SIGKILL) is covered by launchd restarting the daemon
//   (KeepAlive), which hands the fans back on start.
// - The SMC applies writes late, by up to ~2.5 s (measured on an M4 Pro, macOS 27). A takeover
//   write sent just before a handback can land after the handback has read back clean, and a
//   just-written Ftst 0 can read 0, then the old 1, then 0. So a handback only counts as
//   confirmed once the SMC has read handed back continuously for 3 s after the handback's own
//   writes and until 6 s after the last takeover write; any relapse is handed back again.
//   After that, the daemon keeps checking every 200 ms for 30 s more as a backstop.
// - A marker file in /var/run exists from before the first takeover write until a confirmed
//   handback. A daemon restarted after a crash that finds it hands back with the full wait,
//   even if the SMC still reads clean (the crashed instance's writes may not have landed yet).
//   Every start also runs the 30-second watch.
// - Below-max manual levels are abandoned when macOS reports serious thermal pressure.
// Other rules: only the signed BoringNotch XPC helper inside /Applications/boringNotch.app
// may connect, and requests are limited to automatic, a level inside each fan's own
// min–max, or maximum.
//
// Build: see LOCAL_STATS.md ("Fan control").

import Darwin
import Foundation
import IOKit.pwr_mgt
import os

/// The launchd job. Printed by `--launchd-plist` so the installer and the stress test use one definition.
let launchdPlist: [String: Any] = [
    "Label": FanHelperConstants.label,
    "ProgramArguments": [FanHelperConstants.installedBinary],
    "MachServices": [FanHelperConstants.label: true],
    // Restart after a crash, so a fresh instance can hand the fans back.
    "KeepAlive": ["SuccessfulExit": false],
    "ThrottleInterval": 2,
    // Time allowed between SIGTERM and SIGKILL. A handback that has to wait out late SMC
    // writes takes up to ~10 s; the daemon tries up to 4 times.
    "ExitTimeOut": 60,
    "AssociatedBundleIdentifiers": ["theboringteam.boringnotch"],
]

if CommandLine.arguments.dropFirst().first == "--launchd-plist" {
    let data = try! PropertyListSerialization.data(fromPropertyList: launchdPlist, format: .xml, options: 0)
    FileHandle.standardOutput.write(data)
    exit(0)
}

let log = Logger(subsystem: FanHelperConstants.label, category: "fans")

final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ next: Bool) { lock.lock(); value = next; lock.unlock() }
}

final class AtomicCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var current: Int { lock.lock(); defer { lock.unlock() }; return value }
    func increment() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
}

/// True when `path` exists, is owned by root and is not writable by group or others.
func rootOnlyFile(_ path: String) -> Bool {
    var info = stat()
    return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG && info.st_uid == 0 && info.st_mode & (S_IWGRP | S_IWOTH) == 0
}

final class FanService: NSObject, BoringNotchFanHelperProtocol, NSXPCListenerDelegate, @unchecked Sendable {
    /// Serializes all SMC writes and all state changes.
    private let queue = DispatchQueue(label: "theboringteam.boringnotch.FanHelper.smc")
    /// Signals and power notifications. Kept off `queue` so they can interrupt a slow takeover.
    private let urgent = DispatchQueue(label: "theboringteam.boringnotch.FanHelper.urgent")
    private let smc: SMCConnection
    private let hasFtst: Bool

    // Owned by `queue`.
    private var state = FanControlState()
    /// True from the first takeover write until a handback is confirmed by read-back.
    private var holding = false
    private var connections = 0
    private var lastActivity = Date()
    private var faultRoundsLeft = 0
    /// Until this time, the SMC is re-checked every 200 ms and any forced fan is handed back again.
    private var watchUntil = Date.distantPast
    private var watchTimer: DispatchSourceTimer?
    /// Last time this daemon wrote anything that takes the fans (mode 1, a target, or Ftst 1).
    private var lastTakeoverWrite = Date.distantPast
    /// The forced target last written per fan. A late write can leave it on a fan macOS drives again.
    private var lastForced: [Int: Double] = [:]

    // Readable from any thread.
    private let published = OSAllocatedUnfairLock(initialState: FanControlState())
    private let generation = AtomicCounter()
    private let stopping = AtomicFlag()
    private let sleeping = AtomicFlag()

    private var timer: DispatchSourceTimer?
    private var signalSources: [DispatchSourceSignal] = []
    fileprivate var powerPort: io_connect_t = 0
    private var powerNotifier: io_object_t = 0
    private var powerNotifyPort: IONotificationPortRef?

    init(smc: SMCConnection) {
        self.smc = smc
        self.hasFtst = smc.read("Ftst") != nil
        super.init()
    }

    // MARK: Lifecycle

    func start() {
        queue.sync {
            // A previous instance may have crashed while holding the fans, possibly with
            // takeover writes still in flight that the SMC has not applied yet.
            let marked = FileManager.default.fileExists(atPath: FanHelperConstants.holdingMarker)
            if marked || SMCFan.needsReset(smc) {
                log.notice("start: previous instance held the fans (marker: \(marked, privacy: .public)), handing back. SMC: \(SMCFan.describe(self.smc), privacy: .public)")
                holding = true
                if marked { lastTakeoverWrite = Date() } // wait out writes that may still land
                release(note: nil)
            } else {
                publish()
            }
            startWatch()
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: urgent)
            source.setEventHandler { [weak self] in self?.terminate(signal: sig) }
            source.resume()
            signalSources.append(source)
        }
        registerForSleep()
    }

    private func publish() {
        let snapshot = state
        published.withLock { $0 = snapshot }
    }

    /// Hands the fans back and confirms it. Runs on `queue`. On failure `holding` stays true
    /// and `tick` retries every 2 seconds.
    /// `quiet: false` skips waiting out late writes; only for a takeover interrupted by a newer
    /// request, which then either takes the fans itself or hands back with the full wait (the
    /// shortcut below is off within 6 s of a takeover write).
    @discardableResult private func release(note: String?, quiet: Bool = true) -> Bool {
        state = FanControlState(mode: .automatic, level: 0, until: nil, note: note)
        if !holding, Date().timeIntervalSince(lastTakeoverWrite) > 6, SMCFan.macOSInControl(smc, hasFtst: hasFtst) == true {
            publish()
            return true
        }
        holding = true
        // Show "returning to Auto" right away; confirming can take a few seconds.
        state.releasePending = true
        publish()
        if rootOnlyFile(FanHelperConstants.stressFlag), rootOnlyFile(FanHelperConstants.faultFile),
           let text = try? String(contentsOfFile: FanHelperConstants.faultFile, encoding: .utf8), let rounds = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            try? FileManager.default.removeItem(atPath: FanHelperConstants.faultFile)
            faultRoundsLeft = max(0, min(200, rounds))
            log.notice("fault injection: skipping the next \(self.faultRoundsLeft, privacy: .public) handback write rounds")
        }
        let started = Date()
        let skip: () -> Bool = { [self] in
            guard faultRoundsLeft > 0 else { return false }
            faultRoundsLeft -= 1
            return true
        }
        var ok = SMCFan.release(smc, hasFtst: hasFtst, skipWrites: skip)
        // Wait out late SMC writes: the read-back must stay handed back for a quiet period.
        var calmSince = Date(), relapses = 0
        while ok && quiet {
            let quietUntil = max(calmSince.addingTimeInterval(3), lastTakeoverWrite.addingTimeInterval(6))
            if Date() >= quietUntil { break }
            if Date().timeIntervalSince(started) > 25 { ok = false; break }
            usleep(100_000)
            if SMCFan.macOSInControl(smc, hasFtst: hasFtst) != true {
                relapses += 1
                log.error("a late SMC write undid the handback; handing back again. SMC: \(SMCFan.describe(self.smc), privacy: .public)")
                ok = SMCFan.release(smc, hasFtst: hasFtst, skipWrites: skip)
                calmSince = Date()
            } else if clearStaleTargets() {
                relapses += 1
                calmSince = Date()
            }
        }
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        if ok {
            holding = false
            try? FileManager.default.removeItem(atPath: FanHelperConstants.holdingMarker)
            log.notice("handed fans back to macOS (stable for the quiet period, \(ms, privacy: .public) ms, \(relapses, privacy: .public) late-write relapses); reason: \(note ?? "requested", privacy: .public)")
            startWatch()
        } else {
            log.error("handback NOT confirmed after \(ms, privacy: .public) ms; retrying. SMC: \(SMCFan.describe(self.smc), privacy: .public)")
        }
        state.releasePending = ok ? nil : true
        publish()
        return ok
    }

    /// Clears a forced target that a late write left on a fan macOS drives again (mode 0 or 3).
    /// Late writes land within ~3.5 s, so this only looks within 10 s of the last takeover write;
    /// after that a matching target is macOS's own and is left alone. Returns true if it found
    /// one. Runs on `queue`.
    private func clearStaleTargets() -> Bool {
        guard Date().timeIntervalSince(lastTakeoverWrite) < 10 else { return false }
        var found = false
        for (id, rpm) in lastForced {
            guard let mode = smc.read(SMCFan.modeKey(smc, id))?.bytes.first, SMCFan.isAutomatic(mode),
                  let target = smc.number("F\(id)Tg"), abs(target - rpm) < 1 else { continue }
            found = true
            log.error("fan \(id + 1, privacy: .public) still had the forced target \(Int(rpm), privacy: .public) rpm after the handback; clearing it")
            _ = SMCFan.setTarget(smc, id, rpm: 0, attempts: 3)
        }
        return found
    }

    /// Re-checks the SMC every 200 ms for 30 s after a handback. Runs on `queue`.
    private func startWatch() {
        watchUntil = Date().addingTimeInterval(30)
        guard watchTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.2, repeating: 0.2)
        timer.setEventHandler { [weak self] in self?.watch() }
        timer.resume()
        watchTimer = timer
    }

    private func watch() {
        if Date() >= watchUntil || state.mode != .automatic {
            watchTimer?.cancel(); watchTimer = nil
            return
        }
        if stopping.isSet || sleeping.isSet || holding { return }
        if SMCFan.macOSInControl(smc, hasFtst: hasFtst) == false {
            log.error("fans read forced after a confirmed handback; handing back again. SMC: \(SMCFan.describe(self.smc), privacy: .public)")
            holding = true
            release(note: state.note)
        } else {
            _ = clearStaleTargets()
        }
    }

    /// Runs every 2 seconds on `queue`.
    private func tick() {
        if sleeping.isSet || stopping.isSet { return }
        if state.mode != .automatic {
            if let until = state.until, until <= Date() {
                release(note: "Timer finished")
            } else if state.mode == .manual, state.level < 1, ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue {
                release(note: "Mac got hot, so macOS took the fans back")
            } else if let error = enforce(generation.current) {
                // thermalmonitord can take forced mode back, e.g. after wake. Re-taking it is
                // abortable; a timer that ends meanwhile is handled on the next line of tick.
                if let until = state.until, until <= Date() {
                    release(note: "Timer finished")
                } else if error != "Interrupted." {
                    log.error("re-applying fan target failed: \(error, privacy: .public)")
                    release(note: error)
                }
            }
        } else if holding {
            release(note: state.note)
        } else if connections == 0, Date().timeIntervalSince(lastActivity) > 60, watchTimer == nil {
            log.notice("idle with fans on macOS control, exiting")
            exit(0) // launchd starts the daemon again on the next request.
        }
    }

    private func targetRPM(for fan: FanControlFan) -> Double {
        switch state.mode {
        case .maximum: return fan.maximum
        case .manual: return fan.minimum + (fan.maximum - fan.minimum) * min(1, max(0, state.level))
        case .automatic: return 0
        }
    }

    /// Puts every fan in manual mode at its target. Returns an error message on failure.
    /// A newer request, shutdown, sleep or the end of a timed mode aborts it within 100 ms, so a slow
    /// re-take can never delay a handback.
    private func enforce(_ request: Int) -> String? {
        let deadline = state.until
        let abort: SMCFan.Abort = { [self] in
            stopping.isSet || sleeping.isSet || generation.current != request || deadline.map { Date() >= $0 } == true
        }
        let fans = SMCFan.readFans(smc)
        guard !fans.isEmpty else { return "This Mac reports no controllable fans." }
        // Without Ftst held at 1, thermalmonitord takes the fans back after about 20 s.
        let ftstOK = !hasFtst || SMCFan.ftstHeld(smc)
        for fan in fans where fan.maximum > 0 {
            let rpm = targetRPM(for: fan)
            if ftstOK, fan.manual, let target = fan.target, abs(target - rpm) < 1 { continue }
            // Record before writing anything, so a crash at any point leads to a full handback.
            if !FileManager.default.fileExists(atPath: FanHelperConstants.holdingMarker) {
                FileManager.default.createFile(atPath: FanHelperConstants.holdingMarker, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            holding = true
            lastTakeoverWrite = Date()
            defer { lastTakeoverWrite = Date() }
            guard SMCFan.unlock(smc, fan.id, hasFtst: hasFtst, abort: abort) else {
                return abort() ? "Interrupted." : "macOS did not hand over fan \(fan.id + 1)."
            }
            lastForced[fan.id] = rpm
            guard SMCFan.setTarget(smc, fan.id, rpm: rpm, abort: abort) else {
                return abort() ? "Interrupted." : "Could not set fan \(fan.id + 1) speed."
            }
        }
        return nil
    }

    private func terminate(signal sig: Int32) {
        stopping.set(true) // aborts any takeover in progress on `queue`
        queue.sync {
            log.notice("signal \(sig, privacy: .public): handing fans back before exit")
            var ok = release(note: "Fan helper stopped")
            for _ in 0..<3 where !ok { ok = release(note: "Fan helper stopped") }
            // Exiting with failure makes launchd restart the daemon (unless it is being
            // unloaded), and the new instance retries the handback on start.
            exit(ok ? 0 : 1)
        }
    }

    // MARK: Sleep

    private func registerForSleep() {
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        powerPort = IORegisterForSystemPower(refcon, &powerNotifyPort, { refcon, _, message, argument in
            guard let refcon else { return }
            Unmanaged<FanService>.fromOpaque(refcon).takeUnretainedValue().power(message, argument)
        }, &powerNotifier)
        guard powerPort != 0, let powerNotifyPort else {
            log.error("could not register for sleep notifications")
            return
        }
        IONotificationPortSetDispatchQueue(powerNotifyPort, urgent)
    }

    /// Runs on `urgent`. Message values are iokit_common_msg() constants from IOMessage.h.
    fileprivate func power(_ message: natural_t, _ argument: UnsafeMutableRawPointer?) {
        switch message {
        case 0xE000_0270: // kIOMessageCanSystemSleep
            IOAllowPowerChange(powerPort, Int(bitPattern: argument))
        case 0xE000_0280: // kIOMessageSystemWillSleep
            sleeping.set(true) // aborts any takeover in progress
            queue.sync {
                if state.mode != .automatic || holding {
                    log.notice("system sleep: handing fans back")
                    var ok = release(note: "Mac went to sleep")
                    for _ in 0..<3 where !ok { ok = release(note: "Mac went to sleep") }
                }
            }
            IOAllowPowerChange(powerPort, Int(bitPattern: argument))
        case 0xE000_0300: // kIOMessageSystemHasPoweredOn
            sleeping.set(false)
        default:
            break
        }
    }

    // MARK: BoringNotchFanHelperProtocol

    func version(with reply: @escaping (String) -> Void) { reply(FanHelperConstants.version) }

    /// Answers immediately, even while a takeover is in progress.
    func state(with reply: @escaping (Data?) -> Void) {
        reply(try? JSONEncoder().encode(published.withLock { $0 }))
    }

    func apply(_ mode: String, level: Double, duration: Double, with reply: @escaping (String?) -> Void) {
        guard let mode = FanControlState.Mode(rawValue: mode), level.isFinite, duration.isFinite,
              (0...1).contains(level), (0...86_400).contains(duration) else { return reply("Invalid fan request.") }
        let request = generation.increment() // aborts any older takeover still running
        queue.async { [self] in
            lastActivity = Date()
            if stopping.isSet || sleeping.isSet { return reply("The fan helper is stopping.") }
            if mode == .automatic {
                return reply(release(note: nil) ? nil : "Still handing the fans back to macOS. Retrying every 2 seconds.")
            }
            if request != generation.current { return reply("Replaced by a newer request.") }
            state = FanControlState(mode: mode, level: mode == .maximum ? 1 : level,
                                    until: duration > 0 ? Date().addingTimeInterval(duration) : nil, note: nil)
            publish()
            log.notice("apply \(mode.rawValue, privacy: .public) level \(level, privacy: .public) for \(duration, privacy: .public) s")
            if let error = enforce(request) {
                if let until = state.until, until <= Date() {
                    release(note: "Timer finished")
                    return reply(nil)
                }
                if error == "Interrupted." {
                    // A newer request or shutdown is queued behind us; make sure nothing stays forced meanwhile.
                    release(note: nil, quiet: generation.current == request)
                    return reply("Replaced by a newer request.")
                }
                release(note: error)
                return reply(error)
            }
            reply(nil)
        }
    }

    // MARK: NSXPCListenerDelegate

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let path = proc_pidpath(connection.processIdentifier, &buffer, UInt32(buffer.count)) > 0 ? String(cString: buffer) : ""
        if path.hasPrefix(FanHelperConstants.clientPathPrefix) {
            connection.setCodeSigningRequirement("identifier \"\(FanHelperConstants.clientIdentifier)\"")
        } else if rootOnlyFile(FanHelperConstants.stressFlag) {
            connection.setCodeSigningRequirement("identifier \"\(FanHelperConstants.stressClientIdentifier)\"")
        } else {
            log.error("refused a client outside the installed app: \(path, privacy: .public)")
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
    log.error("AppleSMC is unavailable")
    exit(1)
}
let service = FanService(smc: smc)
service.start()
let listener = NSXPCListener(machServiceName: FanHelperConstants.label)
listener.delegate = service
listener.resume()
dispatchMain()
