import AppKit

/// Точный прыжок к сессии: находим процесс агента по cwd, берём его tty
/// и просим терминал выбрать вкладку с этим tty (Terminal.app, iTerm2).
enum TerminalLocator {
    enum Resolution {
        case jumped        // точная вкладка Terminal/iTerm выбрана
        case hostActivated // сессия живёт (Warp/Ghostty/…) — поднято её приложение
        case notLive       // живого процесса нет — вызывающий сделает resume
    }

    /// Привести пользователя к живой сессии, НЕ плодя дубликатов:
    /// точная вкладка (Terminal/iTerm) → поднять терминал-хозяин (Warp и пр.) →
    /// или notLive, если процесса нет (тогда сессию можно resume-нуть).
    static func open(cwd: String) -> Resolution {
        guard !cwd.isEmpty, let found = locate(cwd: cwd) else { return .notLive }
        let dev = "/dev/\(found.tty)"
        if terminalTabJump(dev) || itermTabJump(dev) { return .jumped }
        // сессия жива, но не в Terminal/iTerm — resume создал бы второй процесс,
        // поэтому просто выводим её терминал на передний план
        if let app = hostingApp(forPid: found.pid), let url = app.bundleURL {
            NSWorkspace.shared.openApplication(at: url,
                                               configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
        } else {
            activateAnyKnownTerminal()
        }
        return .hostActivated
    }

    /// Выбрать уже открытую вкладку Terminal.app по её tty (например «/dev/ttys012»).
    /// true — вкладка ещё жива и вышла на передний план.
    static func focusTerminalTab(dev: String) -> Bool {
        terminalTabJump(dev)
    }

    /// Открыть новое окно Terminal.app с командой и вернуть tty этой вкладки
    /// («/dev/ttysNNN»), чтобы к ней можно было прыгать повторно.
    static func runInNewTerminal(command: String) -> String? {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Terminal"
          activate
          set theTab to do script "\(escaped)"
          return tty of theTab
        end tell
        """
        let out = osascript(script)
        return out.hasPrefix("/dev/tty") ? out : nil
    }

    private static func terminalTabJump(_ dev: String) -> Bool {
        guard isRunning("com.apple.Terminal") else { return false }
        let script = """
        tell application "Terminal"
          repeat with w in windows
            repeat with t in tabs of w
              if tty of t is "\(dev)" then
                set selected of t to true
                set index of w to 1
                activate
                return "ok"
              end if
            end repeat
          end repeat
        end tell
        return "no"
        """
        return osascript(script) == "ok"
    }

    private static func itermTabJump(_ dev: String) -> Bool {
        guard isRunning("com.googlecode.iterm2") else { return false }
        let script = """
        tell application "iTerm2"
          repeat with w in windows
            repeat with tb in tabs of w
              repeat with s in sessions of tb
                if tty of s is "\(dev)" then
                  select s
                  select tb
                  select w
                  activate
                  return "ok"
                end if
              end repeat
            end repeat
          end repeat
        end tell
        return "no"
        """
        return osascript(script) == "ok"
    }

    /// cwd сессии → (pid, tty) процесса агента.
    /// Один быстрый ps для списка, cwd — напрямую из ядра (lsof виснет на минуты).
    private static func locate(cwd: String) -> (pid: Int32, tty: String)? {
        let ps = run("/bin/ps", ["-axo", "pid=,tty=,comm="])
        for line in ps.split(separator: "\n") {
            let parts = line.trimmingCharacters(in: .whitespaces)
                .split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3 else { continue }
            let tty = String(parts[1])
            guard tty.hasPrefix("ttys"), let pid = Int32(parts[0]) else { continue }
            let name = (String(parts[2]) as NSString).lastPathComponent
            guard ["claude", "codex", "cursor-agent"].contains(name) else { continue }
            if processCwd(pid: pid) == cwd {
                return (pid, tty)
            }
        }
        return nil
    }

    /// Поднимаемся по цепочке родителей до GUI-приложения (Warp, Ghostty, VS Code…).
    private static func hostingApp(forPid pid: Int32) -> NSRunningApplication? {
        var current = pid
        for _ in 0..<10 {
            guard let ppid = parentPid(of: current), ppid > 1 else { return nil }
            if let app = NSRunningApplication(processIdentifier: ppid),
               app.bundleIdentifier != nil, app.activationPolicy == .regular {
                return app
            }
            current = ppid
        }
        return nil
    }

    private static func parentPid(of pid: Int32) -> Int32? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    private static func activateAnyKnownTerminal() {
        let ids = ["dev.warp.Warp-Stable", "com.googlecode.iterm2",
                   "com.apple.Terminal", "com.mitchellh.ghostty"]
        for id in ids {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first,
               let url = app.bundleURL {
                NSWorkspace.shared.openApplication(at: url,
                                                   configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
                return
            }
        }
    }

    /// cwd процесса через libproc — мгновенно, без subprocess.
    private static func processCwd(pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.stride)
        let ret = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size)
        guard ret == size else { return nil }
        return withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                String(cString: $0)
            }
        }
    }

    private static func isRunning(_ bundleId: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty
    }

    private static func osascript(_ script: String) -> String {
        run("/usr/bin/osascript", ["-e", script]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func run(_ path: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return "" }
        // ВАЖНО: читаем до waitUntilExit — иначе дедлок, когда вывод больше буфера пайпа
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
