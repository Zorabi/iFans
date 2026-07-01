# iFan

macOS 菜单栏风扇控制工具，专为 Apple Silicon（M1–M4 系列）MacBook Pro 设计。

## 功能

- **实时温度监控**：菜单栏显示 CPU 平均温度与最高核心温度，主窗口展示详细传感器数据（CPU / GPU / 机身温度）
- **风扇转速**：实时显示左右风扇 RPM，每秒刷新
- **风扇策略**：可新建、删除自定义风扇策略（按百分比设定左右风扇转速）；内置「自动」「安静」「均衡」「全速」四个预设
- **菜单栏常驻**：关闭窗口自动隐藏 Dock 图标，仅保留菜单栏图标；选中手动策略后风扇图标旋转动画
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
4. 关闭窗口：窗口消失 + Dock 图标消失，应用仍在菜单栏运行
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
| 左侧：已选策略 + 策略列表 + 实时转速 | 风扇图标（手动模式旋转）+ CPU 平均 / 最高温度 |
| 右侧：CPU 平均温度（大字，°C） | 下拉菜单：显示主窗口 / 策略切换 / 退出 |

## FAQ

**Q: 风扇切换策略后没有反应？**
A: 请确认已安装风扇控制守护进程（左侧面板顶部绿色圆点 +「风扇控制已就绪」）。

**Q: 如何卸载？**
A: 点击「卸载」按钮即可移除守护进程；再把 `/Applications/iFan.app` 拖入废纸篓。

**Q: 适配哪些机型？**
A: 已在 MacBook Pro 16" M4 Pro (Mac16,7) 实测通过。理论上支持所有 Apple Silicon MacBook Pro / Air。

## License

MIT
