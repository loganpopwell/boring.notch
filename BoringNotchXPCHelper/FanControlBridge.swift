import Foundation

/// Reads fans as the user and forwards control requests to the root fan helper daemon.
final class FanControlBridge: @unchecked Sendable {
    static let shared = FanControlBridge()
    private let queue = DispatchQueue(label: "local.boringnotch.fan-control", qos: .utility)
    private lazy var smc = SMCConnection()
    private var connection: NSXPCConnection?
    private var lastState: FanControlState?

    private var bundledBinary: URL {
        // …/boringNotch.app/Contents/XPCServices/BoringNotchXPCHelper.xpc → …/boringNotch.app
        Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Contents/Library/LaunchServices/\(FanHelperConstants.label)")
    }

    private func daemon(_ errorHandler: @escaping (Error) -> Void) -> BoringNotchFanHelperProtocol? {
        if connection == nil {
            let next = NSXPCConnection(machServiceName: FanHelperConstants.label, options: .privileged)
            next.remoteObjectInterface = NSXPCInterface(with: BoringNotchFanHelperProtocol.self)
            next.invalidationHandler = { [weak self] in self?.queue.async { self?.connection = nil } }
            next.resume()
            connection = next
        }
        return connection?.remoteObjectProxyWithErrorHandler(errorHandler) as? BoringNotchFanHelperProtocol
    }

    /// Calls the daemon and waits up to `timeout` seconds. Must run on `queue`.
    private func call<T>(_ timeout: Double, _ body: (BoringNotchFanHelperProtocol, @escaping (T) -> Void) -> Void) -> T? {
        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var result: T?
        guard let proxy = daemon({ _ in semaphore.signal() }) else { return nil }
        body(proxy) { value in lock.lock(); result = value; lock.unlock(); semaphore.signal() }
        _ = semaphore.wait(timeout: .now() + timeout)
        lock.lock(); defer { lock.unlock() }
        return result
    }

    func read(_ reply: @escaping (Data?) -> Void) {
        queue.async { [self] in
            var snapshot = FanControlSnapshot()
            if let smc {
                snapshot.fans = SMCFan.readFans(smc)
                snapshot.cpuTemperature = SMCFan.cpuTemperature(smc)
                snapshot.gpuTemperature = SMCFan.gpuTemperature(smc)
            } else {
                snapshot.error = "Fan sensors are unavailable."
            }
            if FileManager.default.fileExists(atPath: FanHelperConstants.installedPlist) {
                if let version: String = call(1.5, { proxy, done in proxy.version(with: done) }) {
                    snapshot.helper = version == FanHelperConstants.version ? .ready : .outdated
                    if let data: Data? = call(1.5, { proxy, done in proxy.state(with: done) }), let data,
                       let state = try? JSONDecoder().decode(FanControlState.self, from: data) {
                        lastState = state
                    }
                    snapshot.state = lastState
                } else {
                    // Busy applying a change, or not loaded. Keep showing the last known mode.
                    snapshot.helper = lastState == nil ? .unreachable : .ready
                    snapshot.state = lastState
                }
            }
            reply(try? JSONEncoder().encode(snapshot))
        }
    }

    func apply(_ mode: String, level: Double, duration: Double, _ reply: @escaping (String?) -> Void) {
        queue.async { [self] in
            // Taking the fans from macOS takes up to ~10 s on M1–M4, and a confirmed handback a few seconds.
            let send: () -> String?? = { [self] in call(60) { proxy, done in proxy.apply(mode, level: level, duration: duration, with: done) } }
            let started = Date()
            var result = send()
            if result == nil, Date().timeIntervalSince(started) < 3 {
                // The connection dropped at once: the helper was exiting (idle or restarted). launchd
                // starts a fresh one on the next message. Every request sets a whole state, so resending is safe.
                connection?.invalidate(); connection = nil
                result = send()
            }
            guard let result else { return reply("The fan helper did not respond.") }
            if result == nil, let mode = FanControlState.Mode(rawValue: mode) {
                lastState = FanControlState(mode: mode, level: mode == .maximum ? 1 : level,
                                            until: duration > 0 ? Date().addingTimeInterval(duration) : nil)
            }
            reply(result)
        }
    }

    private func runAsAdmin(_ shell: String, prompt: String) -> String? {
        let escape: (String) -> String = { $0.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "do shell script \"\(escape(shell))\" with prompt \"\(escape(prompt))\" with administrator privileges"]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        do { try process.run() } catch { return error.localizedDescription }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return message.contains("-128") ? "Cancelled." : "Install failed: \(message.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
        return nil
    }

    func install(_ reply: @escaping (String?) -> Void) {
        queue.async { [self] in
            let label = FanHelperConstants.label
            guard FileManager.default.isExecutableFile(atPath: bundledBinary.path) else {
                return reply("This build does not include the fan helper.")
            }
            let quote: (String) -> String = { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            let plistPath = quote(FanHelperConstants.installedPlist)
            // bootout sends SIGTERM, and a running helper hands the fans back before exiting.
            // The launchd job definition comes from the helper itself (--launchd-plist).
            let shell = [
                "/bin/launchctl bootout system/\(label) >/dev/null 2>&1; /bin/mkdir -p /Library/PrivilegedHelperTools",
                "/usr/bin/install -o root -g wheel -m 0755 \(quote(bundledBinary.path)) \(quote(FanHelperConstants.installedBinary))",
                "\(quote(FanHelperConstants.installedBinary)) --launchd-plist > \(plistPath)",
                "/usr/sbin/chown root:wheel \(plistPath) && /bin/chmod 0644 \(plistPath)",
                // bootout returns before the old helper has exited; retry until launchd accepts the job.
                "{ i=0; until /bin/launchctl bootstrap system \(plistPath) 2>/dev/null; do i=$((i+1)); [ $i -ge 40 ] && exit 1; sleep 0.25; done; }",
            ].joined(separator: " && ")
            connection?.invalidate(); connection = nil; lastState = nil
            let error = runAsAdmin(shell, prompt: "BoringNotch wants to install its fan control helper.")
            reply(error)
        }
    }

    func uninstall(_ reply: @escaping (String?) -> Void) {
        queue.async { [self] in
            let label = FanHelperConstants.label
            connection?.invalidate(); connection = nil; lastState = nil
            // bootout sends SIGTERM, and the helper hands the fans back to macOS before exiting.
            let shell = "/bin/launchctl bootout system/\(label) >/dev/null 2>&1; /bin/rm -f '\(FanHelperConstants.installedPlist)' '\(FanHelperConstants.installedBinary)'"
            reply(runAsAdmin(shell, prompt: "BoringNotch wants to remove its fan control helper."))
        }
    }
}
