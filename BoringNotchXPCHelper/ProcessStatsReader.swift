import Foundation
import Darwin

// Read-only process counters. No command lines, file contents or environment values are collected.
final class ProcessStatsReader {
    private var previous: [Int32: (UInt64, UInt64)] = [:]
    private var previousTime: Double?
    private let nanosecondsPerTick: Double = {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return Double(timebase.numer) / Double(timebase.denom)
    }()
    func sample() -> NotchProcessSnapshot {
        let capacity = max(2048, Int(proc_listallpids(nil, 0)) + 256)
        var pids = [Int32](repeating: 0, count: capacity)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard count > 0 else { return NotchProcessSnapshot(rows: [], unreadable: 0) }
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = previousTime.map { now - $0 }
        var next: [Int32: (UInt64, UInt64)] = [:]
        var groups: [String: NotchProcessRow] = [:]
        var unreadable = 0
        for pid in pids.prefix(min(Int(count), pids.count)) where pid > 0 {
            var info = proc_taskallinfo()
            let size = Int32(MemoryLayout<proc_taskallinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTASKALLINFO, 0, &info, size) == size else { unreadable += 1; continue }
            // Respect the user's session. System daemons are left to Activity Monitor.
            guard info.pbsd.pbi_uid == getuid() else { continue }
            let total = info.ptinfo.pti_total_user &+ info.ptinfo.pti_total_system
            let start = UInt64(info.pbsd.pbi_start_tvsec)
            var cpu: Double?
            if let old = previous[pid], old.0 == start, total >= old.1, let elapsed, elapsed > 0 {
                cpu = Double(total - old.1) * nanosecondsPerTick / 1_000_000_000 / elapsed * 100
            }
            next[pid] = (start, total)
            var buffer = [CChar](repeating: 0, count: 4096)
            let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
            let path = length > 0 ? String(cString: buffer) : ""
            var name = URL(fileURLWithPath: path).lastPathComponent
            var appPath: String?
            if let range = path.range(of: ".app/") {
                appPath = String(path[..<range.lowerBound]) + ".app"
                name = URL(fileURLWithPath: appPath!).deletingPathExtension().lastPathComponent
            }
            if name.isEmpty {
                var shortName = [CChar](repeating: 0, count: 256)
                _ = proc_name(pid, &shortName, UInt32(shortName.count))
                name = String(cString: shortName)
            }
            let key = appPath ?? "pid:\(pid)"
            var row = groups[key] ?? NotchProcessRow(id: key, name: name.isEmpty ? "Process \(pid)" : name, appPath: appPath, memory: 0, cpu: nil, count: 0)
            row.memory += info.ptinfo.pti_resident_size
            if let cpu { row.cpu = (row.cpu ?? 0) + cpu }
            row.count += 1
            groups[key] = row
        }
        previous = next
        previousTime = now
        return NotchProcessSnapshot(rows: Array(groups.values), unreadable: unreadable)
    }
}
