import Foundation

/// A fan policy: a named preset that sets each fan to a target percentage.
struct FanPolicy: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    /// Left fan (index 0) target, 0...100 (% of the fan's min→max RPM range).
    var leftPercent: Double
    /// Right fan (index 1) target, 0...100.
    var rightPercent: Double
    /// System auto policy: hands control back to macOS (cannot be deleted).
    var isSystem: Bool = false

    static let system = FanPolicy(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        name: "自动 (系统)",
        leftPercent: 0,
        rightPercent: 0,
        isSystem: true
    )

    static let defaults: [FanPolicy] = [
        system,
        FanPolicy(name: "安静", leftPercent: 20, rightPercent: 20),
        FanPolicy(name: "均衡", leftPercent: 50, rightPercent: 50),
        FanPolicy(name: "全速", leftPercent: 100, rightPercent: 100),
    ]
}

/// One reading of all monitored sensors.
struct SensorSnapshot {
    // CPU
    var cpuTemp: Double?      // average CPU core die temperature (°C)
    var cpuMaxTemp: Double?   // hottest CPU core die temperature (°C)

    // GPU
    var gpuTemp: Double?      // average GPU die temperature (°C)
    var gpuMaxTemp: Double?   // hottest GPU die temperature (°C)

    // Chassis
    var chassisTemp: Double?  // keyboard / palm-rest area temperature (°C)

    // Fans
    var leftRPM: Double?      // fan 0 actual RPM
    var rightRPM: Double?     // fan 1 actual RPM
    var fan0Min: Double = 0
    var fan0Max: Double = 0
    var fan1Min: Double = 0
    var fan1Max: Double = 0

    // Battery
    var batteryDesignCapacity: Double?  // design mAh
    var batteryMaxCapacity: Double?     // current max mAh
    var batteryHealth: Double?          // percentage

    // Model info (set once, carried in each snapshot)
    var modelName: String = ""
    var modelYear: String = ""
    var fanCount: Int = 0
    var fanNames: [String] = []

    /// Average RPM across all present fans, for menu bar display.
    var avgRPM: Double? {
        let rpms = [leftRPM, rightRPM].compactMap { $0 }
        guard !rpms.isEmpty else { return nil }
        return rpms.reduce(0, +) / Double(rpms.count)
    }
}
