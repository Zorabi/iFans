import Foundation

// MARK: - Signal flags

private var gStopRequested: sig_atomic_t = 0
private var gRelinquishRequested: sig_atomic_t = 0

// MARK: - Shared locations

enum FanPaths {
    static let label = "com.ifan.helper"
    static let supportDir = "/Library/Application Support/iFan"
    static let commandFile = supportDir + "/command.json"
    static let heartbeatFile = supportDir + "/heartbeat"
    static let logFile = supportDir + "/helper.log"
    static let plistPath = "/Library/LaunchDaemons/com.ifan.helper.plist"
}

private struct FanCommand: Codable {
    var mode: String
    var left: Double
    var right: Double
}

enum FanController {

    private static let watchdogTimeout: TimeInterval = 8
    /// If no heartbeat for this long, the daemon exits entirely (doesn't linger).
    private static let manualReassertInterval: TimeInterval = 30

    // MARK: - Daemon entry

    static func runDaemonIfNeeded() {
        guard CommandLine.arguments.contains("--daemon") else { return }
        runDaemon()
        exit(0)
    }

    private static func runDaemon() {
        log("==== iFan daemon starting (pid \(getpid()), uid \(getuid())) ====")
        guard let smc = SMC() else {
            log("FATAL: cannot open AppleSMC")
            exit(2)
        }

        let modeKeys = [
            smc.keyExists("F0Md") ? "F0Md" : "F0md",
            smc.keyExists("F1Md") ? "F1Md" : "F1md",
        ]
        let tgKeys = ["F0Tg", "F1Tg"]
        let hasFtst = smc.keyExists("Ftst")
        let fanMin = [smc.readValue("F0Mn") ?? 1350, smc.readValue("F1Mn") ?? 1350]
        let fanMax = [smc.readValue("F0Mx") ?? 5777, smc.readValue("F1Mx") ?? 5777]
        log("probe: modeKeys=\(modeKeys) Ftst=\(hasFtst) min=\(fanMin) max=\(fanMax)")

        // Always reset stale state left by a prior run on startup.
        for i in 0..<2 { _ = smc.writeUInt8(modeKeys[i], 0) }
        if hasFtst { _ = smc.writeUInt8("Ftst", 0) }
        log("startup: reset all mode keys + Ftst to 0")

        // No KeepAlive in LaunchDaemon means if this process dies, launchd won't
        // restart it. On SIGTERM/SIGINT/SIGHUP we set the flags so the loop body
        // breaks, and the final cleanup block below always runs on any exit path.
        signal(SIGTERM) { _ in gStopRequested = 1; gRelinquishRequested = 1 }
        signal(SIGINT)  { _ in gStopRequested = 1; gRelinquishRequested = 1 }
        signal(SIGHUP)  { _ in gStopRequested = 1; gRelinquishRequested = 1 }

        var lastModeManual: Bool? = nil
        var lastTargets: [Double] = [-1, -1]
        var lastManualWrite = Date.distantPast

        while gStopRequested == 0 {
            let cmd = readCommand()
            let hbAge = heartbeatAge()
            let wantManual = (cmd?.mode == "manual") && hbAge < watchdogTimeout

            if wantManual, let cmd {
                let targets = [
                    min(max(cmd.left,  fanMin[0]), fanMax[0]),
                    min(max(cmd.right, fanMin[1]), fanMax[1]),
                ]
                let changed = (lastModeManual != true) || lastTargets != targets
                let shouldWrite = changed || Date().timeIntervalSince(lastManualWrite) >= manualReassertInterval

                if shouldWrite {
                    var outcomes: [String] = []
                    if hasFtst {
                        outcomes.append("Ftst=1:\(smc.writeUInt8("Ftst", 1).description)")
                    }
                    for i in 0..<2 {
                        outcomes.append("\(modeKeys[i])=1:\(smc.writeUInt8(modeKeys[i], 1).description)")
                    }
                    for i in 0..<2 {
                        outcomes.append("\(tgKeys[i])=\(Int(targets[i])):\(smc.writeFloat(tgKeys[i], Float(targets[i])).description)")
                    }

                    let rbMode = smc.readValue(modeKeys[0]).map { Int($0) } ?? -1
                    let rbAc0 = smc.readValue("F0Ac").map { Int($0) } ?? -1
                    let rbAc1 = smc.readValue("F1Ac").map { Int($0) } ?? -1
                    log("MANUAL L=\(Int(targets[0])) R=\(Int(targets[1])) | \(outcomes.joined(separator: " ")) | readback \(modeKeys[0])=\(rbMode) F0Ac=\(rbAc0) F1Ac=\(rbAc1)")
                    lastManualWrite = Date()
                }
                lastModeManual = true
                lastTargets = targets
            } else {
                if lastModeManual != false {
                    for i in 0..<2 { _ = smc.writeUInt8(modeKeys[i], 0) }
                    if hasFtst { _ = smc.writeUInt8("Ftst", 0) }
                    let reason = cmd?.mode == "manual" ? "hb stale (\(String(format: "%.0f", hbAge))s)" : "auto"
                    log("AUTO restored (\(reason))")
                    lastModeManual = false
                    lastTargets = [-1, -1]
                    lastManualWrite = .distantPast
                }

            }

            for _ in 0..<8 {
                if gStopRequested != 0 { break }
                Thread.sleep(forTimeInterval: 0.25)
            }
        }

        // Final cleanup — guaranteed on any loop exit path.
        for i in 0..<2 { _ = smc.writeUInt8(modeKeys[i], 0) }
        if hasFtst { _ = smc.writeUInt8("Ftst", 0) }
        log("==== iFan daemon stopping, fans restored to auto ====")
    }

    // MARK: - Daemon IPC

    private static func readCommand() -> FanCommand? {
        guard let data = FileManager.default.contents(atPath: FanPaths.commandFile) else { return nil }
        return try? JSONDecoder().decode(FanCommand.self, from: data)
    }

    private static func heartbeatAge() -> TimeInterval {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: FanPaths.heartbeatFile),
              let mtime = attrs[.modificationDate] as? Date else {
            return .greatestFiniteMagnitude
        }
        return Date().timeIntervalSince(mtime)
    }

    private static func log(_ msg: String) {
        let line = "[\(Self.logStamp())] \(msg)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let fh = FileHandle(forWritingAtPath: FanPaths.logFile) {
            fh.seekToEndOfFile()
            fh.write(data)
            try? fh.close()
        } else {
            try? data.write(to: URL(fileURLWithPath: FanPaths.logFile))
        }
    }

    private static func logStamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        return f.string(from: Date())
    }

    // MARK: - GUI side: install / uninstall

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: FanPaths.plistPath)
    }

    static func install(completion: @escaping (Bool, String?) -> Void) {
        let exec = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let script = """
        set -e
        mkdir -p '\(FanPaths.supportDir)'
        chmod 777 '\(FanPaths.supportDir)'
        cat > '\(FanPaths.plistPath)' <<'PLIST'
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key><string>\(FanPaths.label)</string>
          <key>ProgramArguments</key>
          <array>
            <string>\(exec)</string>
            <string>--daemon</string>
          </array>
          <key>RunAtLoad</key><true/>
          <key>KeepAlive</key><true/>
          <key>StandardErrorPath</key><string>\(FanPaths.supportDir)/helper.err.log</string>
        </dict>
        </plist>
        PLIST
        chown root:wheel '\(FanPaths.plistPath)'
        chmod 644 '\(FanPaths.plistPath)'
        launchctl bootout system '\(FanPaths.plistPath)' 2>/dev/null || true
        launchctl bootstrap system '\(FanPaths.plistPath)'
        launchctl enable system/\(FanPaths.label)
        launchctl kickstart -k system/\(FanPaths.label)
        """
        runPrivileged(script, completion: completion)
    }

    static func uninstall(completion: @escaping (Bool, String?) -> Void) {
        let script = """
        launchctl bootout system/\(FanPaths.label) 2>/dev/null || true
        rm -f '\(FanPaths.plistPath)'
        """
        runPrivileged(script, completion: completion)
    }

    private static func runPrivileged(_ shellScript: String, completion: @escaping (Bool, String?) -> Void) {
        let tmp = NSTemporaryDirectory() + "ifan-priv-\(UUID().uuidString).sh"
        do {
            try ("#!/bin/sh\n" + shellScript + "\n").write(toFile: tmp, atomically: true, encoding: .utf8)
        } catch {
            DispatchQueue.main.async { completion(false, "无法写入临时脚本：\(error.localizedDescription)") }
            return
        }
        let appleScript = "do shell script \"/bin/sh '\(tmp)'\" with administrator privileges"

        DispatchQueue.global(qos: .userInitiated).async {
            defer { try? FileManager.default.removeItem(atPath: tmp) }
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            proc.arguments = ["-e", appleScript]
            let errPipe = Pipe()
            proc.standardError = errPipe
            do {
                try proc.run()
                proc.waitUntilExit()
                let ok = proc.terminationStatus == 0
                let errStr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                DispatchQueue.main.async {
                    completion(ok, ok ? nil : (errStr?.isEmpty == false ? errStr : "授权被取消或失败"))
                }
            } catch {
                DispatchQueue.main.async { completion(false, error.localizedDescription) }
            }
        }
    }

    // MARK: - GUI side: IPC writes

    static func sendCommand(manual: Bool, left: Double, right: Double) {
        let cmd = FanCommand(mode: manual ? "manual" : "auto", left: left, right: right)
        if let data = try? JSONEncoder().encode(cmd) {
            try? data.write(to: URL(fileURLWithPath: FanPaths.commandFile))
        }
        touchHeartbeat()
    }

    static func touchHeartbeat() {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: FanPaths.heartbeatFile) {
            try? fileManager.setAttributes(
                [.modificationDate: Date()],
                ofItemAtPath: FanPaths.heartbeatFile
            )
        } else {
            fileManager.createFile(atPath: FanPaths.heartbeatFile, contents: Data())
        }
    }

    static func readLog() -> String {
        (try? String(contentsOfFile: FanPaths.logFile, encoding: .utf8)) ?? ""
    }
}
