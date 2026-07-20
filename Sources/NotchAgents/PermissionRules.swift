import Foundation

/// Правило «всегда разрешать»: для Bash — точная команда, для остальных — весь инструмент.
struct AlwaysRule: Codable, Equatable {
    let tool: String
    let command: String?
}

enum PermissionRules {
    private static let key = "alwaysAllowRules"

    static func load() -> [AlwaysRule] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let rules = try? JSONDecoder().decode([AlwaysRule].self, from: data) else {
            return []
        }
        return rules
    }

    static func add(tool: String, input: [String: Any]) {
        // без валидного имени инструмента правило не имеет смысла
        // (и Claude Code бракует правила с маленькой буквы)
        guard let first = tool.first, first.isUppercase else { return }
        let rule = AlwaysRule(tool: tool, command: input["command"] as? String)
        var rules = load()
        guard !rules.contains(rule) else { return }
        rules.append(rule)
        if let data = try? JSONEncoder().encode(rules) {
            UserDefaults.standard.set(data, forKey: key)
        }
        writeToSettings(rule)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    static func matches(tool: String, input: [String: Any]) -> Bool {
        let command = input["command"] as? String
        return load().contains { rule in
            guard rule.tool == tool else { return false }
            guard let ruleCommand = rule.command else { return true } // весь инструмент
            return ruleCommand == command
        }
    }

    static func ruleString(_ r: AlwaysRule) -> String {
        if let c = r.command { return "\(r.tool)(\(c))" }
        return r.tool
    }

    /// Дублируем правило в permissions.allow настроек Claude Code (текстовой вставкой,
    /// чтобы не пересобирать JSON и не терять форматирование). Ошибки не фатальны:
    /// авто-аппрув в приложении работает и без этого.
    private static func writeToSettings(_ rule: AlwaysRule) {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
        guard var text = try? String(contentsOf: url, encoding: .utf8) else { return }

        // полное JSON-экранирование: сырые \n внутри строки ломают весь settings.json
        let escaped = ruleString(rule)
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        let quoted = "\"\(escaped)\""
        guard !text.contains(quoted) else { return }

        if let allowRange = text.range(of: "\"allow\"\\s*:\\s*\\[", options: .regularExpression) {
            text.insert(contentsOf: "\n      \(quoted),", at: allowRange.upperBound)
        } else if let permRange = text.range(of: "\"permissions\"\\s*:\\s*\\{", options: .regularExpression) {
            text.insert(contentsOf: "\n    \"allow\": [\(quoted)],", at: permRange.upperBound)
        } else if let brace = text.firstIndex(of: "{") {
            text.insert(contentsOf: "\n  \"permissions\": {\n    \"allow\": [\(quoted)]\n  },", at: text.index(after: brace))
        } else {
            return
        }
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}
