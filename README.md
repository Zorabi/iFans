# iFan

macOS 菜单栏风扇控制与温度监控工具，面向 Apple Silicon（M1–M5 系列）Mac。

## 功能

- **CPU 平均与热点温度**：读取 Apple Silicon 的 `Tp*` / `TC*` / `Te*` / `Tf*` 核心及热点传感器，并标出当前热点来源 SMC 键
- **温度聚合与明细**：按 CPU、GPU、内存、电池、机身、SoC / 其他汇总传感器数量、平均温度与最高温度；可继续展开所有有效温度 SMC 键
- **分批刷新**：CPU、GPU、机身和风扇每 2 秒更新；其余温度传感器以小批次循环更新，避免一次读取上百个 SMC 键造成负载尖峰
- **风扇转速**：实时显示左右风扇 RPM
- **风扇策略**：可新建、删除自定义风扇策略（按百分比设定左右风扇转速）；内置「自动」「安静」「均衡」「全速」四个预设
- **固定宽度菜单栏**：使用 AppKit `NSStatusItem` 锁定占位，仅显示静态风扇图标、CPU 平均温度和热点温度；数值变化不会挤动其他状态栏图标
- **低开销监控与控制**：持久缓存 SMC 键列表、类型与数据长度，重启后无需重复探测；手动策略仅在目标变化时写入，并每 30 秒低频校验一次
- **原生尺寸图标**：重新制作完整 macOS App Icon 图标集，适配 Dock 的视觉尺寸
- **温度安全着色**：CPU 温度 < 55°C 绿色、55–75°C 橙色、> 75°C 红色
- **机型识别**：自动检测 Mac 型号，显示设备名称和年份
- **电池健康度**：笔记本上显示电池设计容量 / 当前最大容量 / 健康百分比

## 系统要求

- macOS 14.0 (Sonoma) 及以上
- Apple Silicon Mac（M1 / M2 / M3 / M4 / M5 系列）
- **风扇控制**功能需要安装 root 守护进程（应用内一键安装，仅需授权一次）

## 安装

### 方式一：源码编译

```bash
git clone https://github.com/chansss/iFans.git
cd iFans
# Release 编译并安装到 /Applications
bash build.sh
```

### 方式二：Xcode 打开

```bash
open iFan.xcodeproj
```

按 ⌘R 运行（Debug 模式）。

## 使用说明

1. 首次启动后，左侧面板顶部会提示「风扇控制未安装」
2. 点击「安装风扇控制」→ 输入系统密码授权 → 守护进程安装完毕
3. 之后切换策略即可实时生效，无需再次授权
4. 点击关闭按钮或按 `⌘W`：主窗口隐藏且 Dock 图标消失，应用继续在菜单栏运行；只有 `⌘Q` 或菜单栏中的「退出 iFan」会完全退出
5. 彻底退出：点击菜单栏图标 →「退出 iFan」

## 风扇控制原理

Apple Silicon Mac 的 `thermalmonitord` 守护进程会将风扇锁定在 System Mode（模式 3），阻止用户直接写入 SMC。iFan 通过安装 root 守护进程，在手动模式下写入 `Ftst` 诊断解锁序列突破固件限制：

- `F0Md=0` → `F0Md=1` → `F0Tg=<目标转速>`
- 守护进程每 2 秒循环维持手动模式，防止系统回收
- 守护进程具备 **8 秒心跳看门狗**：GUI 进程退出后自动恢复系统自动模式
- **120 秒无心跳自动退出**：守护进程不会无限驻留，保障安全

> ⚠️ 风扇控制涉及底层固件写入，请合理设置转速。iFan 会将目标转速限定在风扇硬件支持的最小/最大范围内，避免极端值。

## 项目结构

```
iFan/
├── iFanApp.swift          # 入口 + 菜单栏 + Dock 管理
├── AppState.swift         # 数据状态管理
├── Models.swift           # 策略/传感器数据模型
├── SMC.swift              # AppleSMC IOKit 底层读写
├── SensorReader.swift     # 温度/转速/电池传感器读取
├── FanController.swift    # 风扇控制守护进程 + IPC
├── MainWindowView.swift   # 主窗口 SwiftUI 视图
└── Assets.xcassets/       # App 图标
```

## 截图

| 主窗口 | 菜单栏 |
|--------|--------|
| 左侧：已选策略 + 策略列表 + 实时转速 | 静态风扇图标 + CPU 平均 / 热点温度 |
| 右侧：CPU 平均 / 热点、传感器聚合及可展开明细 | 下拉菜单：显示主窗口 / 策略切换 / 退出 |

## FAQ

**Q: 风扇切换策略后没有反应？**
A: 请确认已安装风扇控制守护进程（左侧面板顶部绿色圆点 +「风扇控制已就绪」）。

**Q: 如何卸载？**
A: 点击「卸载」按钮即可移除守护进程；再把 `/Applications/iFan.app` 拖入废纸篓。

**Q: 适配哪些机型？**
A: 已在 MacBook Pro 16" M4 Pro (Mac16,7) 实测通过。理论上支持所有 Apple Silicon MacBook Pro / Air。

**Q: 为什么完整传感器列表不是每秒更新？**
A: Apple Silicon 设备可能暴露上百个温度 SMC 键。iFan 首次识别机型后会持久缓存 SMC 键列表、类型与数据长度；重启时仍重新读取实时温度，不会展示落盘的过期数值。日常运行时每 2 秒更新 CPU 热点、机身温度和风扇等关键数据，其余温度传感器每次只轮询一小批并循环更新，从而摊平 IOKit 调用和 CPU 唤醒。传感器类别根据 SMC 键名前缀推断，Apple 未公开含义的键会归入「SoC / 其他」。

## 致谢

本项目基于 [chansss/iFans](https://github.com/chansss/iFans) 的源码继续改进。感谢原作者 [chansss](https://github.com/chansss) 创建并开源 iFans，为 Apple Silicon 风扇控制、SMC 读取和守护进程实现提供了扎实基础。

本次改进重点包括 Apple Silicon 核心/热点传感器补全、全部温度传感器聚合、固定宽度菜单栏、监控性能优化以及 macOS App Icon 适配。

## License

MIT
