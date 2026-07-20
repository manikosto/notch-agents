import AppKit
import SwiftUI

final class NotchState: ObservableObject {
    @Published var sessions: [AgentSession] = []
    @Published var alerts: [SessionAlert] = []
    @Published var prompts: [PermissionPrompt] = []
    @Published var questions: [QuestionPrompt] = []
    @Published var completion: CompletionEvent?
    @Published var usage: UsageInfo?
    @Published var defaultModel: String?
    @Published var expanded = false
    /// Пользователь ушёл с экрана события на список сессий («Show all sessions»).
    @Published var showAllSessions = false
    @Published var soundEnabled = UserDefaults.standard.object(forKey: "soundEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(soundEnabled, forKey: "soundEnabled") }
    }
    var notchSize = CGSize(width: 200, height: 33)

    /// Экран панели: вопрос > запрос разрешения > завершение > список сессий.
    var screen: NotchScreen {
        if !showAllSessions {
            if let q = questions.first { return .question(q) }
            if let p = prompts.first { return .permission(p) }
            if let c = completion { return .done(c) }
        }
        return .sessions
    }
}

/// Единый источник размеров «поверхности» нотча — использует и SwiftUI, и hitTest окна.
enum NotchMetrics {
    static let expandedWidth: CGFloat = 640
    static let rowHeight: CGFloat = 56
    static let alertHeight: CGFloat = 58
    static let rowSpacing: CGFloat = 8
    static let maxRows = 5
    static let maxAlerts = 3
    static let maxPrompts = 2
    static let promptCardHeight: CGFloat = 92
    static let doneCardHeight: CGFloat = 84

    static let wingWidth: CGFloat = 34

    /// Высота карточки вопроса: варианты + строка своего ответа.
    static func questionHeight(optionCount: Int) -> CGFloat {
        66 + CGFloat(optionCount) * 32 + 32
    }

    /// Высота карточки разрешения: базовая + блок мини-диффа, если есть.
    static func promptHeight(for prompt: PermissionPrompt) -> CGFloat {
        guard let d = prompt.diff else { return promptCardHeight }
        let rows = d.removed.count + d.added.count
        return promptCardHeight + CGFloat(rows) * 15 + 12 + 7
    }

    /// Шапка в полосе выреза + зазоры + футер.
    private static func baseHeight(_ notch: CGSize) -> CGFloat {
        notch.height + 6 + 8 + 22 + 10
    }

    static func surfaceSize(state: NotchState) -> CGSize {
        let notch = state.notchSize
        let attention = !state.alerts.isEmpty || !state.prompts.isEmpty || !state.questions.isEmpty
        guard state.expanded else {
            // вырез + «крылья»; +5px под пульсирующий огонёк, когда агент ждёт
            return CGSize(width: notch.width + wingWidth * 2,
                          height: notch.height + (attention ? 5 : 0))
        }
        var height = baseHeight(notch)
        switch state.screen {
        case .sessions:
            let alerts = min(state.alerts.count, maxAlerts)
            let rows = state.sessions.isEmpty
                ? (alerts > 0 ? 0 : 1)
                : min(state.sessions.count, maxRows)
            if rows > 0 {
                height += CGFloat(rows) * rowHeight + CGFloat(rows - 1) * rowSpacing
            }
            if alerts > 0 {
                height += CGFloat(alerts) * (alertHeight + rowSpacing)
            }
        case .permission(let p):
            if state.sessions.contains(where: { $0.sessionId == p.sessionId }) {
                height += rowHeight + rowSpacing
            }
            height += promptHeight(for: p)
        case .question(let q):
            if state.sessions.contains(where: { $0.sessionId == q.sessionId }) {
                height += rowHeight + rowSpacing
            }
            height += questionHeight(optionCount: q.options.count)
        case .done(let c):
            if state.sessions.contains(where: { $0.sessionId == c.sessionId }) {
                height += rowHeight + rowSpacing
            }
            height += doneCardHeight
        }
        return CGSize(width: expandedWidth, height: height)
    }

    /// Максимально возможная поверхность — для фиксированного окна.
    static func maxSurfaceSize(notch: CGSize) -> CGSize {
        let base = baseHeight(notch)
        let sessions = base + CGFloat(maxRows) * rowHeight + CGFloat(maxRows - 1) * rowSpacing
            + CGFloat(maxAlerts) * (alertHeight + rowSpacing)
        let question = base + rowHeight + rowSpacing + questionHeight(optionCount: 4)
        // + запас под мини-дифф до 5 строк
        let permission = base + rowHeight + rowSpacing + promptCardHeight + 5 * 15 + 19
        return CGSize(width: expandedWidth, height: max(sessions, max(question, permission)))
    }
}

final class NotchPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false        // системная тень давала серую линию у верхнего края
        isMovable = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Пропускает клики/ховер везде, кроме видимой поверхности нотча,
/// чтобы большое прозрачное окно не перекрывало рабочий стол.
final class PassThroughHostingView<Content: View>: NSHostingView<Content> {
    var surfaceSize: () -> CGSize = { .zero }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        let s = surfaceSize()
        let rect = CGRect(x: bounds.midX - s.width / 2,
                          y: isFlipped ? 0 : bounds.height - s.height,
                          width: s.width, height: s.height)
        guard rect.contains(p) else { return nil }
        return super.hitTest(point)
    }

    required init(rootView: Content) {
        super.init(rootView: rootView)
    }

    @MainActor @preconcurrency required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}

final class NotchController {
    let state: NotchState
    private let panel: NotchPanel
    private let space = CGSSpace()
    private var collapseWork: DispatchWorkItem?
    private var hovering = false

    /// Решение по запросу разрешения из карточки в нотче.
    var permissionHandler: ((String, PermissionAction) -> Void)?
    /// Ответ на вопрос AskUserQuestion: (questionId, выбранный вариант или nil = в терминал).
    var questionHandler: ((String, String?) -> Void)?

    /// Раскрытие — упругое, с лёгким баунсом.
    private static let expandSpring = Animation.spring(response: 0.38, dampingFraction: 0.82)
    /// Сворачивание — без перелёта: пружина с недодемпфированием ужала бы
    /// поверхность меньше выреза, и на миг выглядывала бы железная чёлка.
    private static let collapseSpring = Animation.spring(response: 0.22, dampingFraction: 1.0)

    init(state: NotchState) {
        self.state = state
        let screen = Self.targetScreen()
        state.notchSize = Self.notchSize(on: screen)

        // Окно фиксированного размера (максимум разворота + запас под тень) —
        // весь морфинг делает SwiftUI, окно никогда не меняет frame.
        let maxSurface = NotchMetrics.maxSurfaceSize(notch: state.notchSize)
        let w = maxSurface.width + 120
        let h = maxSurface.height + 60
        let rect = NSRect(x: screen.frame.midX - w / 2,
                          y: screen.frame.maxY - h,
                          width: w, height: h)

        panel = NotchPanel(contentRect: rect)
        let host = PassThroughHostingView(rootView: NotchRootView(state: state, controller: self))
        host.surfaceSize = { [weak state] in
            guard let state else { return .zero }
            return NotchMetrics.surfaceSize(state: state)
        }
        panel.contentView = host
        panel.orderFrontRegardless()
        space.add(panel)   // своё CGS-space: не едет при переключении Spaces
    }

    // MARK: - Geometry

    static func targetScreen() -> NSScreen {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    static func notchSize(on screen: NSScreen) -> CGSize {
        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            return CGSize(width: screen.frame.width - left.width - right.width,
                          height: screen.safeAreaInsets.top)
        }
        return CGSize(width: 200, height: 33) // экран без нотча — рисуем свой
    }

    // MARK: - Interaction

    func hover(_ inside: Bool) {
        hovering = inside
        if inside {
            collapseWork?.cancel()
            expand()
        } else {
            // почти мгновенно: крошечный зазор только от дребезга на границе
            scheduleCollapse(after: 0.05)
        }
    }

    private func expand() {
        guard !state.expanded else { return }
        withAnimation(Self.expandSpring) { state.expanded = true }
    }

    private func scheduleCollapse(after delay: TimeInterval) {
        collapseWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            // пока висит запрос разрешения или вопрос — не сворачиваемся
            guard let self, !self.hovering,
                  self.state.prompts.isEmpty, self.state.questions.isEmpty else { return }
            withAnimation(Self.collapseSpring) { self.state.expanded = false }
        }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Раскрыть и держать открытым (ждём решения пользователя).
    func holdOpen() {
        collapseWork?.cancel()
        expand()
    }

    /// Отпустить панель (после решения).
    func release(after delay: TimeInterval) {
        scheduleCollapse(after: delay)
    }

    /// Свернуть немедленно — пользователь сделал действие, больше не отвлекаем.
    func collapseNow() {
        collapseWork?.cancel()
        withAnimation(Self.collapseSpring) { state.expanded = false }
    }

    /// Агент закончил ход — короткий поп
    func flash() {
        expand()
        scheduleCollapse(after: 6)
    }

    /// Агент ждёт разрешения/ответа — поп подольше
    func alertPop() {
        expand()
        scheduleCollapse(after: 10)
    }

    /// Прыжок к сессии: точная вкладка (Terminal/iTerm), иначе — терминал-хозяин
    /// (Warp, Ghostty, …). Если сессия нигде не запущена — поднимаем её заново.
    func openSession(_ session: AgentSession) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            if TerminalLocator.jump(cwd: session.cwd) { return }
            DispatchQueue.main.async {
                if session.agent == "Claude", !session.sessionId.isEmpty {
                    self.resumeInTerminal(session)
                } else {
                    self.focusTerminal()
                }
            }
        }
    }

    /// Открыть новое окно Terminal с продолжением сессии (claude --resume).
    private func resumeInTerminal(_ s: AgentSession) {
        var cmd = "claude --resume \(s.sessionId)"
        if !s.cwd.isEmpty {
            let quoted = "'" + s.cwd.replacingOccurrences(of: "'", with: "'\\''") + "'"
            cmd = "cd \(quoted) && " + cmd
        }
        let escaped = cmd
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Terminal"
            activate
            do script "\(escaped)"
        end tell
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        try? p.run()
    }

    /// Переключиться в терминал, где живут сессии.
    /// Активация — через LaunchServices: NSRunningApplication.activate
    /// из фонового приложения молча игнорируется системой.
    func focusTerminal() {
        let bundleIds = [
            "dev.warp.Warp-Stable",
            "com.googlecode.iterm2",
            "com.apple.Terminal",
            "com.mitchellh.ghostty",
        ]
        for id in bundleIds {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first,
               let url = app.bundleURL {
                NSWorkspace.shared.openApplication(at: url,
                                                   configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
                return
            }
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
            NSWorkspace.shared.openApplication(at: url,
                                               configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
        }
    }
}
