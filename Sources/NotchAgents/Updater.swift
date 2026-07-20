import AppKit

struct UpdateInfo: Equatable {
    let version: String       // "1.1.2"
    let dmgURL: URL
    let pageURL: URL
}

/// Проверка обновлений через GitHub Releases + установка нотаризованного DMG на месте.
final class Updater {
    static let repo = "manikosto/notch-agents"
    static let teamID = "TQ5423H59B"   // Developer ID, которым подписаны релизы

    var onUpdate: ((UpdateInfo?) -> Void)?
    private var timer: Timer?

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Запускается только из установленного .app (в dev-сборке апдейт не имеет смысла).
    func start() {
        guard Bundle.main.bundlePath.hasSuffix(".app") else { return }
        check()
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            self?.check()
        }
    }

    func check() {
        guard let url = URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest") else { return }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 15
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self, let data,
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let tag = obj["tag_name"] as? String else { return }
            let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            let assets = obj["assets"] as? [[String: Any]] ?? []
            let dmg = assets.first { ($0["name"] as? String)?.hasSuffix(".dmg") == true }
            let pageStr = obj["html_url"] as? String ?? "https://github.com/\(Self.repo)/releases"

            guard Self.isNewer(latest, than: self.currentVersion),
                  let dmgStr = dmg?["browser_download_url"] as? String,
                  let dmgURL = URL(string: dmgStr),
                  let pageURL = URL(string: pageStr) else {
                DispatchQueue.main.async { self.onUpdate?(nil) }
                return
            }
            let info = UpdateInfo(version: latest, dmgURL: dmgURL, pageURL: pageURL)
            DispatchQueue.main.async { self.onUpdate?(info) }
        }.resume()
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: - Установка

    enum InstallState { case downloading, installing, failed(String) }
    var onInstallState: ((InstallState) -> Void)?

    /// Скачать DMG → проверить подпись → заменить .app хелпером → перезапуститься.
    func install(_ info: UpdateInfo) {
        onInstallState?(.downloading)
        URLSession.shared.downloadTask(with: info.dmgURL) { [weak self] tmp, _, err in
            guard let self else { return }
            guard let tmp, err == nil else {
                self.fail("Не удалось скачать обновление")
                return
            }
            // downloadTask удаляет tmp по возвращении — переносим в стабильное место
            let dmg = FileManager.default.temporaryDirectory
                .appendingPathComponent("NotchAgents-\(info.version).dmg")
            try? FileManager.default.removeItem(at: dmg)
            do { try FileManager.default.moveItem(at: tmp, to: dmg) }
            catch { self.fail("Ошибка записи DMG"); return }
            DispatchQueue.main.async { self.onInstallState?(.installing) }
            self.mountAndSwap(dmg: dmg, version: info.version)
        }.resume()
    }

    private func fail(_ msg: String) {
        DispatchQueue.main.async { self.onInstallState?(.failed(msg)) }
    }

    private func mountAndSwap(dmg: URL, version: String) {
        // 1. смонтировать
        guard let mount = Self.mount(dmg: dmg) else { fail("Не удалось смонтировать DMG"); return }
        // 2. найти .app внутри
        guard let src = (try? FileManager.default.contentsOfDirectory(atPath: mount))?
            .first(where: { $0.hasSuffix(".app") }) else {
            _ = Self.detach(mount); fail("В DMG нет приложения"); return
        }
        let srcApp = mount + "/" + src
        // 3. проверить, что это наш нотаризованный билд
        guard Self.verifySignature(appPath: srcApp) else {
            _ = Self.detach(mount); fail("Подпись обновления не прошла проверку"); return
        }
        // 4. скопировать .app из DMG в temp, чтобы отмонтировать до замены
        let staged = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotchAgents-new.app")
        try? FileManager.default.removeItem(at: staged)
        guard Self.ditto(from: srcApp, to: staged.path) else {
            _ = Self.detach(mount); fail("Ошибка копирования"); return
        }
        _ = Self.detach(mount)

        // 5. хелпер: ждёт выхода приложения, подменяет бандл, перезапускает
        let dest = Bundle.main.bundlePath
        let pid = ProcessInfo.processInfo.processIdentifier
        Self.launchSwapHelper(pid: pid, newApp: staged.path, dest: dest)
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }

    // MARK: - shell helpers

    @discardableResult
    private static func shell(_ path: String, _ args: [String]) -> (code: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    private static func mount(dmg: URL) -> String? {
        let r = shell("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-noverify", "-quiet"])
        guard r.code == 0 else { return nil }
        // последний столбец последней строки — точка монтирования /Volumes/...
        for line in r.out.split(separator: "\n").reversed() {
            if let range = line.range(of: "/Volumes/") {
                return String(line[range.lowerBound...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private static func detach(_ mount: String) -> Bool {
        shell("/usr/bin/hdiutil", ["detach", mount, "-force", "-quiet"]).code == 0
    }

    private static func verifySignature(appPath: String) -> Bool {
        // подпись валидна, Developer ID и наш Team ID
        let v = shell("/usr/bin/codesign", ["--verify", "--deep", "--strict", appPath])
        guard v.code == 0 else { return false }
        let info = shell("/usr/bin/codesign", ["-dv", "--verbose=4", appPath])
        return info.out.contains("TeamIdentifier=\(teamID)")
    }

    private static func ditto(from: String, to: String) -> Bool {
        shell("/usr/bin/ditto", [from, to]).code == 0
    }

    private static func launchSwapHelper(pid: Int32, newApp: String, dest: String) {
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("notch-swap.sh")
        let body = """
        #!/bin/bash
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        /bin/rm -rf "\(dest)"
        /usr/bin/ditto "\(newApp)" "\(dest)"
        /bin/rm -rf "\(newApp)"
        /usr/bin/open "\(dest)"
        """
        try? body.write(to: script, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script.path]
        try? p.run()   // detached: переживёт наш выход
    }
}
