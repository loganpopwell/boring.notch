import Foundation

/// One fan as read from the SMC. Speeds are RPM.
struct FanControlFan: Codable, Identifiable, Equatable {
    var id: Int
    var actual: Double
    var minimum: Double
    var maximum: Double
    var target: Double?
    var manual: Bool
}

/// What the privileged fan helper is currently enforcing.
struct FanControlState: Codable, Equatable {
    enum Mode: String, Codable { case automatic, manual, maximum }
    var mode: Mode = .automatic
    /// 0...1 of each fan's min–max range. Only meaningful for `.manual`.
    var level: Double = 0
    /// When the helper hands control back to macOS. `nil` means until changed.
    var until: Date?
    /// Set when the helper reverted on its own (timer, heat, or error).
    var note: String?
    /// True while the helper is still retrying the handback to macOS.
    var releasePending: Bool?
}

struct FanControlSnapshot: Codable, Equatable {
    enum Helper: String, Codable { case notInstalled, outdated, unreachable, ready }
    var fans: [FanControlFan] = []
    var cpuTemperature: Double?
    var gpuTemperature: Double?
    var helper: Helper = .notInstalled
    var state: FanControlState?
    var error: String?
}

enum FanHelperConstants {
    static let label = "theboringteam.boringnotch.FanHelper"
    /// Bump when the helper's behavior or protocol changes so the app offers an update.
    static let version = "6"
    static let installedBinary = "/Library/PrivilegedHelperTools/\(label)"
    static let installedPlist = "/Library/LaunchDaemons/\(label).plist"
    /// Only this signed XPC service, living inside the installed app, may drive the fans.
    static let clientIdentifier = "theboringteam.boringnotch.BoringNotchXPCHelper"
    static let clientPathPrefix = "/Applications/boringNotch.app/Contents/XPCServices/"
    /// Present (root-owned, not writable by others) only while scripts/fan-stress-test.sh runs.
    /// It lets the stress client connect and enables fault injection. Only root can create it.
    static let stressFlag = "/Library/PrivilegedHelperTools/\(label).stress-test"
    static let faultFile = "/Library/PrivilegedHelperTools/\(label).fault"
    /// Exists from before the daemon's first takeover write until a confirmed handback, so a
    /// restarted daemon knows late SMC writes may still land. /var/run is cleared at boot.
    static let holdingMarker = "/var/run/\(label).holding"
    static let stressClientIdentifier = "theboringteam.boringnotch.FanStressTest"
}
