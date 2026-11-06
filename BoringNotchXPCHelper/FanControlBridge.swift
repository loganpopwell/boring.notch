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
            // Taking the fans from macOS can take a few seconds on M1–M4.
            let result: String?? = call(45) { proxy, done in proxy.apply(mode, level: level, duration: duration, with: done) }
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
            let plist: [String: Any] = [
                "Label": label,
                "ProgramArguments": [FanHelperConstants.installedBinary],
                "MachServices": [label: true],
                "KeepAlive": ["SuccessfulExit": false],
                "AssociatedBundleIdentifiers": ["theboringteam.boringnotch"],
            ]
            let staged = FileManager.default.temporaryDirectory.appendingPathComponent("\(label).plist")
            do {
                let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                try data.write(to: staged, options: .atomic)
            } catch { return reply("Could not prepare the helper: \(error.localizedDescription)") }
            let quote: (String) -> String = { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            let shell = [
                "/bin/launchctl bootout system/\(label) >/dev/null 2>&1; /bin/mkdir -p /Library/PrivilegedHelperTools",
                "/usr/bin/install -o root -g wheel -m 0755 \(quote(bundledBinary.path)) \(quote(FanHelperConstants.installedBinary))",
                "/usr/bin/install -o root -g wheel -m 0644 \(quote(staged.path)) \(quote(FanHelperConstants.installedPlist))",
                "/bin/launchctl bootstrap system \(quote(FanHelperConstants.installedPlist))",
            ].joined(separator: " && ")
            connection?.invalidate(); connection = nil; lastState = nil
            let error = runAsAdmin(shell, prompt: "BoringNotch wants to install its fan control helper.")
            try? FileManager.default.removeItem(at: staged)
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
