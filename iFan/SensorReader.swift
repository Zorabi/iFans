import Foundation
import IOKit

final class SensorReader {

    private let smc: SMC
    private let allCPUTempKeys: [String]
    private let allGPUTempKeys: [String]
    private let chassisKeys: [String]
    private let summaryTemperatureKeys: [String]
    private let backgroundTemperatureKeys: [String]
    private var backgroundTemperatureOffset = 0

    private let backgroundTemperatureBatchSize: Int
    private let keyInfoCacheName: String
    private var persistedKeyInfoEntries: [String: String]

    private let modelDisplayName: String
    private let modelYearStr: String
    private let fanCountVal: Int
    private let fanNamesList: [String]
    private let hasBattery: Bool
    private let cachedBattery: BatteryInfo?

    init?() {
        guard let smc = SMC() else { return nil }
        self.smc = smc

        let identifier = SensorReader.getModelIdentifier()
        let smcKeyCacheName = "ifan.smc.keys.v1.\(identifier)"
        let temperatureKeyCacheName = "ifan.smc.temperatureKeys.v1.\(identifier)"
        let keyInfoCacheName = "ifan.smc.keyInfo.v1.\(identifier)"
        let persistedKeyInfoEntries = (
            UserDefaults.standard.dictionary(forKey: keyInfoCacheName) ?? [:]
        ).compactMapValues { $0 as? String }
        smc.restoreKeyInfoCache(persistedKeyInfoEntries)
        self.keyInfoCacheName = keyInfoCacheName
        self.persistedKeyInfoEntries = persistedKeyInfoEntries

        let cachedKeys = UserDefaults.standard.stringArray(forKey: smcKeyCacheName) ?? []
        let allKeys: [String]
        if cachedKeys.isEmpty {
            allKeys = smc.allKeyNames()
            UserDefaults.standard.set(allKeys, forKey: smcKeyCacheName)
        } else {
            allKeys = cachedKeys
        }

        // Temperature SMC keys conventionally begin with T and use either
        // Apple's fixed-point temperature type or a floating-point value.
        // Keep the full typed list so the UI can expose every valid sensor.
        let cachedTemperatureKeys = UserDefaults.standard.stringArray(forKey: temperatureKeyCacheName) ?? []
        let temperatureKeys: [String]
        if cachedTemperatureKeys.isEmpty {
            temperatureKeys = allKeys.filter { key in
                guard key.hasPrefix("T") else { return false }
                let type = smc.keyInfo(key).type
                return type == "sp78" || type == "flt"
            }.sorted()
            UserDefaults.standard.set(temperatureKeys, forKey: temperatureKeyCacheName)
        } else {
            temperatureKeys = cachedTemperatureKeys
        }
        // CPU — Apple Silicon exposes per-core / hotspot sensors through
        // generation-specific prefixes. Tp* and TC* are the important M1/M2
        // families; Te*/Tf* cover newer generations. Prefer these granular
        // readings over the lower aggregate TPD*/TRD* values.
        let granularPrefixes = ["Tp", "TC", "Te", "Tf"]
        var cpuKeys = temperatureKeys.filter { key in
            granularPrefixes.contains { key.hasPrefix($0) }
        }

        // Some models only expose aggregate CPU die sensors.
        if cpuKeys.isEmpty {
            cpuKeys = temperatureKeys.filter { $0.hasPrefix("TPD") || $0.hasPrefix("TRD") }
        }
        self.allCPUTempKeys = Array(Set(cpuKeys)).sorted()

        // GPU — known patterns
        let knownGPU = ["TG0D","TG0E","TG0p","TG0h","TG0P","TG0d",
                        "TG1D","TG1E","TG1p","TG1h","TG1P","TG1d",
                        "TG2D","TG0F","TG1F","TG0G","TG1G"]
        let temperatureKeySet = Set(temperatureKeys)
        var gpuKeys = knownGPU.filter { temperatureKeySet.contains($0) }
        if gpuKeys.isEmpty {
            gpuKeys = temperatureKeys.filter { $0.hasPrefix("TG") }
        }
        self.allGPUTempKeys = gpuKeys

        // Chassis
        let candidates = ["TC0P","TC1P","Ts0P","Ts1P","TB0T","TH0a","TH0b","TH0x"]
        let foundChassis = candidates.filter { temperatureKeySet.contains($0) }
        self.chassisKeys = foundChassis
        let summaryTemperatureKeys = Array(Set(cpuKeys + gpuKeys + foundChassis)).sorted()
        self.summaryTemperatureKeys = summaryTemperatureKeys
        let summaryTemperatureKeySet = Set(summaryTemperatureKeys)
        self.backgroundTemperatureKeys = temperatureKeys.filter {
            !summaryTemperatureKeySet.contains($0)
        }
        let hasCompleteKeyInfoCache = temperatureKeys.allSatisfy {
            persistedKeyInfoEntries[$0] != nil
        }
        self.backgroundTemperatureBatchSize = hasCompleteKeyInfoCache ? 8 : 4

        // Model
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

        // A fresh model discovery already queried each temperature key's
        // metadata. Save those results now; existing installs fill the same
        // cache incrementally during the first rolling sensor pass.
        persistKeyInfoMetadata(for: temperatureKeys)
    }

    func read(cachedTemperatureSensors: [TemperatureSensorReading] = []) -> SensorSnapshot {
        var snap = SensorSnapshot()

        let keysToRead = Array(Set(summaryTemperatureKeys + nextBackgroundTemperatureBatch())).sorted()
        let liveTemperatureReadings = keysToRead.compactMap { key -> TemperatureSensorReading? in
            guard let value = smc.readValue(key), SensorReader.isValidTemperature(value) else {
                return nil
            }
            return TemperatureSensorReading(
                key: key,
                value: value,
                category: SensorReader.temperatureCategory(for: key)
            )
        }
        persistKeyInfoMetadata(for: keysToRead)
        let liveTemperaturesByKey = Dictionary(
            uniqueKeysWithValues: liveTemperatureReadings.map { ($0.key, $0) }
        )

        var displayTemperaturesByKey = Dictionary(
            uniqueKeysWithValues: cachedTemperatureSensors.map { ($0.key, $0) }
        )
        for key in keysToRead {
            displayTemperaturesByKey[key] = liveTemperaturesByKey[key]
        }
        snap.temperatureSensors = displayTemperaturesByKey.values.sorted {
            $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
        }

        // CPU
        let cpuReadings = allCPUTempKeys.compactMap { liveTemperaturesByKey[$0] }
        if !cpuReadings.isEmpty {
            snap.cpuTemp = cpuReadings.reduce(0) { $0 + $1.value } / Double(cpuReadings.count)
            if let hotspot = cpuReadings.max(by: { $0.value < $1.value }) {
                snap.cpuMaxTemp = hotspot.value
                snap.cpuHotspotKey = hotspot.key
            }
            snap.cpuSensorCount = cpuReadings.count
        }

        // GPU
        let gpuTemps = allGPUTempKeys.compactMap { liveTemperaturesByKey[$0]?.value }
        if !gpuTemps.isEmpty {
            snap.gpuTemp = gpuTemps.reduce(0, +) / Double(gpuTemps.count)
            snap.gpuMaxTemp = gpuTemps.max()
        }

        // Chassis
        for key in chassisKeys {
            if let reading = liveTemperaturesByKey[key] {
                snap.chassisTemp = reading.value
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

    private func nextBackgroundTemperatureBatch() -> [String] {
        guard !backgroundTemperatureKeys.isEmpty else { return [] }

        let batchCount = min(backgroundTemperatureBatchSize, backgroundTemperatureKeys.count)
        let batch = (0..<batchCount).map { index in
            backgroundTemperatureKeys[(backgroundTemperatureOffset + index) % backgroundTemperatureKeys.count]
        }
        backgroundTemperatureOffset = (backgroundTemperatureOffset + batchCount) % backgroundTemperatureKeys.count
        return batch
    }

    private func persistKeyInfoMetadata(for keys: [String]) {
        let discoveredEntries = smc.cachedKeyInfoEntries(for: keys)
        var changed = false
        for (key, encoded) in discoveredEntries where persistedKeyInfoEntries[key] != encoded {
            persistedKeyInfoEntries[key] = encoded
            changed = true
        }
        if changed {
            UserDefaults.standard.set(persistedKeyInfoEntries, forKey: keyInfoCacheName)
        }
    }

    // MARK: - Model

    private static func isValidTemperature(_ value: Double) -> Bool {
        value > 0 && value < 130
    }

    private static func temperatureCategory(for key: String) -> String {
        if key.hasPrefix("Tp") || key.hasPrefix("TC") || key.hasPrefix("Te") ||
            key.hasPrefix("Tf") || key.hasPrefix("TPD") || key.hasPrefix("TRD") {
            return "CPU"
        }
        if key.hasPrefix("Tg") || key.hasPrefix("TG") { return "GPU" }
        if key.hasPrefix("TB") { return "电池" }
        if key.hasPrefix("Tm") || key.hasPrefix("TM") { return "内存" }
        if key.hasPrefix("Ts") || key.hasPrefix("TH") || key.hasPrefix("TN") ||
            key.hasPrefix("TW") || key.hasPrefix("TA") || key.hasPrefix("TL") {
            return "机身"
        }
        return "SoC / 其他"
    }

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
