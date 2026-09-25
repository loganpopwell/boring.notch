import Foundation
let reader = SystemStatsReader()
assert(SystemStatsReader.cpuUsage(previous: [0,0,0,0], current: [20,10,60,10]) == 40)
assert(SystemStatsReader.cpuUsage(previous: [1,1,1,1], current: [1,1,1,1]) == nil)
assert(SystemStatsReader.cpuUsage(previous: [], current: [1,2,3,4]) == nil)
// Kernel tick counters wrap; a wrapped busy tick must remain a small delta.
let wrapped = SystemStatsReader.cpuUsage(previous: [UInt32.max - 4, 0, 10, 0], current: [5, 0, 20, 0])
assert(wrapped == 50)
let initial = reader.sample()
assert(initial.cpu == nil && initial.received == nil)
Thread.sleep(forTimeInterval: 1)
let sample = reader.sample()
assert(sample.cpu.map { (0...100).contains($0) } == true)
assert(sample.memoryUsed.map { $0 > 0 && $0 <= sample.memoryTotal } == true)
assert(sample.received.map { $0 >= 0 } == true)
assert(sample.diskUsed.map { $0 > 0 && $0 <= sample.diskTotal! } == true)
print("CPU", sample.cpu as Any, "Memory", sample.memoryUsed as Any, "GPU", sample.gpu as Any, "Network", sample.received as Any, "Battery", sample.battery as Any)
print("Sampling checks passed")

let processReader = ProcessStatsReader()
let firstProcesses = processReader.sample()
assert(!firstProcesses.rows.isEmpty)
assert(firstProcesses.rows.allSatisfy { $0.cpu == nil })
Thread.sleep(forTimeInterval: 1)
let processes = processReader.sample()
assert(processes.rows.contains { ($0.cpu ?? -1) >= 0 && $0.memory > 0 })
assert(Set(processes.rows.map(\.id)).count == processes.rows.count)
let roundTrip = try JSONDecoder().decode(NotchProcessSnapshot.self, from: JSONEncoder().encode(processes))
assert(roundTrip.rows.count == processes.rows.count)
assert(sample.sent.map { $0 >= 0 } == true)
if let health = sample.batteryHealth { assert((0...100).contains(health)) }
print("Process sampling and encoding checks passed. Battery health:", sample.batteryHealth as Any, "cycles:", sample.cycles as Any)

// libproc times are Mach ticks, which differ from nanoseconds on Apple silicon.
let busyReader = ProcessStatsReader()
_ = busyReader.sample()
let busyStart = ProcessInfo.processInfo.systemUptime
var busyValue = 1.0
while ProcessInfo.processInfo.systemUptime - busyStart < 0.5 { busyValue = sqrt(busyValue + 1.2) }
let busySnapshot = busyReader.sample()
let selfCPU = busySnapshot.rows.first { $0.id == "pid:\(ProcessInfo.processInfo.processIdentifier)" }?.cpu
assert(selfCPU.map { $0 > 40 && $0 < 150 } == true, "Busy single-thread CPU must be near one core, got \(String(describing: selfCPU))")
print("Mach tick conversion check passed:", selfCPU as Any, busyValue)
