import Foundation

/// Zero-config: при запуске приложение само подключает свои хуки.
/// Идемпотентно — если хуки уже стоят, ничего не трогает (в т.ч. формат файла).
enum HookInstaller {
    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    static func ensureAll() {
        ensureClaudeHooks()
        ensureCodexNotify()
    }

    // MARK: - Claude Code (~/.claude/settings.json)

    private static func ensureClaudeHooks() {
        let url = home.appendingPathComponent(".claude/settings.json")
        var obj: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
           let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            obj = parsed
        } else if FileManager.default.fileExists(atPath: url.path) {
            return   // файл есть, но не парсится — не рискуем
        }

        var hooks = obj["hooks"] as? [String: Any] ?? [:]
        var changed = false

        func curl(_ endpoint: String, maxTime: Int) -> String {
            "curl -s --max-time \(maxTime) -X POST -H 'Content-Type: application/json' "
            + "--data-binary @- http://127.0.0.1:48738/\(endpoint) 2>/dev/null || true"
        }
        func entry(matcher: String, command: String, timeout: Int) -> [String: Any] {
            ["matcher": matcher,
             "hooks": [["type": "command", "command": command, "timeout": timeout]]]
        }
        func ensure(event: String, marker: String, add: [String: Any]) {
            var arr = hooks[event] as? [[String: Any]] ?? []
            let present = arr.contains {
                guard let d = try? JSONSerialization.data(withJSONObject: $0),
                      let s = String(data: d, encoding: .utf8) else { return false }
                return s.contains(marker)
            }
            guard !present else { return }
            arr.append(add)
            hooks[event] = arr
            changed = true
        }

        for event in ["Stop", "Notification", "UserPromptSubmit", "SessionEnd"] {
            ensure(event: event, marker: "48738/hook",
                   add: entry(matcher: "", command: curl("hook", maxTime: 1), timeout: 3))
        }
        ensure(event: "PermissionRequest", marker: "48738/permission",
               add: entry(matcher: "", command: curl("permission", maxTime: 55), timeout: 60))
        ensure(event: "PreToolUse", marker: "48738/question",
               add: entry(matcher: "AskUserQuestion", command: curl("question", maxTime: 42), timeout: 45))

        guard changed else { return }
        obj["hooks"] = hooks
        if let data = try? JSONSerialization.data(withJSONObject: obj,
                                                  options: [.prettyPrinted, .sortedKeys]) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? data.write(to: url)
        }
    }

    // MARK: - Codex (~/.codex/config.toml)

    private static func ensureCodexNotify() {
        let cfg = home.appendingPathComponent(".codex/config.toml")
        guard FileManager.default.fileExists(atPath: cfg.path),
              var text = try? String(contentsOf: cfg, encoding: .utf8),
              !text.contains("notify =") else { return }

        guard let script = installNotifyScript() else { return }
        // notify — top-level ключ, должен стоять до [секций]
        text = "notify = [\"\(script.path)\"]\n\n" + text
        try? text.write(to: cfg, atomically: true, encoding: .utf8)
    }

    private static func installNotifyScript() -> URL? {
        let fm = FileManager.default
        guard let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = support.appendingPathComponent("NotchAgents")
        let script = dir.appendingPathComponent("codex-notify.sh")
        let body = """
        #!/bin/bash
        # Codex notify hook: пробрасывает событие (JSON в $1) в Notch Agents.
        curl -s --max-time 2 -X POST -H 'Content-Type: application/json' \\
          --data-binary "${1:-{}}" http://127.0.0.1:48738/codex-notify >/dev/null 2>&1 || true
        """
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try body.write(to: script, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
            return script
        } catch {
            return nil
        }
    }
}
