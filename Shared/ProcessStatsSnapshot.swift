import Foundation

struct NotchProcessRow: Codable, Identifiable {
    var id: String
    var name: String
    var appPath: String?
    var memory: UInt64
    var cpu: Double?
    var count: Int
}
struct NotchProcessSnapshot: Codable {
    var rows: [NotchProcessRow]
    var unreadable: Int
}
