import Foundation
import Darwin
import IOKit
import IOKit.ps

// All counters are local. A sampler belongs to the visible tab, not the app lifetime.
struct SystemStatsSample {
    var cpu: Double?
    var memoryUsed: Double?
    var memoryTotal = Double(ProcessInfo.processInfo.physicalMemory)
    var compressed: Double = 0
    var gpu: Double?
    var received: Double?
    var sent: Double?
    var diskUsed: Double?
    var diskTotal: Double?
    var battery: Double?
    var batteryHealth: Double?
    var cycles: Int?
    var charging = false
    var thermal = ProcessInfo.processInfo.thermalState
}

final class SystemStatsReader: @unchecked Sendable {
    private var previousCPU: [UInt32]?
    private var previousNetwork: (Double, [String: (UInt64, UInt64)])?

    static func cpuUsage(previous: [UInt32], current: [UInt32]) -> Double? {
        guard previous.count == 4, current.count == 4 else { return nil }
        let delta = zip(current, previous).map { Double($0 &- $1) }
        let total = delta.reduce(0, +)
        guard total > 0 else { return nil }
        return min(100, max(0, (total - delta[Int(CPU_STATE_IDLE)]) / total * 100))
    }

    func sample() -> SystemStatsSample {
        var result = SystemStatsSample()
        var cpu = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let cpuStatus = withUnsafeMutablePointer(to: &cpu) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        if cpuStatus == KERN_SUCCESS {
            let ticks = [cpu.cpu_ticks.0, cpu.cpu_ticks.1, cpu.cpu_ticks.2, cpu.cpu_ticks.3]
            if let previousCPU { result.cpu = Self.cpuUsage(previous: previousCPU, current: ticks) }
            previousCPU = ticks
        }
        var vm = vm_statistics64()
        count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let vmStatus = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        if vmStatus == KERN_SUCCESS {
            let page = Double(getpagesize())
            // Exclude file-backed cache and purgeable pages; include compressed physical storage.
            result.memoryUsed = min(result.memoryTotal, max(0,
                (Double(vm.active_count) + Double(vm.inactive_count) + Double(vm.speculative_count)
                    + Double(vm.wire_count) + Double(vm.compressor_page_count)
                    - Double(vm.purgeable_count) - Double(vm.external_page_count)) * page))
            result.compressed = Double(vm.compressor_page_count) * page
        }
        var addresses: UnsafeMutablePointer<ifaddrs>?
        var counters: [String: (UInt64, UInt64)] = [:]
        if getifaddrs(&addresses) == 0 {
            var cursor = addresses
            while let entry = cursor {
                let info = entry.pointee
                let name = String(cString: info.ifa_name)
                if info.ifa_addr?.pointee.sa_family == UInt8(AF_LINK), name.hasPrefix("en"),
                   (info.ifa_flags & UInt32(IFF_UP)) != 0, let data = info.ifa_data {
                    let link = data.assumingMemoryBound(to: if_data.self).pointee
                    counters[name] = (UInt64(link.ifi_ibytes), UInt64(link.ifi_obytes))
                }
                cursor = info.ifa_next
            }
            freeifaddrs(addresses)
            let now = ProcessInfo.processInfo.systemUptime
            if let (then, old) = previousNetwork, now > then {
                var down: Double = 0, up: Double = 0
                for (name, pair) in counters {
                    if let prior = old[name], pair.0 >= prior.0, pair.1 >= prior.1 {
                        down += Double(pair.0 - prior.0)
                        up += Double(pair.1 - prior.1)
                    }
                }
                result.received = down / (now - then)
                result.sent = up / (now - then)
            }
            previousNetwork = (now, counters)
        }
        if let disk = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey]),
           let total = disk.volumeTotalCapacity, let free = disk.volumeAvailableCapacity {
            result.diskTotal = Double(total)
            result.diskUsed = Double(max(0, total - free))
        }
        var iterator: io_iterator_t = 0
        if IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS {
            defer { IOObjectRelease(iterator) }
            var device = IOIteratorNext(iterator)
            while device != 0 {
                var properties: Unmanaged<CFMutableDictionary>?
                if IORegistryEntryCreateCFProperties(device, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                   let dict = properties?.takeRetainedValue() as? [String: Any],
                   let stats = dict["PerformanceStatistics"] as? [String: Any],
                   let utilization = stats["Device Utilization %"] as? NSNumber {
                    result.gpu = max(result.gpu ?? 0, min(100, max(0, utilization.doubleValue)))
                }
                IOObjectRelease(device)
                device = IOIteratorNext(iterator)
            }
        }
        if let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] {
            for source in sources {
                guard let data = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any],
                      data[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                      let current = data[kIOPSCurrentCapacityKey] as? Double,
                      let maximum = data[kIOPSMaxCapacityKey] as? Double, maximum > 0 else { continue }
                result.battery = min(100, max(0, current / maximum * 100))
                result.charging = data[kIOPSIsChargingKey] as? Bool ?? false
            }
        }
        let batteryService = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        if batteryService != 0 {
            defer { IOObjectRelease(batteryService) }
            func number(_ key: String) -> Double? {
                (IORegistryEntryCreateCFProperty(batteryService, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?.doubleValue
            }
            let batteryData = IORegistryEntryCreateCFProperty(batteryService, "BatteryData" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any]
            let maximum = number("AppleRawMaxCapacity") ?? (batteryData?["FullChargeCapacity"] as? NSNumber)?.doubleValue
            let design = number("DesignCapacity") ?? (batteryData?["DesignCapacity"] as? NSNumber)?.doubleValue
            if let maximum, let design, design > 0 {
                result.batteryHealth = min(100, max(0, maximum / design * 100))
            }
            result.cycles = number("CycleCount").map(Int.init)
        }
        return result
    }
}
