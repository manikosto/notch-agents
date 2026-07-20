import CryptoKit
import Foundation

// MARK: - Общие утилиты чтения

enum SessionIO {
    /// Хвост файла (возвращает также флаг «обрезано» — первая строка может быть неполной).
    static func tail(of url: URL, bytes: Int) -> (Data, Bool)? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        guard let size = try? fh.seekToEnd() else { return nil }
        let offset = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        try? fh.seek(toOffset: offset)
        guard let data = try? fh.readToEnd() else { return nil }
        return (data, offset > 0)
    }

    /// Начало файла (для метаданных в первой строке).
    static func head(of url: URL, bytes: Int) -> Data? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        return try? fh.read(upToCount: bytes)
    }

    static func jsonLines(_ data: Data, dropFirst: Bool) -> [[String: Any]] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        if dropFirst, !lines.isEmpty { lines.removeFirst() }
        return lines.compactMap {
            guard let d = String($0).data(using: .utf8) else { return nil }
            return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
        }
    }
}

protocol SessionProvider {
    func scan(cutoff: Date) -> [AgentSession]
}

// MARK: - Claude Code (~/.claude/projects/*/*.jsonl)

final class ClaudeSessionsProvider: SessionProvider {
    private let workingThreshold: TimeInterval = 5

    func scan(cutoff: Date) -> [AgentSession] {
        let fm = FileManager.default
        let base = fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        guard let dirs = try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return []
        }
        var result: [AgentSession] = []
        for dir in dirs {
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            let dated = files
                .filter { $0.pathExtension == "jsonl" && !$0.lastPathComponent.hasPrefix("agent-") }
                .compactMap { url -> (URL, Date)? in
                    guard let d = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { return nil }
                    return (url, d)
                }
            guard let newest = dated.max(by: { $0.1 < $1.1 }), newest.1 > cutoff else { continue }
            if let s = parse(file: newest.0, modified: newest.1) {
                result.append(s)
            }
        }
        return result
    }

    private func parse(file: URL, modified: Date) -> AgentSession? {
        guard let (data, truncated) = SessionIO.tail(of: file, bytes: 200_000) else { return nil }
        let lines = SessionIO.jsonLines(data, dropFirst: truncated)

        var cwd = ""
        var sessionId = file.deletingPathExtension().lastPathComponent
        var branch: String?
        var model: String?
        var lastUserText = ""
        var lastAssistantText = ""
        var lastRole: String?

        for obj in lines {
            if let c = obj["cwd"] as? String, !c.isEmpty { cwd = c }
            if let sid = obj["sessionId"] as? String { sessionId = sid }
            if let b = obj["gitBranch"] as? String, !b.isEmpty { branch = b }

            let type = obj["type"] as? String
            let msg = obj["message"] as? [String: Any]
            if type == "assistant" {
                if let m = msg?["model"] as? String { model = m }
                if let arr = msg?["content"] as? [[String: Any]],
                   let t = arr.first(where: { $0["type"] as? String == "text" })?["text"] as? String,
                   !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    lastAssistantText = t.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                lastRole = "assistant"
            } else if type == "user" {
                if let t = userText(from: msg), !t.isEmpty {
                    lastUserText = t
                    lastRole = "user"
                }
            }
        }
        guard lastRole != nil else { return nil }

        let age = Date().timeIntervalSince(modified)
        let status: AgentSession.Status = age < workingThreshold
            ? .working
            : (lastRole == "assistant" ? .waiting : .idle)
        let project = cwd.isEmpty
            ? file.deletingLastPathComponent().lastPathComponent
            : (cwd as NSString).lastPathComponent

        return AgentSession(id: file.path, sessionId: sessionId, agent: "Claude",
                            projectName: project, cwd: cwd, branch: branch,
                            title: String(lastUserText.prefix(80)),
                            lastAssistant: String(lastAssistantText.prefix(220)),
                            model: model.map(prettyModel),
                            lastModified: modified, status: status)
    }

    private func userText(from msg: [String: Any]?) -> String? {
        guard let msg else { return nil }
        var t: String?
        if let s = msg["content"] as? String {
            t = s
        } else if let arr = msg["content"] as? [[String: Any]] {
            t = arr.first(where: { $0["type"] as? String == "text" })?["text"] as? String
        }
        guard var s = t else { return nil }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("<") || s.hasPrefix("Caveat:") { return nil }
        return s.replacingOccurrences(of: "\n", with: " ")
    }

    private func prettyModel(_ raw: String) -> String {
        let r = raw.lowercased()
        if r.contains("fable") { return "Fable 5" }
        if r.contains("opus") { return r.contains("4-8") ? "Opus 4.8" : "Opus" }
        if r.contains("sonnet") { return r.contains("sonnet-5") ? "Sonnet 5" : "Sonnet" }
        if r.contains("haiku") { return "Haiku" }
        return raw
    }
}

// MARK: - Codex CLI (~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl)

final class CodexSessionsProvider: SessionProvider {
    func scan(cutoff: Date) -> [AgentSession] {
        let fm = FileManager.default
        let base = fm.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
        guard let enumerator = fm.enumerator(at: base,
                                             includingPropertiesForKeys: [.contentModificationDateKey],
                                             options: [.skipsHiddenFiles]) else { return [] }
        var result: [AgentSession] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl",
                  url.lastPathComponent.hasPrefix("rollout-"),
                  let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  modified > cutoff else { continue }
            if let s = parse(file: url, modified: modified) {
                result.append(s)
            }
        }
        return result
    }

    private func parse(file: URL, modified: Date) -> AgentSession? {
        // session_meta лежит в первой строке — хвостом её можно потерять
        var headLines: [[String: Any]] = []
        if let head = SessionIO.head(of: file, bytes: 16_384) {
            headLines = SessionIO.jsonLines(head, dropFirst: false)
        }
        guard let (data, truncated) = SessionIO.tail(of: file, bytes: 200_000) else { return nil }
        let lines = headLines + SessionIO.jsonLines(data, dropFirst: truncated)

        var cwd = ""
        var sessionId = file.deletingPathExtension().lastPathComponent
        var branch: String?
        var model: String?
        var lastUserText = ""
        var lastAssistantText = ""
        var lastRole: String?

        for obj in lines {
            let type = obj["type"] as? String
            let payload = obj["payload"] as? [String: Any]
            switch type {
            case "session_meta":
                if let c = payload?["cwd"] as? String { cwd = c }
                if let id = payload?["id"] as? String { sessionId = id }
                if let git = payload?["git"] as? [String: Any],
                   let b = git["branch"] as? String, !b.isEmpty { branch = b }
            case "turn_context":
                if let c = payload?["cwd"] as? String, !c.isEmpty { cwd = c }
                if let m = payload?["model"] as? String { model = m }
            case "event_msg":
                switch payload?["type"] as? String {
                case "user_message":
                    if let t = cleanText(payload?["message"] as? String) {
                        lastUserText = t
                        lastRole = "user"
                    }
                case "agent_message":
                    if let t = cleanText(payload?["message"] as? String) {
                        lastAssistantText = t
                    }
                    lastRole = "assistant"
                default:
                    break
                }
            case "response_item":
                if payload?["type"] as? String == "message" {
                    let role = payload?["role"] as? String
                    if role == "assistant" {
                        lastRole = "assistant"
                    } else if role == "user" {
                        let text = (payload?["content"] as? [[String: Any]])?
                            .first { ($0["type"] as? String)?.contains("text") == true }?["text"] as? String
                        if let t = cleanText(text) {
                            lastUserText = t
                            lastRole = "user"
                        }
                    }
                }
            default:
                break
            }
        }
        guard lastRole != nil else { return nil }

        let age = Date().timeIntervalSince(modified)
        let status: AgentSession.Status = age < 5
            ? .working
            : (lastRole == "assistant" ? .waiting : .idle)
        let project = cwd.isEmpty ? "codex" : (cwd as NSString).lastPathComponent

        return AgentSession(id: file.path, sessionId: sessionId, agent: "Codex",
                            projectName: project, cwd: cwd, branch: branch,
                            title: String(lastUserText.prefix(80)),
                            lastAssistant: String(lastAssistantText.prefix(220)),
                            model: model.map(prettyModel),
                            lastModified: modified, status: status)
    }

    private func cleanText(_ s: String?) -> String? {
        guard var s else { return nil }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !s.hasPrefix("<"), !s.hasPrefix("#") else { return nil }
        return s.replacingOccurrences(of: "\n", with: " ")
    }

    private func prettyModel(_ raw: String) -> String {
        raw.hasPrefix("gpt-") ? "GPT-" + raw.dropFirst(4).prefix(8) : raw
    }
}

// MARK: - Cursor Agent (~/.cursor/chats/<md5(cwd)>/<chatId>/store.db)

final class CursorSessionsProvider: SessionProvider {
    func scan(cutoff: Date) -> [AgentSession] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let base = home.appendingPathComponent(".cursor/chats")
        guard let hashDirs = try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return []
        }
        let knownPaths = knownProjectPaths()
        var result: [AgentSession] = []

        for hashDir in hashDirs {
            guard let chats = try? fm.contentsOfDirectory(at: hashDir, includingPropertiesForKeys: nil) else { continue }
            let dated = chats.compactMap { chat -> (URL, Date)? in
                let db = chat.appendingPathComponent("store.db")
                guard let d = (try? db.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { return nil }
                return (chat, d)
            }
            guard let newest = dated.max(by: { $0.1 < $1.1 }), newest.1 > cutoff else { continue }

            let hash = hashDir.lastPathComponent
            let cwd = knownPaths[hash] ?? ""
            let project = cwd.isEmpty ? "cursor" : (cwd as NSString).lastPathComponent
            let age = Date().timeIntervalSince(newest.1)
            // содержимое store.db бинарное — статус только по свежести файла
            let status: AgentSession.Status = age < 8 ? .working : .idle

            result.append(AgentSession(id: newest.0.path,
                                       sessionId: newest.0.lastPathComponent,
                                       agent: "Cursor",
                                       projectName: project, cwd: cwd, branch: nil,
                                       title: "Cursor Agent session",
                                       model: nil,
                                       lastModified: newest.1, status: status))
        }
        return result
    }

    /// md5(cwd) → cwd: восстанавливаем пути из слагов ~/.cursor/projects.
    private func knownProjectPaths() -> [String: String] {
        let fm = FileManager.default
        let projects = fm.homeDirectoryForCurrentUser.appendingPathComponent(".cursor/projects")
        guard let slugs = try? fm.contentsOfDirectory(atPath: projects.path) else { return [:] }
        var map: [String: String] = [:]
        for slug in slugs {
            let path = "/" + slug.replacingOccurrences(of: "-", with: "/")
            let digest = Insecure.MD5.hash(data: Data(path.utf8))
            let hex = digest.map { String(format: "%02x", $0) }.joined()
            map[hex] = path
        }
        return map
    }
}

// MARK: - Монитор: объединяет всех провайдеров

final class SessionMonitor {
    var onUpdate: (([AgentSession]) -> Void)?

    private var timer: Timer?
    private let queue = DispatchQueue(label: "session-monitor", qos: .utility)
    private let providers: [SessionProvider] = [
        ClaudeSessionsProvider(),
        CodexSessionsProvider(),
        CursorSessionsProvider(),
    ]
    private let maxAge: TimeInterval = 12 * 3600

    func start() {
        scanAsync()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.scanAsync()
        }
    }

    private func scanAsync() {
        queue.async { [weak self] in
            guard let self else { return }
            let cutoff = Date().addingTimeInterval(-self.maxAge)
            var sessions = self.providers.flatMap { $0.scan(cutoff: cutoff) }
            sessions.sort { $0.lastModified > $1.lastModified }
            let top = Array(sessions.prefix(6))
            DispatchQueue.main.async { self.onUpdate?(top) }
        }
    }
}
