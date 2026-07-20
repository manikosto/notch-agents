import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: NotchController!
    private var statusItem: NSStatusItem!
    private let state = NotchState()
    private let monitor = SessionMonitor()
    private let hookServer = HookServer()
    private let usageMonitor = UsageMonitor()
    private let updater = Updater()

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = NotchController(state: state)

        // Список сессий — Claude / Codex / Cursor (фон)
        monitor.onUpdate = { [weak self] sessions in
            self?.state.sessions = sessions
        }
        monitor.start()

        // Живые события — из хуков Claude Code (точные сигналы)
        hookServer.onEvent = { [weak self] obj in
            self?.handleHook(obj)
        }
        hookServer.onPermission = { [weak self] obj, responder in
            self?.handlePermission(obj, responder)
        }
        hookServer.onQuestion = { [weak self] obj, responder in
            self?.handleQuestion(obj, responder)
        }
        hookServer.start()

        controller.permissionHandler = { [weak self] id, action in
            self?.resolvePermission(id: id, action: action)
        }
        controller.questionHandler = { [weak self] id, answer in
            self?.resolveQuestion(id: id, answer: answer)
        }

        // Лимиты подписки (5h / 7d); при ошибке (429 и т.п.) держим последнее значение
        usageMonitor.onUpdate = { [weak self] info in
            if let info { self?.state.usage = info }
        }
        usageMonitor.start()

        state.defaultModel = ModelManager.currentModel()

        // Проверка обновлений (GitHub Releases) + установка нотаризованного DMG
        updater.onUpdate = { [weak self] info in self?.state.update = info }
        updater.onInstallState = { [weak self] st in
            guard let self else { return }
            switch st {
            case .downloading, .installing:
                self.state.updateBusy = true
            case .failed(let msg):
                self.state.updateBusy = false
                self.notifyUpdateFailed(msg)
            }
        }
        controller.updateHandler = { [weak self] in
            guard let self, let info = self.state.update, !self.state.updateBusy else { return }
            self.updater.install(info)
        }
        updater.start()

        // Zero-config: сами подключаем хуки Claude Code и notify Codex (идемпотентно)
        DispatchQueue.global(qos: .utility).async { HookInstaller.ensureAll() }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.title = "👾"
        registerLoginItemIfBundled()

        let menu = NSMenu()
        let checkItem = NSMenuItem(title: "Проверить обновления",
                                   action: #selector(checkForUpdates),
                                   keyEquivalent: "")
        checkItem.target = self
        menu.addItem(checkItem)
        menu.addItem(.separator())
        let resetItem = NSMenuItem(title: "Сбросить правила Always Allow",
                                   action: #selector(resetAlwaysRules),
                                   keyEquivalent: "")
        resetItem.target = self
        menu.addItem(resetItem)
        if isBundled {
            let loginItem = NSMenuItem(title: "Запускать при логине",
                                       action: #selector(toggleLoginItem(_:)),
                                       keyEquivalent: "")
            loginItem.target = self
            loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
            menu.addItem(loginItem)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Notch Agents",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        statusItem.menu = menu
    }

    // MARK: - Hook events

    private func handleHook(_ obj: [String: Any]) {
        // notify-хук Codex: JSON без hook_event_name, с полем type
        if obj["hook_event_name"] == nil {
            if let type = obj["type"] as? String, type == "agent-turn-complete" {
                let session = state.sessions.first { $0.agent == "Codex" }
                showCompletion(session: session,
                               agent: "Codex",
                               summary: obj["last-assistant-message"] as? String ?? "")
            }
            return
        }
        guard let event = obj["hook_event_name"] as? String else { return }
        let sid = obj["session_id"] as? String ?? ""

        switch event {
        case "Notification":
            // если по этой сессии уже висит интерактивная карточка — алерт не нужен
            if state.prompts.contains(where: { $0.sessionId == sid })
                || state.questions.contains(where: { $0.sessionId == sid }) { return }
            let msg = obj["message"] as? String ?? "Claude ждёт вашего ответа"
            let isPermission = msg.lowercased().contains("permission")
            let isNew = !state.alerts.contains { $0.id == sid }
            upsertAlert(SessionAlert(id: sid,
                                     kind: isPermission ? .approval : .waiting,
                                     message: msg,
                                     date: Date()))
            if isNew { play("Glass") }
            controller.alertPop()

        case "Stop":
            removeAlert(sid)
            let session = state.sessions.first { $0.sessionId == sid }
            showCompletion(session: session, agent: session?.agent ?? "Claude", summary: "")

        case "UserPromptSubmit", "SessionEnd":
            removeAlert(sid)
            if state.completion?.sessionId == sid { state.completion = nil }

        default:
            break
        }
    }

    // MARK: - Permission prompts (Allow/Deny из нотча)

    private struct PendingPermission {
        let responder: PermissionResponder
        let tool: String
        let input: [String: Any]
    }

    private var pendingPermissions: [String: PendingPermission] = [:]

    private func handlePermission(_ obj: [String: Any], _ responder: PermissionResponder) {
        let sid = obj["session_id"] as? String ?? ""
        let tool = obj["tool_name"] as? String ?? "tool"
        let input = obj["tool_input"] as? [String: Any] ?? [:]
        let cwd = obj["cwd"] as? String ?? ""

        // правило «всегда разрешать» — отвечаем сразу, без карточки
        if PermissionRules.matches(tool: tool, input: input) {
            responder.send(Self.decisionJSON(allow: true))
            return
        }

        let id = UUID().uuidString
        let prompt = PermissionPrompt(id: id,
                                      sessionId: sid,
                                      tool: tool,
                                      summary: Self.summary(tool: tool, input: input),
                                      projectName: cwd.isEmpty ? "" : (cwd as NSString).lastPathComponent,
                                      date: Date(),
                                      diff: Self.diffPreview(tool: tool, input: input))
        pendingPermissions[id] = PendingPermission(responder: responder, tool: tool, input: input)
        state.prompts.append(prompt)
        state.showAllSessions = false   // событие занимает экран
        removeAlert(sid)   // интерактивная карточка информативнее алерта
        play("Glass")
        controller.holdOpen()

        // не тронули карточку 45с — отпускаем запрос в терминальный диалог
        DispatchQueue.main.asyncAfter(deadline: .now() + 45) { [weak self] in
            self?.resolvePermission(id: id, action: .dismiss, userInitiated: false)
        }
    }

    private func resolvePermission(id: String, action: PermissionAction, userInitiated: Bool = true) {
        guard let pending = pendingPermissions.removeValue(forKey: id) else { return }
        switch action {
        case .allow:
            pending.responder.send(Self.decisionJSON(allow: true))
        case .always:
            PermissionRules.add(tool: pending.tool, input: pending.input)
            pending.responder.send(Self.decisionJSON(allow: true))
        case .deny:
            pending.responder.send(Self.decisionJSON(allow: false))
        case .dismiss:
            pending.responder.send("{}")
        }
        state.prompts.removeAll { $0.id == id }
        finishEventIfIdle(userInitiated: userInitiated)
    }

    /// Все события закрыты: после действия пользователя — мгновенно сворачиваемся,
    /// после таймаута — мягко (вдруг пользователь сейчас читает панель).
    private func finishEventIfIdle(userInitiated: Bool) {
        guard state.prompts.isEmpty && state.questions.isEmpty else { return }
        if userInitiated {
            controller.collapseNow()
        } else {
            controller.release(after: 0.3)
        }
    }

    // MARK: - Вопросы AskUserQuestion (варианты прямо в нотче)

    private var pendingQuestions: [String: PermissionResponder] = [:]

    private func handleQuestion(_ obj: [String: Any], _ responder: PermissionResponder) {
        let sid = obj["session_id"] as? String ?? ""
        let cwd = obj["cwd"] as? String ?? ""
        guard let input = obj["tool_input"] as? [String: Any],
              let questions = input["questions"] as? [[String: Any]],
              let q = questions.first,
              let text = q["question"] as? String else {
            responder.send("{}")
            return
        }
        let options = (q["options"] as? [[String: Any]] ?? []).compactMap { o -> QuestionPrompt.Option? in
            guard let label = o["label"] as? String else { return nil }
            return QuestionPrompt.Option(label: label,
                                         description: o["description"] as? String ?? "")
        }
        guard !options.isEmpty else {
            responder.send("{}")
            return
        }

        let id = UUID().uuidString
        let prompt = QuestionPrompt(id: id,
                                    sessionId: sid,
                                    header: q["header"] as? String ?? "Question",
                                    question: text,
                                    options: Array(options.prefix(4)),
                                    projectName: cwd.isEmpty ? "" : (cwd as NSString).lastPathComponent,
                                    date: Date())
        pendingQuestions[id] = responder
        state.questions.append(prompt)
        state.showAllSessions = false   // событие занимает экран
        removeAlert(sid)
        play("Glass")
        controller.holdOpen()

        // не ответили из нотча за 38с — отпускаем в терминальный пикер
        DispatchQueue.main.asyncAfter(deadline: .now() + 38) { [weak self] in
            self?.resolveQuestion(id: id, answer: nil, userInitiated: false)
        }
    }

    private func resolveQuestion(id: String, answer: String?, userInitiated: Bool = true) {
        guard let responder = pendingQuestions.removeValue(forKey: id) else { return }
        let question = state.questions.first { $0.id == id }
        if let answer, let question {
            let reason = "The user already answered this question via the notch UI. "
                + "Question: \"\(question.question)\" — Answer: \"\(answer)\". "
                + "Proceed with this answer; do not ask again."
            let payload: [String: Any] = [
                "hookSpecificOutput": [
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "deny",
                    "permissionDecisionReason": reason,
                ],
            ]
            if let data = try? JSONSerialization.data(withJSONObject: payload),
               let s = String(data: data, encoding: .utf8) {
                responder.send(s)
            } else {
                responder.send("{}")
            }
        } else {
            responder.send("{}")   // fall through → пикер в терминале
        }
        state.questions.removeAll { $0.id == id }
        finishEventIfIdle(userInitiated: userInitiated)
    }

    private static func decisionJSON(allow: Bool) -> String {
        var decision: [String: Any] = ["behavior": allow ? "allow" : "deny"]
        if !allow { decision["message"] = "Denied from the notch" }
        let payload: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "decision": decision,
            ],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }

    /// Мини-дифф для Edit/Write/MultiEdit: первые строки старого/нового текста.
    private static func diffPreview(tool: String, input: [String: Any]) -> DiffPreview? {
        func lines(_ s: String) -> [String] {
            s.split(separator: "\n", omittingEmptySubsequences: false)
                .map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        switch tool {
        case "Edit":
            guard let old = input["old_string"] as? String,
                  let new = input["new_string"] as? String else { return nil }
            let o = lines(old), n = lines(new)
            return DiffPreview(removed: Array(o.prefix(2)), added: Array(n.prefix(2)),
                               removedTotal: o.count, addedTotal: n.count)
        case "ExitPlanMode":
            // Plan review: показываем начало плана прямо в карточке
            guard let plan = input["plan"] as? String else { return nil }
            let n = lines(plan)
            return DiffPreview(removed: [], added: Array(n.prefix(4)),
                               removedTotal: 0, addedTotal: n.count)
        case "Write":
            guard let content = input["content"] as? String else { return nil }
            let n = lines(content)
            return DiffPreview(removed: [], added: Array(n.prefix(3)),
                               removedTotal: 0, addedTotal: n.count)
        case "MultiEdit":
            guard let edits = input["edits"] as? [[String: Any]],
                  let first = edits.first,
                  let old = first["old_string"] as? String,
                  let new = first["new_string"] as? String else { return nil }
            let allOld = edits.compactMap { $0["old_string"] as? String }.flatMap(lines)
            let allNew = edits.compactMap { $0["new_string"] as? String }.flatMap(lines)
            return DiffPreview(removed: Array(lines(old).prefix(2)), added: Array(lines(new).prefix(2)),
                               removedTotal: allOld.count, addedTotal: allNew.count)
        default:
            return nil
        }
    }

    private static func summary(tool: String, input: [String: Any]) -> String {
        if tool == "ExitPlanMode" { return "План готов — посмотри и подтверди" }
        if let cmd = input["command"] as? String { return cmd }
        if let path = input["file_path"] as? String { return path }
        if let url = input["url"] as? String { return url }
        if let pattern = input["pattern"] as? String { return pattern }
        if input.isEmpty { return tool }
        return input.keys.sorted().prefix(3).map { "\($0)" }.joined(separator: ", ")
    }

    // MARK: - Экран завершения («что сделано»)

    /// Показывает экран «Done» с контекстом сессии; сам гаснет через 8 секунд.
    private func showCompletion(session: AgentSession?, agent: String, summary: String) {
        var text = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { text = session?.lastAssistant ?? "" }
        if text.isEmpty { text = "Работа над задачей завершена." }

        let comp = CompletionEvent(id: UUID().uuidString,
                                   sessionId: session?.sessionId ?? "",
                                   agent: agent,
                                   projectName: session?.projectName ?? "",
                                   title: session?.title ?? "",
                                   summary: String(text.replacingOccurrences(of: "\n", with: " ").prefix(220)),
                                   date: Date())
        state.completion = comp
        state.showAllSessions = false
        play("Pop")
        controller.flash()
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, self.state.completion?.id == comp.id else { return }
            self.state.completion = nil
        }
    }

    private func upsertAlert(_ alert: SessionAlert) {
        var alerts = state.alerts.filter { $0.id != alert.id }
        alerts.append(alert)
        alerts.sort { $0.date > $1.date }
        state.alerts = alerts
    }

    private func removeAlert(_ sid: String) {
        state.alerts.removeAll { $0.id == sid }
    }

    @objc private func resetAlwaysRules() {
        PermissionRules.clear()
    }

    @objc private func checkForUpdates() {
        updater.check()
    }

    private func notifyUpdateFailed(_ msg: String) {
        let a = NSAlert()
        a.messageText = "Обновление не удалось"
        a.informativeText = msg
        a.addButton(withTitle: "OK")
        if let info = state.update {
            a.addButton(withTitle: "Открыть страницу релиза")
            if a.runModal() == .alertSecondButtonReturn {
                NSWorkspace.shared.open(info.pageURL)
            }
        } else {
            a.runModal()
        }
    }

    // MARK: - Автозапуск при логине (только из .app-бандла)

    private var isBundled: Bool {
        Bundle.main.bundlePath.hasSuffix(".app")
    }

    private func registerLoginItemIfBundled() {
        guard isBundled, SMAppService.mainApp.status != .enabled else { return }
        try? SMAppService.mainApp.register()
    }

    @objc private func toggleLoginItem(_ item: NSMenuItem) {
        if SMAppService.mainApp.status == .enabled {
            try? SMAppService.mainApp.unregister()
        } else {
            try? SMAppService.mainApp.register()
        }
        item.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    private func play(_ name: String) {
        guard state.soundEnabled else { return }
        guard let sound = NSSound(named: name) else { return }
        sound.volume = 0.5
        sound.play()
    }
}
