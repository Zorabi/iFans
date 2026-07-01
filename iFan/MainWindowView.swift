import SwiftUI

struct MainWindowView: View {
    @EnvironmentObject var state: AppState
    @State private var showingAdd = false
    @State private var showingLog = false
    @State private var draggingPolicyID: UUID?

    var body: some View {
        HStack(spacing: 0) {
            policyPanel
                .frame(width: 320)
                .background(.regularMaterial)

            Divider()

            statusPanel
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 780, minHeight: 520)
        .sheet(isPresented: $showingAdd) {
            AddPolicySheet { name, left, right in
                state.addPolicy(name: name, left: left, right: right)
            }
        }
        .sheet(isPresented: $showingLog) {
            LogSheet { state.helperLog() }
        }
        .alert("提示", isPresented: Binding(
            get: { state.lastError != nil },
            set: { if !$0 { state.lastError = nil } }
        )) {
            Button("好", role: .cancel) { state.lastError = nil }
        } message: {
            Text(state.lastError ?? "")
        }
        .onAppear { state.startMonitoring() }
    }

    // MARK: - Left panel

    private var policyPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            helperBar
            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("正在使用")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Image(systemName: "fan.fill")
                        .foregroundStyle(.tint)
                    Text(state.currentPolicy.name)
                        .font(.title3.weight(.semibold))
                    if state.isInstalling {
                        ProgressView().controlSize(.small)
                    }
                }
                if !state.currentPolicy.isSystem {
                    Text("左 \(Int(state.currentPolicy.leftPercent))%  ·  右 \(Int(state.currentPolicy.rightPercent))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)

            Divider()

            HStack {
                Text("策略").font(.headline)
                Spacer()
                Button { showingAdd = true } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .disabled(!state.helperInstalled)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 6)

            if !state.helperInstalled {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text("请先点击上方「安装风扇控制」以启用策略")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
            }

            // Policy list with drag-to-reorder
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(state.policies) { policy in
                        PolicyRow(
                            policy: policy,
                            isCurrent: policy.id == state.currentPolicyID,
                            helperInstalled: state.helperInstalled,
                            onSelect: { state.applyPolicy(policy) },
                            onDelete: { state.deletePolicy(policy) }
                        )
                        .opacity(draggingPolicyID == policy.id ? 0.4 : 1.0)
                        .onDrag {
                            guard !policy.isSystem else { return NSItemProvider() }
                            draggingPolicyID = policy.id
                            return NSItemProvider(object: policy.id.uuidString as NSString)
                        }
                        .onDrop(
                            of: [.utf8PlainText],
                            delegate: PolicyDropDelegate(
                                policy: policy,
                                policies: $state.policies,
                                draggingID: $draggingPolicyID
                            )
                        )
                        .disabled(state.isInstalling)
                    }
                }
                .padding(.horizontal, 12)
            }

            Divider()

            VStack(spacing: 10) {
                Text("实时转速")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 12) {
                    fanGauge(title: "左风扇", rpm: state.snapshot.leftRPM)
                    fanGauge(title: "右风扇", rpm: state.snapshot.rightRPM)
                }
            }
            .padding(16)
        }
    }

    // MARK: - Helper bar

    private var helperBar: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(state.helperInstalled ? Color.green : Color.red)
                .frame(width: 7, height: 7)
            Text(state.helperInstalled ? "风扇控制已就绪" : "风扇控制未安装")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if !state.helperInstalled {
                Button { state.installHelper() } label: {
                    Text("安装风扇控制").font(.caption.weight(.medium))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(state.isInstalling)
            } else {
                Button { showingLog = true } label: {
                    Image(systemName: "doc.text").font(.caption)
                }
                .buttonStyle(.borderless)
                .help("查看守护进程日志")
                Button { state.uninstallHelper() } label: {
                    Text("卸载").font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .disabled(state.isInstalling)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(state.helperInstalled ? Color.green.opacity(0.08) : Color.red.opacity(0.08))
    }

    // MARK: - Fan gauge

    private func fanGauge(title: String, rpm: Double?) -> some View {
        VStack(spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(rpm.map { "\(Int($0))" } ?? "--")
                .font(.system(.title2, design: .rounded).weight(.semibold))
                .monospacedDigit()
            Text("RPM").font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))
    }

    // MARK: - Right panel: status overview

    private var statusPanel: some View {
        ScrollView {
            VStack(spacing: 0) {
                VStack(spacing: 12) {
                    tempCardWide(
                        icon: "cpu",
                        title: "CPU 温度",
                        temp: state.snapshot.cpuTemp,
                        subtitle: state.snapshot.cpuMaxTemp.map { String(format: "最高 %.1f°C", $0) } ?? "最高 --°C"
                    )

                    tempCardWide(
                        icon: "keyboard",
                        title: "机身温度 (键盘区域)",
                        temp: state.snapshot.chassisTemp
                    )
                }
                .padding(20)

                Divider()
                    .padding(.horizontal, 20)

                VStack(alignment: .leading, spacing: 14) {
                    detailSection

                    if state.snapshot.batteryHealth != nil {
                        batterySection
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Temperature card (small)

    private func tempCard(icon: String, title: String, temp: Double?, subtitle: String?) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(tempColor(temp))
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
            }

            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(temp.map { String(format: "%.1f", $0) } ?? "--")
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("°C")
                    .font(.system(size: 18, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(tempColor(temp))
            .frame(maxWidth: .infinity, alignment: .leading)

            if let sub = subtitle {
                Text(sub)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.4)))
    }

    // MARK: - Temperature card (wide)

    private func tempCardWide(icon: String, title: String, temp: Double?, subtitle: String = "") -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(tempColor(temp))
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(temp.map { String(format: "%.1f", $0) } ?? "--")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text("°C")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(tempColor(temp))
            }
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.4)))
    }

    private func tempColor(_ t: Double?) -> Color {
        guard let t else { return .primary }
        switch t {
        case ..<55: return .green
        case 55..<75: return .orange
        default:     return .red
        }
    }

    // MARK: - Detail section

    private var detailSection: some View {
        let snap = state.snapshot
        return VStack(alignment: .leading, spacing: 10) {
            Text("系统信息")
                .font(.headline)

            HStack(spacing: 6) {
                Image(systemName: "macbook")
                    .foregroundStyle(.secondary)
                Text("机型")
                    .foregroundStyle(.secondary)
                Text(snap.modelYear.isEmpty
                     ? snap.modelName
                     : "\(snap.modelName) (\(snap.modelYear))")
                    .fontWeight(.medium)
            }
            .font(.subheadline)

            HStack(spacing: 6) {
                Image(systemName: "fan")
                    .foregroundStyle(.secondary)
                Text("风扇")
                    .foregroundStyle(.secondary)
                Text("\(snap.fanCount) 个")
                    .fontWeight(.medium)
            }
            .font(.subheadline)

            if !snap.fanNames.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(snap.fanNames.enumerated()), id: \.offset) { _, name in
                        HStack(spacing: 4) {
                            Text("·")
                            Text(name)
                        }
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            }
        }
    }

    // MARK: - Battery section

    private var batterySection: some View {
        let snap = state.snapshot
        guard let health = snap.batteryHealth,
              let design = snap.batteryDesignCapacity,
              let maxCap = snap.batteryMaxCapacity else { return AnyView(EmptyView()) }

        return AnyView(
            VStack(alignment: .leading, spacing: 10) {
                Divider()

                Text("电池健康")
                    .font(.headline)

                HStack(spacing: 8) {
                    Image(systemName: batteryIcon(health: health))
                        .foregroundStyle(batteryColor(health: health))
                        .font(.title2)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(format: "%.1f%%", health))
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(batteryColor(health: health))

                        Text(String(format: "设计 %.0f mAh  ·  当前最高 %.0f mAh", design, maxCap))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(.quaternary)
                            .frame(height: 6)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(batteryColor(health: health))
                            .frame(width: geo.size.width * min(health / 100, 1), height: 6)
                    }
                }
                .frame(height: 6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        )
    }

    private func batteryIcon(health: Double) -> String {
        if health >= 90 { return "battery.100percent" }
        if health >= 75 { return "battery.75percent" }
        return "battery.50percent"
    }

    private func batteryColor(health: Double) -> Color {
        health >= 80 ? .green : health >= 60 ? .orange : .red
    }
}

// MARK: - Drag-and-drop reorder delegate

private struct PolicyDropDelegate: DropDelegate {
    let policy: FanPolicy
    @Binding var policies: [FanPolicy]
    @Binding var draggingID: UUID?

    func performDrop(info: DropInfo) -> Bool {
        draggingID = nil
        return true
    }

    func dropEntered(info: DropInfo) {
        guard let draggingID,
              draggingID != policy.id,
              !policy.isSystem,
              let fromIdx = policies.firstIndex(where: { $0.id == draggingID }),
              let toIdx = policies.firstIndex(where: { $0.id == policy.id }),
              fromIdx != 0, toIdx != 0 else { return }

        withAnimation(.easeInOut(duration: 0.2)) {
            let dest = toIdx > fromIdx ? toIdx + 1 : toIdx
            policies.move(fromOffsets: IndexSet(integer: fromIdx), toOffset: dest)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        policy.isSystem ? nil : DropProposal(operation: .move)
    }
}

// MARK: - Policy row

private struct PolicyRow: View {
    let policy: FanPolicy
    let isCurrent: Bool
    let helperInstalled: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isCurrent ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isCurrent ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(policy.name).fontWeight(isCurrent ? .semibold : .regular)
                if !policy.isSystem {
                    Text("左 \(Int(policy.leftPercent))%  ·  右 \(Int(policy.rightPercent))%")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if !policy.isSystem && hovering {
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(isCurrent ? Color.accentColor.opacity(0.15) : .clear))
        .contentShape(Rectangle())
        .onTapGesture {
            if helperInstalled { onSelect() }
        }
        .onHover { hovering = $0 }
        .contextMenu {
            if !policy.isSystem {
                Button(role: .destructive, action: onDelete) { Label("删除", systemImage: "trash") }
            }
        }
    }
}

// MARK: - Add policy sheet

private struct AddPolicySheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var left: Double = 50
    @State private var right: Double = 50
    let onAdd: (String, Double, Double) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("新增策略").font(.title2.weight(.semibold))

            VStack(alignment: .leading, spacing: 6) {
                Text("名称").font(.caption).foregroundStyle(.secondary)
                TextField("例如：游戏散热", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            sliderRow(title: "左风扇", value: $left)
            sliderRow(title: "右风扇", value: $right)

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("添加") {
                    onAdd(name, left, right)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private func sliderRow(title: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(value.wrappedValue))%").monospacedDigit()
            }
            Slider(value: value, in: 0...100, step: 1)
        }
    }
}

// MARK: - Log sheet

private struct LogSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var logText = ""
    let fetchLog: () -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("守护进程日志").font(.title2.weight(.semibold))
                Spacer()
                Button { logText = fetchLog() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                Button("关闭") { dismiss() }
            }

            ScrollView {
                Text(logText)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }

            HStack {
                Spacer()
                Button("复制到剪贴板") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(logText, forType: .string)
                }
            }
        }
        .padding(20)
        .frame(width: 600, height: 400)
        .onAppear { logText = fetchLog() }
    }
}
