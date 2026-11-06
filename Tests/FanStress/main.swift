// Stress test for handing the fans back to macOS. Run only through scripts/fan-stress-test.sh (as root).
// It drives the installed BoringNotchFanHelper daemon over XPC and checks the SMC directly after
// every step. "macOS in control" means every fan mode byte is 0 and Ftst is 0 (read back), and in
// the settle checks, that the forced target is gone and the fans spin down.

import Darwin
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)
guard getuid() == 0 else { print("Run through scripts/fan-stress-test.sh (needs root)."); exit(2) }
guard let smc = SMCConnection() else { print("AppleSMC unavailable"); exit(2) }
let label = FanHelperConstants.label
let hasFtst = smc.read("Ftst") != nil
let fans0 = SMCFan.readFans(smc)
guard !fans0.isEmpty else { print("No fans."); exit(2) }
let maxRPM = fans0.map(\.maximum).min()!
let started = Date()

// MARK: Helpers

func now() -> String { String(format: "%7.1fs", Date().timeIntervalSince(started)) }
func say(_ text: String) { print("\(now())  \(text)") }

func macOS() -> Bool { SMCFan.macOSInControl(smc, hasFtst: hasFtst) == true }
func smcLine() -> String { SMCFan.describe(smc) }
func modeByte(_ id: Int) -> UInt8? { smc.read(SMCFan.modeKey(smc, id))?.bytes.first }
/// All fans forced at roughly `rpm` (per-fan target for manual levels).
func forced(level: Double) -> Bool {
    let fans = SMCFan.readFans(smc)
    return !fans.isEmpty && fans.allSatisfy { fan in
        fan.manual && abs((fan.target ?? -1) - (fan.minimum + (fan.maximum - fan.minimum) * level)) < 2
    }
}
@discardableResult func wait(_ timeout: Double, every: Double = 0.1, _ condition: () -> Bool) -> Double? {
    let begin = Date()
    while Date().timeIntervalSince(begin) < timeout {
        if condition() { return Date().timeIntervalSince(begin) }
        usleep(UInt32(every * 1_000_000))
    }
    return condition() ? Date().timeIntervalSince(begin) : nil
}
func pause(_ seconds: Double) { usleep(UInt32(seconds * 1_000_000)) }

@discardableResult func shell(_ args: [String]) -> (Int32, String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: args[0])
    process.arguments = Array(args.dropFirst())
    let pipe = Pipe()
    process.standardOutput = pipe; process.standardError = pipe
    try? process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}
func daemonPID() -> Int? {
    let (code, out) = shell(["/bin/launchctl", "print", "system/\(label)"])
    guard code == 0 else { return nil }
    for line in out.split(separator: "\n") {
        let parts = line.trimmingCharacters(in: .whitespaces).components(separatedBy: " = ")
        if parts.count == 2, parts[0] == "pid", let pid = Int(parts[1]) { return pid }
    }
    return nil
}
func launchctlKill(_ signal: String) { shell(["/bin/launchctl", "kill", signal, "system/\(label)"]) }

// MARK: XPC

final class Client {
    private var connection: NSXPCConnection?
    private func proxy(_ onError: @escaping () -> Void) -> BoringNotchFanHelperProtocol? {
        if connection == nil {
            let next = NSXPCConnection(machServiceName: label, options: .privileged)
            next.remoteObjectInterface = NSXPCInterface(with: BoringNotchFanHelperProtocol.self)
            next.resume()
            connection = next
        }
        return connection?.remoteObjectProxyWithErrorHandler { _ in onError() } as? BoringNotchFanHelperProtocol
    }
    func close() { connection?.invalidate(); connection = nil }

    enum Outcome: Equatable { case ok, error(String), noReply }
    /// Sends a request and waits for its reply.
    @discardableResult func apply(_ mode: String, level: Double = 0, duration: Double = 0, timeout: Double = 50) -> Outcome {
        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock(); var outcome = Outcome.noReply
        guard let proxy = proxy({ semaphore.signal() }) else { return .noReply }
        proxy.apply(mode, level: level, duration: duration) { error in
            lock.lock(); outcome = error.map { .error($0) } ?? .ok; lock.unlock(); semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + timeout) == .timedOut { close() }
        lock.lock(); defer { lock.unlock() }
        return outcome
    }
    /// Sends a request without waiting.
    func send(_ mode: String, level: Double = 0, duration: Double = 0, done: @escaping (Outcome) -> Void = { _ in }) {
        guard let proxy = proxy({ done(.noReply) }) else { return done(.noReply) }
        proxy.apply(mode, level: level, duration: duration) { error in done(error.map { .error($0) } ?? .ok) }
    }
    func state() -> FanControlState? {
        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock(); var result: FanControlState?
        guard let proxy = proxy({ semaphore.signal() }) else { return nil }
        proxy.state { data in
            lock.lock(); result = data.flatMap { try? JSONDecoder().decode(FanControlState.self, from: $0) }; lock.unlock(); semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 5)
        lock.lock(); defer { lock.unlock() }
        return result
    }
}
let client = Client()

/// Last resort used by the harness itself: hand back to macOS directly as root.
func failsafe(_ why: String) {
    say("FAILSAFE (\(why)): requesting Auto, then direct SMC handback")
    _ = client.apply("automatic", timeout: 10)
    if !macOS() { _ = SMCFan.release(smc, hasFtst: hasFtst, rounds: 40) }
    say("failsafe result: macOS in control = \(macOS()) | \(smcLine())")
}
signal(SIGINT, SIG_IGN); signal(SIGTERM, SIG_IGN)
for sig in [SIGINT, SIGTERM] {
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
    source.setEventHandler { failsafe("interrupted"); exit(3) }
    source.resume()
    _ = Unmanaged.passRetained(source)
}
// Whole-run watchdog.
DispatchQueue.global().asyncAfter(deadline: .now() + 25 * 60) { failsafe("watchdog: run exceeded 25 minutes"); exit(4) }

// MARK: Test bookkeeping

var results: [(String, Bool, String)] = []
var currentFailures: [String] = []
func check(_ condition: Bool, _ what: String) {
    if !condition { currentFailures.append(what); say("   ✗ \(what) | \(smcLine())") }
}
func test(_ name: String, _ body: () -> String) {
    say("▶ \(name)")
    currentFailures = []
    let detail = body()
    // Every test must end with macOS in control. If it doesn't, restore before moving on.
    if !macOS() {
        check(false, "test ended with macOS NOT in control")
        failsafe("after \(name)")
    }
    let pass = currentFailures.isEmpty
    results.append((name, pass, pass ? detail : currentFailures.joined(separator: "; ")))
    say("   \(pass ? "PASS" : "FAIL") \(detail)")
}
func ms(_ seconds: Double?) -> String { seconds.map { String(format: "%.0f ms", $0 * 1000) } ?? "never" }
/// Waits for confirmed handback, returns seconds.
func handback(_ timeout: Double, _ what: String) -> Double? {
    let elapsed = wait(timeout) { macOS() }
    check(elapsed != nil, "\(what): macOS not in control after \(Int(timeout)) s")
    return elapsed
}
/// Behavioral check: the forced target is gone and the fans actually slow down under macOS.
func settles(_ what: String) -> Double? {
    let elapsed = wait(60, every: 0.5) {
        macOS() && SMCFan.readFans(smc).allSatisfy { ($0.target ?? 0) < maxRPM * 0.6 && $0.actual < maxRPM * 0.6 }
    }
    check(elapsed != nil, "\(what): fans did not spin down under macOS within 60 s")
    return elapsed
}
/// Proof that macOS itself is driving the fans again, not just that the mode bytes read automatic.
/// The handback clears each forced target to 0, so any of these must have been written by macOS:
/// a fan parked in mode 3, or a non-zero target on a fan in mode 0. A dead fan controller would
/// leave mode 0 with target 0 forever.
@discardableResult func macOSActive(_ what: String, timeout: Double = 45) -> Double? {
    let elapsed = wait(timeout, every: 0.2) {
        macOS() && SMCFan.readFans(smc).allSatisfy { fan in modeByte(fan.id) == 3 || (fan.target ?? 0) > 0 }
    }
    check(elapsed != nil, "\(what): macOS did not take over writing the fans within \(Int(timeout)) s")
    return elapsed
}
func take(_ mode: String = "maximum", level: Double = 1, duration: Double = 0) -> Bool {
    let outcome = client.apply(mode, level: level, duration: duration)
    check(outcome == .ok, "\(mode) request failed: \(outcome)")
    let ok = wait(3) { forced(level: mode == "maximum" ? 1 : level) } != nil
    check(ok, "fans not forced after \(mode) request")
    return ok
}

/// Proof that macOS is really driving the fans (not just that the mode bytes read 0): load every
/// CPU core and wait for macOS itself to raise the fan target. Run before any control and after all tests.
final class Spin: @unchecked Sendable { let lock = NSLock(); var on = true
    var running: Bool { lock.lock(); defer { lock.unlock() }; return on } }
func macOSRaisesFans(_ what: String, timeout: Double = 300) -> Double? {
    check(macOS(), "\(what): macOS not in control before the load test")
    let start = SMCFan.readFans(smc)
    let startTarget = start.map { $0.target ?? 0 }.max() ?? 0
    let minimum = start.map(\.minimum).min() ?? 1000
    let goal = minimum
    say("   loading all \(ProcessInfo.processInfo.activeProcessorCount) cores until macOS raises the fan target to ≥ \(Int(goal)) rpm (start \(Int(startTarget)))")
    let spin = Spin()
    for _ in 0..<ProcessInfo.processInfo.activeProcessorCount {
        Thread.detachNewThread {
            var x = 1.000001
            while spin.running { for _ in 0..<200_000 { x = x * 1.0000001 + 0.0000001 }; if x == 0 { print(x) } }
        }
    }
    var lastLog = Date()
    let elapsed = wait(timeout, every: 1) {
        if Date().timeIntervalSince(lastLog) > 30 {
            lastLog = Date()
            say("   … \(smcLine()) cpu \(SMCFan.cpuTemperature(smc).map { String(format: "%.0f°C", $0) } ?? "?")")
        }
        return macOS() && SMCFan.readFans(smc).contains { modeByte($0.id) == 0 && ($0.target ?? 0) >= goal && $0.actual > minimum * 0.8 }
    }
    spin.lock.lock(); spin.on = false; spin.lock.unlock()
    check(elapsed != nil, "\(what): macOS never raised the fans under full CPU load in \(Int(timeout)) s")
    check(macOS(), "\(what): mode bytes changed during the load test")
    say("   → \(smcLine()) cpu \(SMCFan.cpuTemperature(smc).map { String(format: "%.0f°C", $0) } ?? "?")")
    return elapsed
}

say("Fans: \(fans0.map { "fan\($0.id + 1) \(Int($0.minimum))–\(Int($0.maximum)) rpm" }.joined(separator: ", ")); Ftst present: \(hasFtst)")
say("Start: \(smcLine())")
if !macOS() { failsafe("fans were not on macOS control at start") }

// MARK: Tests

test("01 invalid requests are refused and change nothing") {
    for (mode, level, duration) in [("off", 0.5, 0.0), ("manual", 1.5, 0), ("manual", -0.1, 0), ("manual", .nan, 0),
                                    ("maximum", 1, -5), ("maximum", 1, 1e9), ("maximum", 1, .infinity)] {
        let outcome = client.apply(mode, level: level, duration: duration, timeout: 5)
        check(outcome == .error("Invalid fan request."), "\(mode)/\(level)/\(duration) answered \(outcome)")
    }
    check(macOS(), "an invalid request changed the fans")
    check(client.state()?.mode == .automatic, "daemon state changed")
    return "7 invalid requests refused"
}

test("02 Max then Auto, with spin-down") {
    guard take() else { return "" }
    let up = wait(20, every: 0.5) { SMCFan.readFans(smc).allSatisfy { $0.actual > maxRPM * 0.7 } }
    check(up != nil, "fans never spun up under Max")
    let begin = Date()
    let outcome = client.apply("automatic")
    let reply = Date().timeIntervalSince(begin)
    check(outcome == .ok, "Auto answered \(outcome)")
    check(macOS(), "macOS not in control when Auto replied")
    check(client.state()?.mode == .automatic, "daemon state not automatic")
    let active = macOSActive("after Auto")
    let down = settles("after Auto")
    return "spun up in \(ms(up)); Auto confirmed in \(ms(reply)); macOS wrote the fans after \(ms(active)); settled in \(ms(down))"
}

test("03 Manual levels hit their targets, then Auto") {
    for level in [0.0, 0.33, 0.75, 1.0] {
        let outcome = client.apply("manual", level: level)
        check(outcome == .ok, "manual \(level) answered \(outcome)")
        check(wait(3) { forced(level: level) } != nil, "manual \(level) target not applied")
    }
    check(client.apply("automatic") == .ok, "Auto failed")
    check(macOS(), "macOS not in control after Auto")
    return "4 levels applied and released"
}

test("04 25 rapid take/release cycles") {
    var worst = 0.0
    for cycle in 1...25 {
        let level = [0.2, 0.5, 1.0][cycle % 3]
        _ = take(cycle % 2 == 0 ? "maximum" : "manual", level: level)
        pause(Double(cycle % 3) * 0.5)
        let begin = Date()
        let outcome = client.apply("automatic")
        worst = max(worst, Date().timeIntervalSince(begin))
        check(outcome == .ok, "cycle \(cycle): Auto answered \(outcome)")
        check(macOS(), "cycle \(cycle): macOS not in control right after Auto")
        pause(0.3)
        check(macOS(), "cycle \(cycle): fans re-forced after Auto")
    }
    let active = macOSActive("after 25 cycles")
    return "25 cycles, slowest confirmed handback \(ms(worst)); macOS driving again after \(ms(active))"
}

test("05 Stop while the takeover is still running") {
    var detail: [String] = []
    for delay in [0.0, 0.3, 1.0, 2.5, 3.5] {
        let late = DispatchSemaphore(value: 0)
        client.send("maximum") { _ in late.signal() }
        // The app sends requests one at a time, so Stop always reaches the helper after Max.
        check(wait(5, every: 0.005) { client.state()?.mode == .maximum } != nil, "Max never reached the helper")
        pause(delay)
        let begin = Date()
        let outcome = client.apply("automatic")
        let reply = Date().timeIntervalSince(begin)
        check(outcome == .ok, "Stop after \(delay)s answered \(outcome)")
        check(macOS(), "Stop after \(delay)s: macOS not in control when Stop replied")
        _ = late.wait(timeout: .now() + 40)
        pause(2.5) // a tick later, the stale Max must not have come back
        check(macOS(), "Stop after \(delay)s: the earlier Max re-took the fans")
        detail.append("\(delay)s→\(ms(reply))")
    }
    macOSActive("after Stop tests")
    return "Stop replies: " + detail.joined(separator: ", ")
}

test("06 request storm from 4 connections ending in Auto") {
    let group = DispatchGroup()
    for worker in 0..<4 {
        group.enter()
        DispatchQueue.global().async {
            let own = Client()
            let inner = DispatchGroup()
            for i in 0..<12 {
                inner.enter()
                let mode = ["maximum", "manual", "automatic"][(i + worker) % 3]
                own.send(mode, level: Double(i % 4) / 3, duration: Double(i % 2) * 30) { _ in inner.leave() }
                usleep(UInt32.random(in: 0...150_000))
            }
            _ = inner.wait(timeout: .now() + 120)
            own.close()
            group.leave()
        }
    }
    _ = group.wait(timeout: .now() + 150)
    let begin = Date()
    check(client.apply("automatic") == .ok, "final Auto failed")
    check(macOS(), "macOS not in control after final Auto")
    pause(5)
    check(macOS(), "fans re-forced after the storm settled")
    return "48 overlapping requests, final Auto confirmed in \(ms(Date().timeIntervalSince(begin)))"
}

test("07 timed cool-down ends by itself") {
    guard take(duration: 10) else { return "" }
    let begin = Date()
    pause(6)
    check(forced(level: 1), "released before the timer ended")
    let elapsed = wait(15) { macOS() }.map { $0 + 6 }
    check(elapsed != nil, "timer never handed back")
    check((elapsed ?? 99) <= 13, "timer handback late")
    check(client.state()?.note == "Timer finished", "note is \(client.state()?.note ?? "nil")")
    _ = begin
    let active = macOSActive("after timer")
    return "10 s timer handed back at \(String(format: "%.1f", elapsed ?? -1)) s; macOS driving after \(ms(active))"
}

test("08 app quits during a cool-down; daemon then exits when idle") {
    guard take(duration: 30) else { return "" }
    client.close() // like BoringNotch quitting
    pause(20)
    check(forced(level: 1), "released early after the client left")
    check(daemonPID() != nil, "daemon exited while holding the fans")
    let back = wait(20) { macOS() }.map { $0 + 20 }
    check(back != nil, "timer did not hand back without a client")
    check((back ?? 99) <= 33, "timer handback late")
    macOSActive("after timer with no client")
    let gone = wait(75, every: 1) { daemonPID() == nil }
    check(gone != nil, "daemon did not exit when idle")
    check(macOS(), "macOS not in control after idle exit")
    return "handed back at \(String(format: "%.1f", back ?? -1)) s of 30 s with no client; idle exit after \(String(format: "%.0f", gone ?? -1)) s"
}

test("09 daemon crashes (SIGKILL) while holding, 3 times") {
    var times: [String] = []
    for round in 1...3 {
        guard take() else { break }
        let pid = daemonPID()
        launchctlKill("SIGKILL")
        client.close()
        let elapsed = handback(20, "crash \(round)")
        check(daemonPID() != nil && daemonPID() != pid, "crash \(round): launchd did not restart the daemon")
        times.append(ms(elapsed))
        pause(1)
    }
    let active = macOSActive("after crashes")
    return "handback after crash: \(times.joined(separator: ", ")); macOS driving after \(ms(active))"
}

test("10 daemon crashes (SIGKILL) in the middle of a takeover") {
    var times: [String] = []
    for delay in [0.2, 1.5, 3.2] {
        client.send("maximum")
        pause(delay)
        launchctlKill("SIGKILL")
        client.close()
        times.append("\(delay)s→" + ms(handback(20, "crash at \(delay)s")))
        pause(2.5)
        check(macOS(), "crash at \(delay)s: fans re-forced afterwards")
    }
    macOSActive("after mid-takeover crashes")
    return "handback: " + times.joined(separator: ", ")
}

test("11 SIGTERM while holding and during a takeover") {
    var times: [String] = []
    guard take() else { return "" }
    launchctlKill("SIGTERM")
    client.close()
    times.append("holding→" + ms(handback(10, "SIGTERM while holding")))
    for delay in [0.3, 2.0] {
        client.send("maximum")
        pause(delay)
        launchctlKill("SIGTERM")
        client.close()
        times.append("takeover \(delay)s→" + ms(handback(10, "SIGTERM during takeover")))
        pause(2.5)
        check(macOS(), "fans re-forced after SIGTERM")
    }
    macOSActive("after SIGTERM")
    return times.joined(separator: ", ")
}

test("12 uninstall-style unload (bootout) while holding, then reload") {
    guard take() else { return "" }
    let begin = Date()
    let (code, out) = shell(["/bin/launchctl", "bootout", "system/\(label)"])
    client.close()
    check(code == 0, "bootout failed: \(out)")
    // bootout returns before the helper exits; the helper hands back on SIGTERM.
    let took = wait(10) { macOS() }.map { _ in Date().timeIntervalSince(begin) }
    check(took != nil, "fans not handed back after bootout")
    macOSActive("after bootout")
    var loaded = false
    for _ in 0..<40 where !loaded {
        loaded = shell(["/bin/launchctl", "bootstrap", "system", FanHelperConstants.installedPlist]).0 == 0
        if !loaded { pause(0.25) }
    }
    check(loaded, "could not reload the helper")
    check(client.state() != nil, "daemon not reachable after reload")
    return "fans handed back \(ms(took)) after bootout; reloaded"
}

test("13 injected handback write failures are retried until confirmed") {
    guard take() else { return "" }
    FileManager.default.createFile(atPath: FanHelperConstants.faultFile, contents: "30".data(using: .utf8), attributes: [.posixPermissions: 0o600])
    let begin = Date()
    let outcome = client.apply("automatic")
    check(outcome != .ok, "Auto reported success although every write was skipped")
    check(!macOS(), "fault injection did not take effect (test invalid)")
    check(client.state()?.releasePending == true, "state does not report the pending handback")
    let elapsed = wait(20) { macOS() }.map { _ in Date().timeIntervalSince(begin) }
    check(elapsed != nil, "pending handback was never retried to success")
    pause(2.5)
    check(client.state()?.releasePending == nil, "releasePending still set after success")
    macOSActive("after injected failures")
    return "first Auto correctly reported failure; retried and confirmed after \(String(format: "%.1f", elapsed ?? -1)) s"
}

test("14 failed handback blocks shutdown until it succeeds") {
    guard take() else { return "" }
    FileManager.default.createFile(atPath: FanHelperConstants.faultFile, contents: "60".data(using: .utf8), attributes: [.posixPermissions: 0o600])
    launchctlKill("SIGTERM") // daemon retries 4×20 rounds, then exits(1) and launchd restarts it
    client.close()
    let elapsed = handback(40, "SIGTERM with failing writes")
    macOSActive("after SIGTERM with failing writes")
    return "handed back in \(ms(elapsed)) despite 60 failed write rounds"
}

// MARK: Report

client.apply("automatic", timeout: 10)
test("15 after all tests: Max, Auto, then macOS turns the fans on by itself under load") {
    guard take() else { return "" }
    check(client.apply("automatic") == .ok, "Auto failed")
    let active = macOSActive("final")
    let elapsed = macOSRaisesFans("final", timeout: 240)
    return "macOS driving after \(ms(active)); under full load macOS had the fans on after \(String(format: "%.0f", elapsed ?? -1)) s"
}
let finalSettle = wait(1) { macOS() }
say("End: \(smcLine())")
print("\n================ FAN HANDBACK STRESS TEST ================")
for (name, pass, detail) in results { print("\(pass ? "PASS" : "FAIL")  \(name)\n      \(detail)") }
let failed = results.filter { !$0.1 }.count
_ = finalSettle
print("Final: macOS in control = \(macOS()); \(smcLine())")
print("\(results.count - failed)/\(results.count) passed in \(Int(Date().timeIntervalSince(started))) s")
exit(failed == 0 && macOS() ? 0 : 1)
