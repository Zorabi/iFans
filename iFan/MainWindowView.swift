import SwiftUI

private struct TemperatureSensorGroup: Identifiable {
    let name: String
    let sensors: [TemperatureSensorReading]

    var id: String { name }
    var average: Double { sensors.reduce(0) { $0 + $1.value } / Double(sensors.count) }
    var hottest: TemperatureSensorReading? { sensors.max { $0.value < $1.value } }
}

struct MainWindowView: View {
    @EnvironmentObject var state: AppState
    @State private var showingAdd = false
    @State private var showingLog = false
    @State private var showingTemperatureSettings = false
    @State private var showingAllTemperatureSensors = false
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
        .sheet(isPresented: $showingTemperatureSettings) {
            TemperatureSettingsSheet(
                curves: state.temperatureCurves,
                selectedID: state.selectedTemperatureCurveID
            ) { curves, selectedID in
                state.updateTemperatureCurves(curves, selectedID: selectedID)
            }
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
                if state.currentPolicy.isTemperatureControlled {
                    HStack(spacing: 6) {
                        Text(temperatureControlSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("设置") { showingTemperatureSettings = true }
                            .font(.caption)
                            .buttonStyle(.borderless)
                    }
                } else if !state.currentPolicy.isSystem {
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
                            temperatureCurveName: state.selectedTemperatureCurve?.name ?? "未选择曲线",
                            temperatureLevelCount: state.temperatureLevels.count,
                            onSelect: { state.applyPolicy(policy) },
                            onConfigure: { showingTemperatureSettings = true },
                            onDelete: { state.deletePolicy(policy) }
                        )
                        .opacity(draggingPolicyID == policy.id ? 0.4 : 1.0)
                        .onDrag {
                            guard !policy.isBuiltIn else { return NSItemProvider() }
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

    private var temperatureControlSummary: String {
        let temperature = state.temperatureControlTemperature
            .map { String(format: "%.1f°C", $0) } ?? "温度不可用"
        let curveName = state.selectedTemperatureCurve?.name ?? "温控曲线"
        guard let active = state.activeTemperatureLevel,
              let index = state.temperatureLevels.firstIndex(where: { $0.id == active.id }) else {
            return "\(curveName) · CPU 热点 \(temperature) · 系统自动"
        }
        return "\(curveName) · CPU 热点 \(temperature) · \(index + 1) 档 \(Int(active.percent))%"
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
                    cpuTemperatureCard

                    tempCardWide(
                        icon: "keyboard",
                        title: "机身温度 (键盘区域)",
                        temp: state.snapshot.chassisTemp
                    )

                    allTemperatureSensorsSection
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

    private var cpuTemperatureCard: some View {
        let snap = state.snapshot

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "cpu")
                    .font(.title3)
                    .foregroundStyle(tempColor(snap.cpuMaxTemp ?? snap.cpuTemp))
                Text("CPU 温度")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(snap.cpuSensorCount > 0 ? "\(snap.cpuSensorCount) 个核心 / 热点传感器" : "未检测到传感器")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: 14) {
                cpuTemperatureMetric(label: "平均", temp: snap.cpuTemp)
                    .frame(maxWidth: .infinity)

                Divider()
                    .frame(height: 42)

                cpuTemperatureMetric(label: "热点", temp: snap.cpuMaxTemp, source: snap.cpuHotspotKey)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.4)))
        .accessibilityElement(children: .combine)
    }

    private func cpuTemperatureMetric(label: String, temp: Double?, source: String? = nil) -> some View {
        HStack(alignment: .center, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let source {
                    Text("来源 \(source)")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 4)

            Text(temp.map { String(format: "%.1f°C", $0) } ?? "--°C")
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tempColor(temp))
        }
        .frame(minHeight: 42, alignment: .center)
    }

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

    // MARK: - All temperature sensors

    private var allTemperatureSensorsSection: some View {
        let sensors = state.snapshot.temperatureSensors
        let groups = temperatureSensorGroups(sensors)

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "thermometer.medium")
                    .foregroundStyle(.secondary)
                Text("温度传感器概览")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(sensors.isEmpty ? "未检测到" : "共 \(sensors.count) 个")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3),
                spacing: 8
            ) {
                ForEach(groups) { group in
                    temperatureGroupCard(group)
                }
            }

            Text("分类依据 SMC 键名推断；未公开含义的键归入「SoC / 其他」。")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            Divider()

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showingAllTemperatureSensors.toggle()
                }
            } label: {
                HStack {
                    Text("原始传感器明细（组内按温度降序）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: showingAllTemperatureSensors ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showingAllTemperatureSensors {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Label(group.name, systemImage: temperatureGroupIcon(group.name))
                                    .font(.caption.weight(.semibold))
                                Spacer()
                                Text("\(group.sensors.count) 个")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }

                            LazyVGrid(
                                columns: [GridItem(.adaptive(minimum: 170), spacing: 8)],
                                spacing: 8
                            ) {
                                ForEach(group.sensors) { sensor in
                                    temperatureSensorCell(sensor)
                                }
                            }
                        }
                    }
                }
                .transition(.opacity)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.4)))
    }

    private func temperatureGroupCard(_ group: TemperatureSensorGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(group.name, systemImage: temperatureGroupIcon(group.name))
                    .font(.caption.weight(.semibold))
                Spacer()
                Text("\(group.sensors.count) 个")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("平均")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(String(format: "%.1f°C", group.average))
                        .font(.system(.body, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(tempColor(group.average))
                }
                Spacer()
                if let hottest = group.hottest {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("最高 · \(hottest.key)")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text(String(format: "%.1f°C", hottest.value))
                            .font(.system(.body, design: .rounded).weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(tempColor(hottest.value))
                    }
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(.background.opacity(0.55)))
        .accessibilityElement(children: .combine)
    }

    private func temperatureSensorGroups(_ sensors: [TemperatureSensorReading]) -> [TemperatureSensorGroup] {
        let order = ["CPU", "GPU", "内存", "电池", "机身", "SoC / 其他"]
        let grouped = Dictionary(grouping: sensors, by: \.category)
        return order.compactMap { name in
            guard let groupSensors = grouped[name], !groupSensors.isEmpty else { return nil }
            return TemperatureSensorGroup(name: name, sensors: groupSensors)
        }
    }

    private func temperatureGroupIcon(_ name: String) -> String {
        switch name {
        case "CPU": return "cpu"
        case "GPU": return "display"
        case "内存": return "memorychip"
        case "电池": return "battery.75percent"
        case "机身": return "macbook"
        default: return "square.stack.3d.up"
        }
    }

    private func temperatureSensorCell(_ sensor: TemperatureSensorReading) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(sensor.key)
                    .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                Text(sensor.category)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 6)

            Text(String(format: "%.1f°C", sensor.value))
                .font(.system(.body, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(tempColor(sensor.value))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(.background.opacity(0.55)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(sensor.category) 传感器 \(sensor.key)，\(String(format: "%.1f", sensor.value)) 摄氏度")
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
              !policy.isBuiltIn,
              let fromIdx = policies.firstIndex(where: { $0.id == draggingID }),
              let toIdx = policies.firstIndex(where: { $0.id == policy.id }),
              !policies[fromIdx].isBuiltIn else { return }

        withAnimation(.easeInOut(duration: 0.2)) {
            let dest = toIdx > fromIdx ? toIdx + 1 : toIdx
            policies.move(fromOffsets: IndexSet(integer: fromIdx), toOffset: dest)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        policy.isBuiltIn ? nil : DropProposal(operation: .move)
    }
}

// MARK: - Policy row

private struct PolicyRow: View {
    let policy: FanPolicy
    let isCurrent: Bool
    let helperInstalled: Bool
    let temperatureCurveName: String
    let temperatureLevelCount: Int
    let onSelect: () -> Void
    let onConfigure: () -> Void
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isCurrent ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isCurrent ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(policy.name).fontWeight(isCurrent ? .semibold : .regular)
                if policy.isTemperatureControlled {
                    Text("\(temperatureCurveName) · \(temperatureLevelCount) 档")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if !policy.isSystem {
                    Text("左 \(Int(policy.leftPercent))%  ·  右 \(Int(policy.rightPercent))%")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if policy.isTemperatureControlled && hovering {
                Button(action: onConfigure) {
                    Image(systemName: "slider.horizontal.3")
                }
                .buttonStyle(.borderless)
                .help("设置温控档位")
            } else if !policy.isBuiltIn && hovering {
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
            if policy.isTemperatureControlled {
                Button(action: onConfigure) { Label("设置温控曲线", systemImage: "slider.horizontal.3") }
            } else if !policy.isBuiltIn {
                Button(role: .destructive, action: onDelete) { Label("删除", systemImage: "trash") }
            }
        }
    }
}

// MARK: - Temperature control settings

private struct TemperatureSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var curves: [TemperatureFanCurve]
    @State private var selectedID: UUID
    let onSave: ([TemperatureFanCurve], UUID) -> Void

    init(
        curves: [TemperatureFanCurve],
        selectedID: UUID,
        onSave: @escaping ([TemperatureFanCurve], UUID) -> Void
    ) {
        _curves = State(initialValue: curves)
        _selectedID = State(initialValue: selectedID)
        self.onSave = onSave
    }

    private var selectedIndex: Int? {
        curves.firstIndex { $0.id == selectedID }
    }

    private var hasDuplicateThresholds: Bool {
        curves.contains { curve in
            Set(curve.levels.map { Int($0.threshold.rounded()) }).count != curve.levels.count
        }
    }

    private var hasEmptyCurve: Bool {
        curves.contains { $0.levels.isEmpty }
    }

    private var hasInvalidNames: Bool {
        let names = curves.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) }
        return names.contains(where: \.isEmpty)
            || Set(names.map { $0.lowercased() }).count != names.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("智能温控设置")
                    .font(.title2.weight(.semibold))
                Text("保存多套自定义曲线，并选择当前用于自动调速的一套。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Picker("当前曲线", selection: $selectedID) {
                    ForEach(curves) { curve in
                        Text(curve.name).tag(curve.id)
                    }
                }
                .frame(maxWidth: .infinity)

                Button(action: addCurve) {
                    Image(systemName: "plus")
                }
                .help("新建曲线")

                Button(action: duplicateCurve) {
                    Image(systemName: "plus.square.on.square")
                }
                .help("复制当前曲线")

                Button(role: .destructive, action: deleteSelectedCurve) {
                    Image(systemName: "trash")
                }
                .help("删除当前曲线")
                .disabled(curves.count == 1)
            }

            if let curveIndex = selectedIndex {
                VStack(alignment: .leading, spacing: 6) {
                    Text("曲线名称")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("例如：游戏散热", text: $curves[curveIndex].name)
                        .textFieldStyle(.roundedBorder)
                }

                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(Array(curves[curveIndex].levels.indices), id: \.self) { levelIndex in
                            levelRow(curveIndex: curveIndex, levelIndex: levelIndex)
                        }
                    }
                }
                .frame(maxHeight: 330)

                HStack {
                    Button {
                        addLevel(to: curveIndex)
                    } label: {
                        Label("添加档位", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .disabled(curves[curveIndex].levels.count >= 10)

                    Button {
                        curves[curveIndex].levels = TemperatureFanLevel.defaults
                    } label: {
                        Label("恢复默认档位", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)

                    Spacer()
                }
                .padding(.vertical, 2)
            }

            VStack(alignment: .leading, spacing: 4) {
                if hasDuplicateThresholds {
                    Label("每个档位需要使用不同的温度阈值", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                if hasInvalidNames {
                    Label("曲线名称不能为空或重复", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                Text("降温时会比当前阈值低 3°C 后再降档，避免频繁切换。低于首档或温度不可用时，自动恢复系统控制。")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("保存") {
                    onSave(curves, selectedID)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(hasEmptyCurve || hasDuplicateThresholds || hasInvalidNames)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private func levelRow(curveIndex: Int, levelIndex: Int) -> some View {
        let level = $curves[curveIndex].levels[levelIndex]
        return VStack(spacing: 10) {
            HStack {
                Text("\(levelIndex + 1) 档")
                    .font(.headline)
                    .frame(width: 42, alignment: .leading)

                Stepper(value: level.threshold, in: 40...100, step: 1) {
                    Text("达到 \(Int(level.wrappedValue.threshold))°C")
                        .monospacedDigit()
                }

                Spacer()

                Button(role: .destructive) {
                    curves[curveIndex].levels.remove(at: levelIndex)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .disabled(curves[curveIndex].levels.count == 1)
            }

            HStack(spacing: 10) {
                Text("风扇")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 42, alignment: .leading)
                Slider(value: level.percent, in: 0...100, step: 1)
                Text("\(Int(level.wrappedValue.percent))%")
                    .monospacedDigit()
                    .frame(width: 42, alignment: .trailing)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.45)))
    }

    private func addCurve() {
        let levels = TemperatureFanLevel.defaults.map {
            TemperatureFanLevel(threshold: $0.threshold, percent: $0.percent)
        }
        let curve = TemperatureFanCurve(name: uniqueName("新温控曲线"), levels: levels)
        curves.append(curve)
        selectedID = curve.id
    }

    private func duplicateCurve() {
        guard let index = selectedIndex else { return }
        let source = curves[index]
        let levels = source.levels.map {
            TemperatureFanLevel(threshold: $0.threshold, percent: $0.percent)
        }
        let copy = TemperatureFanCurve(name: uniqueName("\(source.name) 副本"), levels: levels)
        curves.append(copy)
        selectedID = copy.id
    }

    private func deleteSelectedCurve() {
        guard curves.count > 1, let index = selectedIndex else { return }
        curves.remove(at: index)
        selectedID = curves[min(index, curves.count - 1)].id
    }

    private func addLevel(to curveIndex: Int) {
        let levels = curves[curveIndex].levels
        let occupied = Set(levels.map { Int($0.threshold.rounded()) })
        let preferred = min(100, Int((levels.map(\.threshold).max() ?? 50) + 5))
        let threshold = (preferred...100).first { !occupied.contains($0) }
            ?? (40...100).first { !occupied.contains($0) }
            ?? preferred
        let percent = min(100, (levels.last?.percent ?? 20) + 10)
        curves[curveIndex].levels.append(
            TemperatureFanLevel(threshold: Double(threshold), percent: percent)
        )
    }

    private func uniqueName(_ base: String) -> String {
        let existing = Set(curves.map { $0.name.lowercased() })
        if !existing.contains(base.lowercased()) { return base }
        for suffix in 2...99 {
            let candidate = "\(base) \(suffix)"
            if !existing.contains(candidate.lowercased()) { return candidate }
        }
        return "\(base) \(UUID().uuidString.prefix(4))"
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
