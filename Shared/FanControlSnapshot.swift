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
    static let version = "1"
    static let installedBinary = "/Library/PrivilegedHelperTools/\(label)"
    static let installedPlist = "/Library/LaunchDaemons/\(label).plist"
    /// Only this signed XPC service, living inside the installed app, may drive the fans.
    static let clientIdentifier = "theboringteam.boringnotch.BoringNotchXPCHelper"
    static let clientPathPrefix = "/Applications/boringNotch.app/Contents/XPCServices/"
}
