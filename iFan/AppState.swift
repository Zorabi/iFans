import Foundation
import Combine

/// Central app state: live sensor readings, fan policies, and persistence.
@MainActor
final class AppState: ObservableObject {

    @Published var snapshot = SensorSnapshot()
    @Published var policies: [FanPolicy] = []
    @Published var currentPolicyID: UUID = FanPolicy.system.id
    @Published var temperatureCurves: [TemperatureFanCurve] = TemperatureFanCurve.defaults
    @Published var selectedTemperatureCurveID: UUID = TemperatureFanCurve.balancedID
    @Published private(set) var activeTemperatureLevel: TemperatureFanLevel?
    @Published private(set) var smoothedTemperatureControlTemperature: Double?
    @Published var helperInstalled = false
    @Published var isInstalling = false
    @Published var lastError: String?

    private let reader = SensorReader()
    private var timer: Timer?

    private let monitoringInterval: TimeInterval = 2

    private let policiesKey = "ifan.policies.v1"
    private let currentKey = "ifan.currentPolicy.v1"
    private let temperatureCurvesKey = "ifan.temperatureCurves.v2"
    private let selectedTemperatureCurveKey = "ifan.selectedTemperatureCurve.v2"
    private let temperatureCurveDefaultsVersionKey = "ifan.temperatureCurveDefaultsVersion"
    private let temperatureCurveDefaultsVersion = 2
    /// Legacy single-curve storage, read once during migration.
    private let temperatureLevelsKey = "ifan.temperatureLevels.v1"

    let temperatureAveragingWindow: TimeInterval = 10
    let temperatureRiseDelay: TimeInterval = 4
    let temperatureFallDelay: TimeInterval = 20
    /// A lower level is considered only after clearing the current threshold.
    let temperatureHysteresis: Double = 4

    private var temperatureSamples: [(date: Date, value: Double)] = []
    private var pendingTemperatureLevel: TemperatureFanLevel?
    private var pendingTemperatureChangeStartedAt: Date?

    var currentPolicy: FanPolicy {
        policies.first { $0.id == currentPolicyID } ?? FanPolicy.system
    }

    var temperatureControlTemperature: Double? {
        snapshot.cpuMaxTemp ?? snapshot.cpuTemp
    }

    var selectedTemperatureCurve: TemperatureFanCurve? {
        temperatureCurves.first { $0.id == selectedTemperatureCurveID }
            ?? temperatureCurves.first
    }

    var temperatureLevels: [TemperatureFanLevel] {
        selectedTemperatureCurve?.levels ?? []
    }

    init() {
        loadPolicies()
        loadTemperatureCurves()
        helperInstalled = FanController.isInstalled
        refresh()
        startMonitoring()
    }

    // MARK: - Live monitoring

    func startMonitoring() {
        helperInstalled = FanController.isInstalled
        // Re-assert the last selected policy to the daemon on launch.
        pushCurrentToDaemon()
        timer?.invalidate()
        let t = Timer(timeInterval: monitoringInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func refresh() {
        if let snap = reader?.read(cachedTemperatureSensors: snapshot.temperatureSensors) {
            snapshot = snap
        }
        let now = Date()
        updateSmoothedTemperature(now: now)
        updateTemperatureControl(now: now)
        // Keep the daemon's watchdog fed while a manual policy is active.
        if helperInstalled && !currentPolicy.isSystem {
            FanController.touchHeartbeat()
        }
    }

    // MARK: - Policy management

    func addPolicy(name: String, left: Double, right: Double) {
        let p = FanPolicy(name: name.isEmpty ? "新策略" : name,
                          leftPercent: left.clamped(),
                          rightPercent: right.clamped())
        policies.append(p)
        savePolicies()
    }

    func deletePolicy(_ policy: FanPolicy) {
        guard !policy.isBuiltIn else { return }
        policies.removeAll { $0.id == policy.id }
        if currentPolicyID == policy.id {
            currentPolicyID = FanPolicy.system.id
            UserDefaults.standard.set(FanPolicy.system.id.uuidString, forKey: currentKey)
            pushCurrentToDaemon()
        }
        savePolicies()
    }

    func applyPolicy(_ policy: FanPolicy) {
        currentPolicyID = policy.id
        if !policy.isTemperatureControlled {
            activeTemperatureLevel = nil
        }
        clearPendingTemperatureChange()
        UserDefaults.standard.set(policy.id.uuidString, forKey: currentKey)
        pushCurrentToDaemon()
    }

    func updateTemperatureCurves(_ curves: [TemperatureFanCurve], selectedID: UUID) {
        guard !curves.isEmpty else { return }
        temperatureCurves = curves.map(normalizedCurve)
        selectedTemperatureCurveID = temperatureCurves.contains { $0.id == selectedID }
            ? selectedID
            : temperatureCurves[0].id
        activeTemperatureLevel = nil
        clearPendingTemperatureChange()
        saveTemperatureCurves()
        updateTemperatureControl(force: true)
    }

    func movePolicies(from source: IndexSet, to destination: Int) {
        // Built-in policies stay locked at the start of the list.
        var dest = destination
        if dest < 2 { dest = 2 }
        guard source.allSatisfy({ !policies[$0].isBuiltIn }) else { return }
        policies.move(fromOffsets: source, toOffset: dest)
        savePolicies()
    }

    /// Sends the current policy's intent to the root daemon via the command file.
    private func pushCurrentToDaemon() {
        guard helperInstalled else { return }
        let p = currentPolicy
        if p.isSystem {
            FanController.sendCommand(manual: false, left: 0, right: 0)
        } else if p.isTemperatureControlled {
            updateTemperatureControl(force: true)
        } else {
            let l = rpm(min: snapshot.fan0Min, max: snapshot.fan0Max, percent: p.leftPercent)
            let r = rpm(min: snapshot.fan1Min, max: snapshot.fan1Max, percent: p.rightPercent)
            FanController.sendCommand(manual: true, left: l, right: r)
        }
    }

    /// Uses a moving average for normal transitions. A rise must persist briefly;
    /// a fall must clear hysteresis and persist longer. The highest configured
    /// threshold always takes effect immediately.
    private func updateTemperatureControl(force: Bool = false, now: Date = Date()) {
        guard currentPolicy.isTemperatureControlled else { return }

        guard let temperature = smoothedTemperatureControlTemperature
                ?? temperatureControlTemperature else {
            let changed = activeTemperatureLevel != nil
            activeTemperatureLevel = nil
            clearPendingTemperatureChange()
            if helperInstalled && (changed || force) {
                FanController.sendCommand(manual: false, left: 0, right: 0)
            }
            return
        }

        let matchingLevel = temperatureLevels.last { temperature >= $0.threshold }
        var desiredLevel = matchingLevel

        if !force,
           let highestLevel = temperatureLevels.last,
           let rawTemperature = temperatureControlTemperature,
           rawTemperature >= highestLevel.threshold {
            commitTemperatureLevel(highestLevel)
            return
        }

        if let current = activeTemperatureLevel,
           levelRank(matchingLevel) < levelRank(current),
           temperature >= current.threshold - temperatureHysteresis {
            desiredLevel = current
        }

        if force {
            commitTemperatureLevel(desiredLevel, force: true)
            return
        }

        guard desiredLevel != activeTemperatureLevel else {
            clearPendingTemperatureChange()
            return
        }

        let isHighestLevel = desiredLevel?.id == temperatureLevels.last?.id
        if isHighestLevel {
            commitTemperatureLevel(desiredLevel)
            return
        }

        if pendingTemperatureChangeStartedAt == nil
            || pendingTemperatureLevel != desiredLevel {
            pendingTemperatureLevel = desiredLevel
            pendingTemperatureChangeStartedAt = now
            return
        }

        let isRising = levelRank(desiredLevel) > levelRank(activeTemperatureLevel)
        let delay = isRising ? temperatureRiseDelay : temperatureFallDelay
        guard let startedAt = pendingTemperatureChangeStartedAt,
              now.timeIntervalSince(startedAt) >= delay else { return }

        commitTemperatureLevel(desiredLevel)
    }

    private func updateSmoothedTemperature(now: Date) {
        guard let temperature = temperatureControlTemperature else {
            temperatureSamples.removeAll()
            smoothedTemperatureControlTemperature = nil
            return
        }

        temperatureSamples.append((now, temperature))
        let cutoff = now.addingTimeInterval(-temperatureAveragingWindow)
        temperatureSamples.removeAll { $0.date < cutoff }
        smoothedTemperatureControlTemperature = temperatureSamples
            .map(\.value)
            .reduce(0, +) / Double(temperatureSamples.count)
    }

    private func levelRank(_ level: TemperatureFanLevel?) -> Int {
        guard let level else { return -1 }
        return temperatureLevels.firstIndex { $0.id == level.id }
            ?? temperatureLevels.lastIndex { $0.threshold <= level.threshold }
            ?? -1
    }

    private func clearPendingTemperatureChange() {
        pendingTemperatureLevel = nil
        pendingTemperatureChangeStartedAt = nil
    }

    private func commitTemperatureLevel(_ nextLevel: TemperatureFanLevel?, force: Bool = false) {
        let changed = nextLevel != activeTemperatureLevel
        activeTemperatureLevel = nextLevel
        clearPendingTemperatureChange()
        guard helperInstalled && (changed || force) else { return }

        if let level = nextLevel {
            let left = rpm(
                min: snapshot.fan0Min,
                max: snapshot.fan0Max,
                percent: level.percent
            )
            let right = rpm(
                min: snapshot.fan1Min,
                max: snapshot.fan1Max,
                percent: level.percent
            )
            FanController.sendCommand(manual: true, left: left, right: right)
        } else {
            FanController.sendCommand(manual: false, left: 0, right: 0)
        }
    }

    private func rpm(min: Double, max: Double, percent: Double) -> Double {
        guard max > min else { return min }
        return min + (max - min) * percent / 100
    }

    // MARK: - Helper (root daemon) install / uninstall

    func installHelper() {
        guard !isInstalling else { return }
        isInstalling = true
        lastError = nil
        FanController.install { [weak self] ok, err in
            Task { @MainActor in
                guard let self else { return }
                self.isInstalling = false
                self.helperInstalled = FanController.isInstalled
                if ok {
                    self.pushCurrentToDaemon()
                } else {
                    self.lastError = err
                }
            }
        }
    }

    func uninstallHelper() {
        guard !isInstalling else { return }
        isInstalling = true
        lastError = nil
        FanController.uninstall { [weak self] ok, err in
            Task { @MainActor in
                guard let self else { return }
                self.isInstalling = false
                self.helperInstalled = FanController.isInstalled
                if !ok { self.lastError = err }
            }
        }
    }

    func helperLog() -> String { FanController.readLog() }

    // MARK: - Persistence

    private func loadPolicies() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: policiesKey),
           let decoded = try? JSONDecoder().decode([FanPolicy].self, from: data),
           !decoded.isEmpty {
            let customPolicies = decoded.filter { !$0.isBuiltIn }
            policies = [.system, .temperature] + customPolicies
        } else {
            policies = FanPolicy.defaults
        }
        if let idStr = defaults.string(forKey: currentKey),
           let id = UUID(uuidString: idStr),
           policies.contains(where: { $0.id == id }) {
            currentPolicyID = id
        }
    }

    private func savePolicies() {
        if let data = try? JSONEncoder().encode(policies) {
            UserDefaults.standard.set(data, forKey: policiesKey)
        }
    }

    private func loadTemperatureCurves() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: temperatureCurvesKey),
           let decoded = try? JSONDecoder().decode([TemperatureFanCurve].self, from: data),
           !decoded.isEmpty {
            temperatureCurves = decoded.map(normalizedCurve)
            let needsDefaultMigration = defaults.integer(
                forKey: temperatureCurveDefaultsVersionKey
            ) < temperatureCurveDefaultsVersion
            if needsDefaultMigration {
                temperatureCurves = temperatureCurves.map(migratingLegacyDefaultCurve)
                defaults.set(
                    temperatureCurveDefaultsVersion,
                    forKey: temperatureCurveDefaultsVersionKey
                )
            }
            if let idString = defaults.string(forKey: selectedTemperatureCurveKey),
               let id = UUID(uuidString: idString),
               temperatureCurves.contains(where: { $0.id == id }) {
                selectedTemperatureCurveID = id
            } else {
                selectedTemperatureCurveID = temperatureCurves[0].id
            }
            if needsDefaultMigration {
                saveTemperatureCurves()
            }
            return
        }

        // Migrate the single editable curve created by the previous version.
        if let data = defaults.data(forKey: temperatureLevelsKey),
           let legacyLevels = try? JSONDecoder().decode([TemperatureFanLevel].self, from: data),
           !legacyLevels.isEmpty {
            let migrated = normalizedCurve(
                TemperatureFanCurve(name: "我的温控", levels: legacyLevels)
            )
            temperatureCurves = [migrated]
            selectedTemperatureCurveID = migrated.id
            defaults.set(
                temperatureCurveDefaultsVersion,
                forKey: temperatureCurveDefaultsVersionKey
            )
            saveTemperatureCurves()
            return
        }

        temperatureCurves = TemperatureFanCurve.defaults
        selectedTemperatureCurveID = TemperatureFanCurve.balancedID
        defaults.set(
            temperatureCurveDefaultsVersion,
            forKey: temperatureCurveDefaultsVersionKey
        )
    }

    private func saveTemperatureCurves() {
        if let data = try? JSONEncoder().encode(temperatureCurves) {
            UserDefaults.standard.set(data, forKey: temperatureCurvesKey)
        }
        UserDefaults.standard.set(
            selectedTemperatureCurveID.uuidString,
            forKey: selectedTemperatureCurveKey
        )
    }

    private func normalizedCurve(_ curve: TemperatureFanCurve) -> TemperatureFanCurve {
        var normalized = curve
        normalized.name = curve.name.trimmingCharacters(in: .whitespacesAndNewlines)
        normalized.levels = curve.levels
            .map {
                TemperatureFanLevel(
                    id: $0.id,
                    threshold: min(100, max(40, $0.threshold)),
                    percent: min(100, max(0, $0.percent))
                )
            }
            .sorted { $0.threshold < $1.threshold }
        return normalized
    }

    private func migratingLegacyDefaultCurve(
        _ curve: TemperatureFanCurve
    ) -> TemperatureFanCurve {
        guard let legacyLevels = TemperatureFanCurve.legacyDefaultLevels(for: curve.id),
              levelsMatch(curve.levels, legacyLevels),
              let newLevels = TemperatureFanCurve.defaultLevels(for: curve.id) else {
            return curve
        }

        var migrated = curve
        migrated.levels = newLevels
        return normalizedCurve(migrated)
    }

    private func levelsMatch(
        _ lhs: [TemperatureFanLevel],
        _ rhs: [TemperatureFanLevel]
    ) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { pair in
            pair.0.threshold == pair.1.threshold && pair.0.percent == pair.1.percent
        }
    }
}

private extension Double {
    func clamped() -> Double { Swift.min(100, Swift.max(0, self)) }
}
