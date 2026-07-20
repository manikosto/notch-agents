import AppKit

/// Точный прыжок к сессии: находим процесс агента по cwd, берём его tty
/// и просим терминал выбрать вкладку с этим tty (Terminal.app, iTerm2).
enum TerminalLocator {
    /// Точный прыжок к вкладке сессии — только там, где терминал умеет выбрать
    /// вкладку по tty (Terminal.app, iTerm2). Во всех остальных случаях false —
    /// вызывающий откроет сессию в обычном Terminal через resume.
    static func preciseJump(cwd: String) -> Bool {
        guard !cwd.isEmpty, let found = locate(cwd: cwd) else { return false }
        let dev = "/dev/\(found.tty)"
        return terminalTabJump(dev) || itermTabJump(dev)
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
