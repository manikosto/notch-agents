import Foundation

struct UsageInfo: Equatable {
    var fiveHourPercent: Int
    var fiveHourResetsAt: Date?
    var sevenDayPercent: Int
    var sevenDayResetsAt: Date?
}

/// Лимиты подписки Claude (5h / 7d) — тот же OAuth-эндпоинт, что использует /usage в Claude Code.
final class UsageMonitor {
    var onUpdate: ((UsageInfo?) -> Void)?
    private var timer: Timer?
    private let queue = DispatchQueue(label: "usage-monitor", qos: .utility)

    func start() {
        fetchAsync()
        // эндпоинт строго рейт-лимитится (429 при частом опросе) — не чаще раза в 5 минут
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.fetchAsync()
        }
    }

    private func fetchAsync() {
        queue.async { [weak self] in self?.fetch() }
    }

    private func fetch() {
        guard let token = Self.accessToken(),
              let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else {
            DispatchQueue.main.async { self.onUpdate?(nil) }
            return
        }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.timeoutInterval = 10
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, _ in
            guard let self else { return }
            var info: UsageInfo?
            if let data,
               (resp as? HTTPURLResponse)?.statusCode == 200,
               let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                info = Self.parse(obj)
            }
            DispatchQueue.main.async { self.onUpdate?(info) }
        }.resume()
    }

    private static func parse(_ obj: [String: Any]) -> UsageInfo? {
        guard let five = obj["five_hour"] as? [String: Any],
              let seven = obj["seven_day"] as? [String: Any] else { return nil }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()

        func date(_ v: Any?) -> Date? {
            guard let s = v as? String else { return nil }
            return iso.date(from: s) ?? isoPlain.date(from: s)
        }
        func pct(_ v: Any?) -> Int {
            if let d = v as? Double { return Int(d.rounded()) }
            if let i = v as? Int { return i }
            return 0
        }

        return UsageInfo(fiveHourPercent: pct(five["utilization"]),
                         fiveHourResetsAt: date(five["resets_at"]),
                         sevenDayPercent: pct(seven["utilization"]),
                         sevenDayResetsAt: date(seven["resets_at"]))
    }

    /// Токен Claude Code: ~/.claude/.credentials.json или Keychain («Claude Code-credentials»).
    private static func accessToken() -> String? {
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
        if let data = try? Data(contentsOf: file), let t = token(fromJSON: data) {
            return t
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return token(fromJSON: pipe.fileHandleForReading.readDataToEndOfFile())
    }

    private static func token(fromJSON data: Data) -> String? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any] else { return nil }
        return oauth["accessToken"] as? String
    }
}
