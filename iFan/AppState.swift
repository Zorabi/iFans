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
    /// Legacy single-curve storage, read once during migration.
    private let temperatureLevelsKey = "ifan.temperatureLevels.v1"

    /// Prevents rapid up/down switching when temperature hovers around a threshold.
    let temperatureHysteresis: Double = 3

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
        updateTemperatureControl()
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
        UserDefaults.standard.set(policy.id.uuidString, forKey: currentKey)
        pushCurrentToDaemon()
    }

    func updateTemperatureCurves(_ curves: [TemperatureFanCurve], selectedID: UUID) {
        guard !curves.isEmpty else { return }
        temperatureCurves = curves.map(normalizedCurve)
        selectedTemperatureCurveID = temperatureCurves.contains { $0.id == selectedID }
            ? selectedID
            : temperatureCurves[0].id
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

    /// Selects the hottest matching level. Rising temperature takes effect
    /// immediately; falling temperature must clear the current threshold by the
    /// hysteresis amount before a lower level is selected.
    private func updateTemperatureControl(force: Bool = false) {
        guard currentPolicy.isTemperatureControlled else { return }

        guard let temperature = temperatureControlTemperature else {
            let changed = activeTemperatureLevel != nil
            activeTemperatureLevel = nil
            if helperInstalled && (changed || force) {
                FanController.sendCommand(manual: false, left: 0, right: 0)
            }
            return
        }

        let matchingLevel = temperatureLevels.last { temperature >= $0.threshold }
        let nextLevel: TemperatureFanLevel?
        if !force,
           let current = activeTemperatureLevel,
           temperature >= current.threshold - temperatureHysteresis,
           (matchingLevel?.threshold ?? -.infinity) <= current.threshold {
            nextLevel = current
        } else {
            nextLevel = matchingLevel
        }

        let changed = nextLevel != activeTemperatureLevel
        activeTemperatureLevel = nextLevel
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
            if let idString = defaults.string(forKey: selectedTemperatureCurveKey),
               let id = UUID(uuidString: idString),
               temperatureCurves.contains(where: { $0.id == id }) {
                selectedTemperatureCurveID = id
            } else {
                selectedTemperatureCurveID = temperatureCurves[0].id
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
            saveTemperatureCurves()
            return
        }

        temperatureCurves = TemperatureFanCurve.defaults
        selectedTemperatureCurveID = TemperatureFanCurve.balancedID
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
}

private extension Double {
    func clamped() -> Double { Swift.min(100, Swift.max(0, self)) }
}
