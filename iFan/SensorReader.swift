import Foundation
import IOKit

final class SensorReader {

    private let smc: SMC
    private let allCPUTempKeys: [String]
    private let allGPUTempKeys: [String]
    private let chassisKeys: [String]

    private let modelDisplayName: String
    private let modelYearStr: String
    private let fanCountVal: Int
    private let fanNamesList: [String]
    private let hasBattery: Bool
    private let cachedBattery: BatteryInfo?

    init?() {
        guard let smc = SMC() else { return nil }
        self.smc = smc

        let allKeys = smc.allKeyNames()

        // CPU
        var cpuKeys = allKeys.filter { $0.hasPrefix("TPD") || $0.hasPrefix("TRD") }
        if cpuKeys.isEmpty {
            for k in ["pACC","eACC","PC0C","PC0R","PC1C","PC2R","PC3R","PC4R","PC5R","PCAM","PCBC","PCBR"] {
                if let v = smc.readValue(k), v > 0, v < 130 { cpuKeys.append(k) }
            }
        }
        self.allCPUTempKeys = cpuKeys

        // GPU — known patterns
        let knownGPU = ["TG0D","TG0E","TG0p","TG0h","TG0P","TG0d",
                        "TG1D","TG1E","TG1p","TG1h","TG1P","TG1d",
                        "TG2D","TG0F","TG1F","TG0G","TG1G"]
        var gpuKeys: [String] = []
        for k in knownGPU {
            if let v = smc.readValue(k), v > 0, v < 130 { gpuKeys.append(k) }
        }
        if gpuKeys.isEmpty {
            for k in allKeys where k.hasPrefix("TG") {
                if let v = smc.readValue(k), v > 0, v < 130 { gpuKeys.append(k) }
            }
        }
        self.allGPUTempKeys = gpuKeys

        // Chassis
        let candidates = ["TC0P","TC1P","Ts0P","Ts1P","TB0T","TH0a","TH0b","TH0x"]
        var foundChassis: [String] = []
        for k in candidates {
            if let v = smc.readValue(k), v > 0, v < 130 { foundChassis.append(k) }
        }
        self.chassisKeys = foundChassis

        // Model
        let identifier = SensorReader.getModelIdentifier()
        (self.modelDisplayName, self.modelYearStr) = SensorReader.parseModel(identifier)

        // Fan
        var count = 0
        var names: [String] = []
        for i in 0..<4 {
            if smc.keyExists("F\(i)Ac") {
                count += 1
                if let name = smc.readString("F\(i)ID"), !name.isEmpty {
                    names.append(name)
                } else {
                    names.append(count == 1 ? "主风扇" : "风扇 \(count)")
                }
            }
        }
        self.fanCountVal = count
        self.fanNamesList = names

        // Battery
        let bat = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        self.hasBattery = bat != 0
        if bat != 0 { IOObjectRelease(bat) }
        self.cachedBattery = hasBattery ? SensorReader.readBattery() : nil

    }

    func read() -> SensorSnapshot {
        var snap = SensorSnapshot()

        // CPU
        var cpuTemps: [Double] = []
        for key in allCPUTempKeys {
            if let v = smc.readValue(key), v > 0, v < 130 { cpuTemps.append(v) }
        }
        if !cpuTemps.isEmpty {
            snap.cpuTemp = cpuTemps.reduce(0, +) / Double(cpuTemps.count)
            snap.cpuMaxTemp = cpuTemps.max()
        }

        // GPU
        var gpuTemps: [Double] = []
        for key in allGPUTempKeys {
            if let v = smc.readValue(key), v > 0, v < 130 { gpuTemps.append(v) }
        }
        if !gpuTemps.isEmpty {
            snap.gpuTemp = gpuTemps.reduce(0, +) / Double(gpuTemps.count)
            snap.gpuMaxTemp = gpuTemps.max()
        }

        // Chassis
        for key in chassisKeys {
            if let v = smc.readValue(key), v > 0, v < 130 {
                snap.chassisTemp = v
                break
            }
        }

        // Fans
        snap.leftRPM  = smc.readValue("F0Ac")
        snap.rightRPM = smc.readValue("F1Ac")
        snap.fan0Min  = smc.readValue("F0Mn") ?? 0
        snap.fan0Max  = smc.readValue("F0Mx") ?? 0
        snap.fan1Min  = smc.readValue("F1Mn") ?? 0
        snap.fan1Max  = smc.readValue("F1Mx") ?? 0

        // Battery (cached at init — no need to re-read every second)
        if let bat = cachedBattery {
            snap.batteryDesignCapacity = bat.design
            snap.batteryMaxCapacity   = bat.max
            snap.batteryHealth        = bat.health
        }

        // Model
        snap.modelName = modelDisplayName
        snap.modelYear = modelYearStr
        snap.fanCount  = fanCountVal
        snap.fanNames  = fanNamesList

        return snap
    }

    // MARK: - Model

    private static func getModelIdentifier() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "Unknown" }
        var model = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &model, &size, nil, 0)
        return String(cString: model)
    }

    static func parseModel(_ identifier: String) -> (name: String, year: String) {
        let map: [String: (String, String)] = [
            "Mac16,1":("MacBook Pro 14\"","2024"),"Mac16,5":("MacBook Pro 16\"","2024"),
            "Mac16,6":("MacBook Pro 14\"","2024"),"Mac16,7":("MacBook Pro 14\"","2024"),
            "Mac16,8":("MacBook Pro 16\"","2024"),
            "Mac16,2":("MacBook Air 13\"","2025"),"Mac16,3":("MacBook Air 15\"","2025"),
            "MacBookPro18,3":("MacBook Pro 14\"","2021"),"MacBookPro18,4":("MacBook Pro 14\"","2021"),
            "Mac14,5":("MacBook Pro 14\"","2023"),"Mac14,6":("MacBook Pro 16\"","2023"),
            "Mac14,9":("MacBook Pro 14\"","2023"),"Mac14,10":("MacBook Pro 16\"","2023"),
            "Mac15,3":("MacBook Pro 14\"","2023"),"Mac15,6":("MacBook Pro 14\"","2024"),
            "Mac15,7":("MacBook Pro 16\"","2024"),"Mac15,8":("MacBook Pro 14\"","2024"),
            "Mac15,9":("MacBook Pro 14\"","2024"),"Mac15,10":("MacBook Pro 14\"","2024"),
            "Mac15,11":("MacBook Pro 16\"","2024"),
            "Mac14,2":("MacBook Air 13\"","2022"),"Mac14,15":("MacBook Air 15\"","2023"),
            "Mac15,12":("MacBook Air 13\"","2024"),"Mac15,13":("MacBook Air 15\"","2024"),
            "Mac15,4":("iMac 24\"","2023"),"Mac15,5":("iMac 24\"","2023"),
            "Mac14,3":("Mac mini","2023"),"Mac14,12":("Mac mini","2023"),
            "Mac16,10":("Mac mini","2024"),"Mac16,11":("Mac mini","2024"),
            "Mac13,1":("Mac Studio","2022"),"Mac13,2":("Mac Studio","2022"),
            "Mac14,13":("Mac Studio","2023"),"Mac14,14":("Mac Studio","2023"),
            "Mac14,8":("Mac Pro","2023"),
        ]
        if let m = map[identifier] { return m }
        let p = String(identifier.split(separator: ",").first ?? Substring(identifier))
        if let n = Int(p.filter({$0.isNumber})), n >= 14 { return (identifier, "\(2020+n-14)") }
        return (identifier, "")
    }

    // MARK: - Battery

    private struct BatteryInfo { let design: Double; let max: Double; let health: Double }

    private static func readBattery() -> BatteryInfo? {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard svc != 0 else { return nil }
        defer { IOObjectRelease(svc) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any] else { return nil }
        let bd = dict["BatteryData"] as? [String: Any]
        let design = (bd?["DesignCapacity"] as? Int) ?? (dict["DesignCapacity"] as? Int)
        var maxCap = (bd?["FullChargeCapacity"] as? Int) ?? (dict["AppleRawMaxCapacity"] as? Int)
        if maxCap == nil, let d = design, let pct = (bd?["MaxCapacity"] as? Int) ?? (dict["MaxCapacity"] as? Int), pct > 0 {
            maxCap = d * pct / 100
        }
        guard let d = design.map(Double.init), d > 0, let m = maxCap.map(Double.init), m > 0 else { return nil }
        return BatteryInfo(design: d, max: m, health: (m / d) * 100.0)
    }
}
