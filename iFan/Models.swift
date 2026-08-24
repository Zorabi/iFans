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
    /// Kept optional so policies saved by older iFan versions still decode.
    var temperatureControlled: Bool? = nil

    var isTemperatureControlled: Bool { temperatureControlled == true }
    var isBuiltIn: Bool { isSystem || isTemperatureControlled }

    static let system = FanPolicy(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        name: "自动 (系统)",
        leftPercent: 0,
        rightPercent: 0,
        isSystem: true
    )

    static let temperature = FanPolicy(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
        name: "智能温控",
        leftPercent: 0,
        rightPercent: 0,
        temperatureControlled: true
    )

    static let defaults: [FanPolicy] = [
        system,
        temperature,
        FanPolicy(name: "安静", leftPercent: 20, rightPercent: 20),
        FanPolicy(name: "均衡", leftPercent: 50, rightPercent: 50),
        FanPolicy(name: "全速", leftPercent: 100, rightPercent: 100),
    ]
}

/// One step in the CPU-hotspot driven fan curve.
struct TemperatureFanLevel: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var threshold: Double
    var percent: Double

    static let defaults: [TemperatureFanLevel] = [
        TemperatureFanLevel(threshold: 55, percent: 30),
        TemperatureFanLevel(threshold: 65, percent: 45),
        TemperatureFanLevel(threshold: 75, percent: 65),
        TemperatureFanLevel(threshold: 85, percent: 85),
        TemperatureFanLevel(threshold: 90, percent: 100),
    ]
}

/// A named, user-editable temperature-to-fan-speed curve.
struct TemperatureFanCurve: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    var levels: [TemperatureFanLevel]

    static let balancedID = UUID(uuidString: "00000000-0000-0000-0000-000000000102")!

    static let defaults: [TemperatureFanCurve] = [
        TemperatureFanCurve(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!,
            name: "安静温控",
            levels: [
                TemperatureFanLevel(threshold: 60, percent: 25),
                TemperatureFanLevel(threshold: 70, percent: 40),
                TemperatureFanLevel(threshold: 80, percent: 60),
                TemperatureFanLevel(threshold: 90, percent: 85),
                TemperatureFanLevel(threshold: 95, percent: 100),
            ]
        ),
        TemperatureFanCurve(
            id: balancedID,
            name: "均衡温控",
            levels: TemperatureFanLevel.defaults
        ),
        TemperatureFanCurve(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000103")!,
            name: "强力散热",
            levels: [
                TemperatureFanLevel(threshold: 50, percent: 35),
                TemperatureFanLevel(threshold: 60, percent: 55),
                TemperatureFanLevel(threshold: 70, percent: 75),
                TemperatureFanLevel(threshold: 80, percent: 100),
            ]
        ),
    ]
}

/// A live reading from one temperature-related SMC key.
struct TemperatureSensorReading: Identifiable, Equatable {
    var id: String { key }
    let key: String
    let value: Double
    let category: String
}

/// One reading of all monitored sensors.
struct SensorSnapshot {
    // CPU
    var cpuTemp: Double?      // average CPU core die temperature (°C)
    var cpuMaxTemp: Double?   // hottest CPU core die temperature (°C)
    var cpuHotspotKey: String? // SMC key currently reporting the hotspot
    var cpuSensorCount: Int = 0

    // GPU
    var gpuTemp: Double?      // average GPU die temperature (°C)
    var gpuMaxTemp: Double?   // hottest GPU die temperature (°C)

    // Chassis
    var chassisTemp: Double?  // keyboard / palm-rest area temperature (°C)

    // All valid temperature-related SMC readings, hottest first.
    var temperatureSensors: [TemperatureSensorReading] = []

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
