import Foundation

/// Interface of the root `BoringNotchFanHelper` launch daemon. Only the BoringNotch XPC helper talks to it.
@objc protocol BoringNotchFanHelperProtocol {
    func version(with reply: @escaping (String) -> Void)
    /// JSON-encoded `FanControlState`.
    func state(with reply: @escaping (Data?) -> Void)
    /// `mode` is a `FanControlState.Mode` raw value. `level` is 0...1 of each fan's range (manual only).
    /// `duration` is seconds before control returns to macOS; 0 keeps it until changed.
    /// Replies with an error message, or nil on success.
    func apply(_ mode: String, level: Double, duration: Double, with reply: @escaping (String?) -> Void)
}
