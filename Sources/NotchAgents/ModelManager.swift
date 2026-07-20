import Foundation

enum ModelOption: String, CaseIterable, Identifiable {
    case fable = "claude-fable-5"
    case opus1m = "opus[1m]"
    case opus = "opus"
    case sonnet = "sonnet"
    case haiku = "haiku"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fable: return "Fable 5"
        case .opus1m: return "Opus 4.8 · 1M"
        case .opus: return "Opus 4.8"
        case .sonnet: return "Sonnet 5"
        case .haiku: return "Haiku 4.5"
        }
    }
}

/// Чтение/смена модели по умолчанию в ~/.claude/settings.json.
/// Действует на новые сессии Claude Code.
enum ModelManager {
    private static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
    }

    static func currentModel() -> String? {
        guard let data = try? Data(contentsOf: settingsURL),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        return obj["model"] as? String
    }

    static func prettyName(_ raw: String) -> String {
        if let opt = ModelOption(rawValue: raw) { return opt.title }
        let r = raw.lowercased()
        if r.contains("fable") { return "Fable 5" }
        if r.contains("opus") { return r.contains("[1m]") ? "Opus · 1M" : "Opus" }
        if r.contains("sonnet") { return "Sonnet" }
        if r.contains("haiku") { return "Haiku" }
        return raw
    }

    /// Меняем "model" точечной текстовой заменой — форматирование
    /// и порядок ключей settings.json остаются нетронутыми.
    @discardableResult
    static func setModel(_ raw: String) -> Bool {
        guard var text = try? String(contentsOf: settingsURL, encoding: .utf8),
              let regex = try? NSRegularExpression(pattern: "\"model\"\\s*:\\s*\"[^\"]*\"") else {
            return false
        }
        let replacement = "\"model\": \"\(raw)\""
        let range = NSRange(text.startIndex..., in: text)
        if regex.firstMatch(in: text, range: range) != nil {
            text = regex.stringByReplacingMatches(in: text, range: range, withTemplate: replacement)
        } else if let brace = text.firstIndex(of: "{") {
            text.insert(contentsOf: "\n  \(replacement),", at: text.index(after: brace))
        } else {
            return false
        }
        do {
            try text.write(to: settingsURL, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }
}
