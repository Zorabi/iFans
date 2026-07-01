import Foundation
import Combine

/// Central app state: live sensor readings, fan policies, and persistence.
@MainActor
final class AppState: ObservableObject {

    @Published var snapshot = SensorSnapshot()
    @Published var policies: [FanPolicy] = []
    @Published var currentPolicyID: UUID = FanPolicy.system.id
    @Published var helperInstalled = false
    @Published var isInstalling = false
    @Published var lastError: String?

    private let reader = SensorReader()
    private var timer: Timer?

    private let policiesKey = "ifan.policies.v1"
    private let currentKey = "ifan.currentPolicy.v1"

    var currentPolicy: FanPolicy {
        policies.first { $0.id == currentPolicyID } ?? FanPolicy.system
    }

    init() {
        loadPolicies()
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
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func refresh() {
        if let snap = reader?.read() {
            snapshot = snap
        }
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
        guard !policy.isSystem else { return }
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
        UserDefaults.standard.set(policy.id.uuidString, forKey: currentKey)
        pushCurrentToDaemon()
    }

    func movePolicies(from source: IndexSet, to destination: Int) {
        // System policy stays locked at index 0.
        var dest = destination
        if dest == 0 { dest = 1 }
        guard !source.contains(0) else { return }
        policies.move(fromOffsets: source, toOffset: dest)
        savePolicies()
    }

    /// Sends the current policy's intent to the root daemon via the command file.
    private func pushCurrentToDaemon() {
        guard helperInstalled else { return }
        let p = currentPolicy
        if p.isSystem {
            FanController.sendCommand(manual: false, left: 0, right: 0)
        } else {
            let l = rpm(min: snapshot.fan0Min, max: snapshot.fan0Max, percent: p.leftPercent)
            let r = rpm(min: snapshot.fan1Min, max: snapshot.fan1Max, percent: p.rightPercent)
            FanController.sendCommand(manual: true, left: l, right: r)
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
            var list = decoded.filter { !$0.isSystem }
            list.insert(.system, at: 0)
            policies = list
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
}

private extension Double {
    func clamped() -> Double { Swift.min(100, Swift.max(0, self)) }
}
