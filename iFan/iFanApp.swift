import SwiftUI
import AppKit
import Combine

@main
enum EntryPoint {
    static func main() {
        FanController.runDaemonIfNeeded()
        iFanApp.main()
    }
}

struct iFanApp: App {
    @StateObject private var state = AppState()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("iFan", id: "main") {
            MainWindowView()
                .environmentObject(state)
                .onAppear { appDelegate.installStatusBarIfNeeded(state: state) }
        }
        .windowResizability(.contentSize)
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var mainWindow: NSWindow?
    private var statusBarController: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        trackMainWindowIfAvailable()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            openMainWindow()
        }
        return true
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender.title == "iFan" || sender == mainWindow {
            sender.orderOut(nil)
            NSApp.setActivationPolicy(.accessory)
            return false
        }
        return true
    }

    func installStatusBarIfNeeded(state: AppState) {
        trackMainWindowIfAvailable()
        guard statusBarController == nil else { return }
        statusBarController = StatusBarController(state: state, appDelegate: self)
    }

    func openMainWindow() {
        trackMainWindowIfAvailable()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        mainWindow?.makeKeyAndOrderFront(nil)
    }

    private func trackMainWindowIfAvailable() {
        guard let window = NSApp.windows.first(where: { $0.title == "iFan" }) else { return }
        mainWindow = window
        window.delegate = self
    }
}

@MainActor
private final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
private final class StatusBarController: NSObject, NSMenuDelegate {
    private static let fixedWidth: CGFloat = 52

    private let state: AppState
    private weak var appDelegate: AppDelegate?
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private var tooltipSubscription: AnyCancellable?

    init(state: AppState, appDelegate: AppDelegate) {
        self.state = state
        self.appDelegate = appDelegate
        self.statusItem = NSStatusBar.system.statusItem(withLength: Self.fixedWidth)
        super.init()

        if let button = statusItem.button {
            let label = PassthroughHostingView(rootView: MenuBarLabelView(state: state))
            label.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 2),
                label.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -2),
                label.topAnchor.constraint(equalTo: button.topAnchor),
                label.bottomAnchor.constraint(equalTo: button.bottomAnchor),
            ])
            button.setAccessibilityLabel("iFan 温度与风扇状态")
            button.toolTip = MenuBarLabelView.accessibilitySummary(state.snapshot)
            tooltipSubscription = state.$snapshot.sink { [weak button] snapshot in
                button?.toolTip = MenuBarLabelView.accessibilitySummary(snapshot)
            }
        }

        menu.delegate = self
        statusItem.menu = menu
    }

    deinit {
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let showItem = NSMenuItem(title: "显示主窗口", action: #selector(showMainWindow), keyEquivalent: "")
        showItem.target = self
        menu.addItem(showItem)
        menu.addItem(.separator())

        let heading = NSMenuItem(title: "预设选择", action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(heading)

        for policy in state.policies {
            let item = NSMenuItem(title: policy.name, action: #selector(applyPolicy(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = policy.id.uuidString
            item.state = policy.id == state.currentPolicyID ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "退出 iFan", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    @objc private func showMainWindow() {
        appDelegate?.openMainWindow()
    }

    @objc private func applyPolicy(_ sender: NSMenuItem) {
        guard let idString = sender.representedObject as? String,
              let id = UUID(uuidString: idString),
              let policy = state.policies.first(where: { $0.id == id }) else { return }
        state.applyPolicy(policy)
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}

// MARK: - Menu bar label (3s refresh via tick, data from @ObservedObject directly)

private struct MenuBarLabelView: View {
    @ObservedObject var state: AppState

    var body: some View {
        let snap = state.snapshot

        return HStack(spacing: 0) {
            Image(systemName: "fan.fill")
                .font(.system(size: 13))
                .frame(width: 14, height: 14)

            VStack(alignment: .leading, spacing: -2) {
                Text(Self.fmtTop(snap))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                Text(Self.fmtBot(snap))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .frame(minWidth: 34, idealWidth: 34, maxWidth: 34, alignment: .trailing)
            .fixedSize(horizontal: true, vertical: false)
        }
        .frame(minWidth: 48, idealWidth: 48, maxWidth: 48, alignment: .leading)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilitySummary(snap))
    }

    static func fmtTop(_ snap: SensorSnapshot) -> String {
        if let cpu = snap.cpuTemp { return String(format: "%.1f", cpu) }
        if let gpu = snap.gpuTemp  { return String(format: "G%.0f", gpu) }
        return "--"
    }
    static func fmtBot(_ snap: SensorSnapshot) -> String {
        if let cpu = snap.cpuMaxTemp { return String(format: "%.1f", cpu) }
        if let gpu = snap.gpuMaxTemp { return String(format: "G%.0f", gpu) }
        return "--"
    }
    static func fmtRPM(_ snap: SensorSnapshot) -> String {
        guard let rpm = snap.avgRPM else { return "--" }
        return rpm >= 1000 ? String(format: "%.1fk", rpm / 1000) : String(format: "%.0f", rpm)
    }

    static func accessibilitySummary(_ snap: SensorSnapshot) -> String {
        let average = snap.cpuTemp.map { String(format: "平均 %.1f°C", $0) } ?? "平均温度不可用"
        let hotspot = snap.cpuMaxTemp.map { String(format: "热点 %.1f°C", $0) } ?? "热点温度不可用"
        let rpm = snap.avgRPM.map { String(format: "风扇 %.0f RPM", $0) } ?? "风扇转速不可用"
        return "CPU \(average)，\(hotspot)，\(rpm)"
    }

}
