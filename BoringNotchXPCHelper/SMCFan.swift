// SMC access for fan readings and fan control.
// The key layout, Apple Silicon `Ftst` unlock sequence and retry timings follow
// exelban/stats (MIT License, Copyright (c) 2019 Serhiy Mytrovtsiy). See THIRD_PARTY_LICENSES.
//
// Reads work as the logged-in user. Writes need root, so only the privileged
// BoringNotchFanHelper daemon calls the write functions.

import Foundation
import IOKit

private struct SMCKeyData {
    typealias Bytes = (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                       UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                       UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                       UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)
    struct Version { var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0; var release: UInt16 = 0 }
    struct PLimit { var version: UInt16 = 0, length: UInt16 = 0; var cpu: UInt32 = 0, gpu: UInt32 = 0, mem: UInt32 = 0 }
    struct KeyInfo { var dataSize: UInt32 = 0; var dataType: UInt32 = 0; var dataAttributes: UInt8 = 0 }
    var key: UInt32 = 0
    var vers = Version()
    var pLimit = PLimit()
    var keyInfo = KeyInfo()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: Bytes = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

struct SMCValue {
    var type: String
    var bytes: [UInt8]
}

final class SMCConnection {
    private var conn: io_connect_t = 0
    private let lock = NSLock()
    private var infoCache: [UInt32: SMCKeyData.KeyInfo] = [:]

    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &conn) == kIOReturnSuccess else { return nil }
    }

    deinit { IOServiceClose(conn) }

    private static func code(_ key: String) -> UInt32? {
        let utf8 = Array(key.utf8)
        guard utf8.count == 4 else { return nil }
        return utf8.reduce(0) { $0 << 8 | UInt32($1) }
    }

    private static func string(_ code: UInt32) -> String {
        String(bytes: [24, 16, 8, 0].map { UInt8(code >> $0 & 0xff) }, encoding: .ascii) ?? ""
    }

    private func call(_ input: inout SMCKeyData, _ output: inout SMCKeyData) -> kern_return_t {
        var size = MemoryLayout<SMCKeyData>.stride
        return IOConnectCallStructMethod(conn, 2, &input, MemoryLayout<SMCKeyData>.stride, &output, &size)
    }

    private func keyInfo(_ code: UInt32) -> SMCKeyData.KeyInfo? {
        if let cached = infoCache[code] { return cached }
        var input = SMCKeyData(), output = SMCKeyData()
        input.key = code
        input.data8 = 9 // read key info
        guard call(&input, &output) == kIOReturnSuccess, output.result == 0, output.keyInfo.dataSize > 0, output.keyInfo.dataSize <= 32 else { return nil }
        infoCache[code] = output.keyInfo
        return output.keyInfo
    }

    func read(_ key: String) -> SMCValue? {
        guard let code = Self.code(key) else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard let info = keyInfo(code) else { return nil }
        var input = SMCKeyData(), output = SMCKeyData()
        input.key = code
        input.keyInfo.dataSize = info.dataSize
        input.data8 = 5 // read bytes
        guard call(&input, &output) == kIOReturnSuccess, output.result == 0 else { return nil }
        let all = withUnsafeBytes(of: output.bytes) { Array($0) }
        return SMCValue(type: Self.string(info.dataType), bytes: Array(all.prefix(Int(info.dataSize))))
    }

    /// Writes raw bytes. The SMC can accept the IOKit call yet reject the value, so both results are checked.
    func write(_ key: String, _ bytes: [UInt8]) -> Bool {
        guard let code = Self.code(key) else { return false }
        lock.lock(); defer { lock.unlock() }
        guard let info = keyInfo(code), bytes.count == Int(info.dataSize) else { return false }
        var input = SMCKeyData(), output = SMCKeyData()
        input.key = code
        input.data8 = 6 // write bytes
        input.keyInfo.dataSize = info.dataSize
        withUnsafeMutableBytes(of: &input.bytes) { buffer in
            for (i, byte) in bytes.enumerated() { buffer[i] = byte }
        }
        return call(&input, &output) == kIOReturnSuccess && output.result == 0
    }

    func number(_ key: String) -> Double? {
        guard let value = read(key), !value.bytes.isEmpty else { return nil }
        let b = value.bytes
        switch value.type {
        case "flt " where b.count >= 4:
            let raw = UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
            let float = Double(Float(bitPattern: raw))
            return float.isFinite ? float : nil
        case "ui8 ": return Double(b[0])
        case "ui16" where b.count >= 2: return Double(UInt16(b[0]) << 8 | UInt16(b[1]))
        case "ui32" where b.count >= 4: return Double(UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3]))
        case "fpe2" where b.count >= 2: return Double(Int(b[0]) << 6 + Int(b[1]) >> 2)
        case "sp78" where b.count >= 2: return Double(Int16(bitPattern: UInt16(b[0]) << 8 | UInt16(b[1]))) / 256
        default: return nil
        }
    }
}

enum SMCFan {
    static func modeKey(_ smc: SMCConnection, _ id: Int) -> String {
        smc.read("F\(id)md") != nil ? "F\(id)md" : "F\(id)Md"
    }

    static func count(_ smc: SMCConnection) -> Int {
        min(4, max(0, Int(smc.number("FNum") ?? 0)))
    }

    /// Fan mode byte values: 0 = automatic, 3 = automatic with the fan parked (macOS sets this
    /// when it stops the fans), 1 = forced. Anything else is treated as not automatic.
    static func isAutomatic(_ mode: UInt8) -> Bool { mode == 0 || mode == 3 }

    /// Raw state for logs: Ftst and each fan's mode byte and target.
    static func describe(_ smc: SMCConnection) -> String {
        let ftst = smc.read("Ftst")?.bytes.first.map(String.init) ?? "?"
        let fans = (0..<count(smc)).map { id in
            "F\(id) mode=\(smc.read(modeKey(smc, id))?.bytes.first.map(String.init) ?? "?") tg=\(smc.number("F\(id)Tg").map { String(Int($0)) } ?? "?") ac=\(smc.number("F\(id)Ac").map { String(Int($0)) } ?? "?")"
        }
        return "Ftst=\(ftst) " + fans.joined(separator: " ")
    }

    static func readFans(_ smc: SMCConnection) -> [FanControlFan] {
        (0..<count(smc)).compactMap { id in
            guard let actual = smc.number("F\(id)Ac") else { return nil }
            let minimum = smc.number("F\(id)Mn") ?? 0
            let maximum = smc.number("F\(id)Mx") ?? max(actual, minimum)
            let mode = smc.read(modeKey(smc, id))?.bytes.first ?? 0
            return FanControlFan(id: id, actual: max(0, actual), minimum: minimum, maximum: maximum,
                                 target: smc.number("F\(id)Tg"), manual: mode == 1)
        }
    }

    private static let cpuKeys = ["Tp01", "Tp05", "Tp09", "Tp0D", "Tp0V", "Tp0Y", "Tp0b", "Tp0e", "Te05", "Te0S", "Te09", "Te0H", // M4
                                  "Tp0j", "Tp0n", "Tp0h", "Tp0L", "Tp0P", "Tp0X", "Tp0f", "Tp0T", "Tp0H", "Tp0D", // M1–M3
                                  "TC0P", "TC0D", "TC0E"] // Intel
    private static let gpuKeys = ["Tg1U", "Tg1k", "Tg0G", "Tg0H", "Tg0K", "Tg0L", "Tg0d", "Tg0e", "Tg0j", "Tg0k", "Tg0f", "Tg0n", "TG0P", "TG0D"]

    private static func average(_ smc: SMCConnection, _ keys: [String]) -> Double? {
        let values = Set(keys).compactMap { smc.number($0) }.filter { $0 > 5 && $0 < 130 }
        return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    static func cpuTemperature(_ smc: SMCConnection) -> Double? { average(smc, cpuKeys) }
    static func gpuTemperature(_ smc: SMCConnection) -> Double? { average(smc, gpuKeys) }

    // MARK: Writes (root only)

    /// Return true to stop a long retry loop early (a newer request, shutdown, or sleep).
    typealias Abort = () -> Bool

    private static func writeRetrying(_ smc: SMCConnection, _ key: String, _ bytes: [UInt8], attempts: Int, delay: UInt32, abort: Abort = { false }) -> Bool {
        for attempt in 0..<attempts {
            if smc.write(key, bytes) { return true }
            if abort() { return false }
            if attempt < attempts - 1 { usleep(delay) }
        }
        return false
    }

    private static func setModeByte(_ smc: SMCConnection, _ id: Int, _ value: UInt8, attempts: Int = 10, delay: UInt32 = 50_000, abort: Abort = { false }) -> Bool {
        let key = modeKey(smc, id)
        guard var current = smc.read(key)?.bytes, !current.isEmpty else { return false }
        if current[0] == value { return true }
        current[0] = value
        return writeRetrying(smc, key, current, attempts: attempts, delay: delay, abort: abort)
    }

    /// Puts a fan in forced (manual) mode. M5 and later accept the mode write directly;
    /// M1–M4 first need `Ftst` = 1 so thermalmonitord yields, which takes a few seconds.
    /// Every wait checks `abort` at least every 100 ms.
    static func unlock(_ smc: SMCConnection, _ id: Int, abort: Abort) -> Bool {
        if smc.read(modeKey(smc, id))?.bytes.first == 1 { return true }
        if setModeByte(smc, id, 1, attempts: 1, delay: 0) { return true }
        guard let ftst = smc.read("Ftst"), !ftst.bytes.isEmpty else { return false }
        if ftst.bytes[0] != 1 {
            var bytes = ftst.bytes; bytes[0] = 1
            guard writeRetrying(smc, "Ftst", bytes, attempts: 100, delay: 50_000, abort: abort) else { return false }
            for _ in 0..<30 {
                if abort() { return false }
                usleep(100_000)
            }
            return setModeByte(smc, id, 1, attempts: 300, delay: 100_000, abort: abort)
        }
        return setModeByte(smc, id, 1, attempts: 20, delay: 100_000, abort: abort)
    }

    static func setTarget(_ smc: SMCConnection, _ id: Int, rpm: Double, attempts: Int = 10, abort: Abort = { false }) -> Bool {
        let key = "F\(id)Tg"
        guard let value = smc.read(key) else { return false }
        let bytes: [UInt8]
        switch value.type {
        case "flt ":
            let bits = Float(rpm).bitPattern
            bytes = [UInt8(bits & 0xff), UInt8(bits >> 8 & 0xff), UInt8(bits >> 16 & 0xff), UInt8(bits >> 24 & 0xff)]
        case "fpe2":
            let speed = min(16383, max(0, Int(rpm)))
            bytes = [UInt8(speed >> 6), UInt8((speed << 2) & 0xff)]
        default: return false
        }
        return writeRetrying(smc, key, bytes, attempts: attempts, delay: 50_000, abort: abort)
    }

    /// Reads whether macOS owns every fan: each fan's mode byte is automatic (0 or 3) and,
    /// on Macs that have it, `Ftst` is 0. Returns nil when any of those keys can't be read,
    /// so an unreadable SMC never counts as handed back.
    static func macOSInControl(_ smc: SMCConnection, hasFtst: Bool) -> Bool? {
        guard let fanCount = smc.number("FNum").map(Int.init), (0...9).contains(fanCount) else { return nil }
        if hasFtst {
            guard let ftst = smc.read("Ftst")?.bytes.first else { return nil }
            if ftst != 0 { return false }
        }
        for id in 0..<fanCount {
            guard let mode = smc.read(modeKey(smc, id))?.bytes.first else { return nil }
            if !isAutomatic(mode) { return false }
        }
        return true
    }

    /// Hands every fan back to macOS and confirms it by reading the SMC back.
    /// Each round writes mode 0 for any fan not automatic (never touching a fan macOS has
    /// parked in mode 3), clears that fan's forced
    /// target (as Stats does), then sets `Ftst` to 0. Returns true only after a read-back
    /// shows macOS in control. `skipWrites` exists for fault-injection tests.
    static func release(_ smc: SMCConnection, hasFtst: Bool, rounds: Int = 20, interval: UInt32 = 250_000,
                        skipWrites: () -> Bool = { false }) -> Bool {
        var clearTarget = Set<Int>()
        for round in 0..<rounds {
            if !skipWrites() {
                let fanCount = min(9, max(0, Int(smc.number("FNum") ?? 0)))
                for id in 0..<fanCount {
                    let key = modeKey(smc, id)
                    guard var mode = smc.read(key)?.bytes, !mode.isEmpty, !isAutomatic(mode[0]) else { continue }
                    clearTarget.insert(id)
                    mode[0] = 0
                    _ = writeRetrying(smc, key, mode, attempts: 3, delay: 20_000)
                }
                for id in clearTarget where smc.read(modeKey(smc, id))?.bytes.first.map(isAutomatic) == true {
                    if setTarget(smc, id, rpm: 0, attempts: 3) { clearTarget.remove(id) }
                }
                if var ftst = smc.read("Ftst")?.bytes, !ftst.isEmpty, ftst[0] != 0 {
                    ftst[0] = 0
                    _ = writeRetrying(smc, "Ftst", ftst, attempts: 3, delay: 20_000)
                }
            }
            if macOSInControl(smc, hasFtst: hasFtst) == true { return true }
            if round < rounds - 1 { usleep(interval) }
        }
        return false
    }

    static func needsReset(_ smc: SMCConnection) -> Bool {
        smc.read("Ftst")?.bytes.first == 1 || (0..<count(smc)).contains { smc.read(modeKey(smc, $0))?.bytes.first.map(isAutomatic) == false }
    }
}
